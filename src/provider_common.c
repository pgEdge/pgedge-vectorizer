/*-------------------------------------------------------------------------
 *
 * provider_common.c
 *		Shared utilities for embedding provider implementations
 *
 * Extracted from provider_openai.c and provider_voyage.c to eliminate
 * code duplication across providers.
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "provider_common.h"

#include <sys/stat.h>
#include <unistd.h>

#include "utils/memutils.h"

/*
 * Curl write callback - accumulates response data into a ResponseBuffer.
 */
size_t
provider_write_callback(void *contents, size_t size, size_t nmemb, void *userp)
{
	size_t realsize = size * nmemb;
	ResponseBuffer *mem = (ResponseBuffer *) userp;

	char *ptr = repalloc(mem->data, mem->size + realsize + 1);
	if (!ptr)
		return 0;  /* Out of memory */

	mem->data = ptr;
	/* flawfinder: ignore - buffer was realloced to mem->size + realsize + 1 */
	memcpy(&(mem->data[mem->size]), contents, realsize);  /* nosemgrep */
	mem->size += realsize;
	mem->data[mem->size] = 0;

	return realsize;
}

/*
 * Expand tilde in path
 */
char *
provider_expand_tilde(const char *path)
{
	if (path[0] == '~' && (path[1] == '/' || path[1] == '\0'))
	{
		const char *home = getenv("HOME");
		if (home)
			return psprintf("%s%s", home, path + 1);
	}
	return pstrdup(path);
}

/*
 * Load API key from file
 *
 * Handles tilde expansion, file permission checks, and persists the key
 * in TopMemoryContext so it survives across transactions.
 */
char *
provider_load_api_key(const char *filepath, char **error_msg)
{
	FILE *fp;
	char *expanded_path;
	StringInfoData key_buf;
	int c;
	struct stat st;

	if (filepath == NULL || filepath[0] == '\0')
	{
		*error_msg = pstrdup("API key file path is not configured");
		return NULL;
	}

	/* Expand tilde */
	expanded_path = provider_expand_tilde(filepath);

	/* Check file exists and has proper permissions */
	if (stat(expanded_path, &st) != 0)
	{
		*error_msg = psprintf("API key file not found: %s", expanded_path);
		pfree(expanded_path);
		return NULL;
	}

	/* Warn if file is world-readable */
	if (st.st_mode & (S_IRWXG | S_IRWXO))
	{
		elog(WARNING, "API key file %s has permissive permissions (should be 0600)",
			 expanded_path);
	}

	/* Open and read file */
	fp = fopen(expanded_path, "r");
	if (fp == NULL)
	{
		*error_msg = psprintf("Failed to open API key file: %s", expanded_path);
		pfree(expanded_path);
		return NULL;
	}

	initStringInfo(&key_buf);

	/* Read the file, trimming whitespace */
	while ((c = fgetc(fp)) != EOF)
	{
		if (c != '\n' && c != '\r' && c != ' ' && c != '\t')
			appendStringInfoChar(&key_buf, c);
	}

	fclose(fp);
	pfree(expanded_path);

	if (key_buf.len == 0)
	{
		*error_msg = pstrdup("API key file is empty");
		pfree(key_buf.data);
		return NULL;
	}

	/* Copy to TopMemoryContext so it persists across transactions */
	{
		char *persistent_key;
		MemoryContext oldcontext;

		oldcontext = MemoryContextSwitchTo(TopMemoryContext);
		persistent_key = pstrdup(key_buf.data);
		MemoryContextSwitchTo(oldcontext);

		pfree(key_buf.data);
		return persistent_key;
	}
}

/*
 * Escape a string for JSON
 */
char *
provider_escape_json_string(const char *str)
{
	StringInfoData buf;
	const char *p;

	initStringInfo(&buf);

	for (p = str; *p; p++)
	{
		switch (*p)
		{
			case '"':
				appendStringInfoString(&buf, "\\\"");
				break;
			case '\\':
				appendStringInfoString(&buf, "\\\\");
				break;
			case '\b':
				appendStringInfoString(&buf, "\\b");
				break;
			case '\f':
				appendStringInfoString(&buf, "\\f");
				break;
			case '\n':
				appendStringInfoString(&buf, "\\n");
				break;
			case '\r':
				appendStringInfoString(&buf, "\\r");
				break;
			case '\t':
				appendStringInfoString(&buf, "\\t");
				break;
			default:
				if ((unsigned char) *p < 32)
					appendStringInfo(&buf, "\\u%04x", (unsigned char) *p);
				else
					appendStringInfoChar(&buf, *p);
				break;
		}
	}

	return buf.data;
}

/*
 * Build an OpenAI-format embedding request body.
 *
 * Returns a palloc'd JSON string: {"input":["text1","text2"],"model":"model-name"}
 * Caller must pfree the result.
 */
char *
provider_build_openai_request(const char **texts, int count, const char *model)
{
	StringInfoData request_buf;

	initStringInfo(&request_buf);
	appendStringInfo(&request_buf, "{\"input\":[");
	for (int i = 0; i < count; i++)
	{
		char *escaped = provider_escape_json_string(texts[i]);
		if (i > 0)
			appendStringInfoChar(&request_buf, ',');
		appendStringInfo(&request_buf, "\"%s\"", escaped);
		pfree(escaped);
	}
	appendStringInfo(&request_buf, "],\"model\":\"%s\"}", model);

	return request_buf.data;
}

/*
 * Perform an HTTP POST request via curl.
 *
 * Handles:
 * - Setting Content-Type header
 * - Adding provider-specific auth header (if non-NULL)
 * - Parsing and appending extra_headers from GUC
 * - Curl lifecycle (init, perform, cleanup)
 * - HTTP response code checking
 *
 * Returns true on HTTP 200, false otherwise.
 */
bool
provider_do_curl_request(const char *url, const char *auth_header,
						 const char *json_request,
						 const char *provider_name,
						 ResponseBuffer *response_out,
						 char **error_msg)
{
	CURL *curl;
	CURLcode res;
	struct curl_slist *headers = NULL;
	long response_code;

	/* Initialize response buffer */
	response_out->data = palloc(1);
	response_out->data[0] = '\0';
	response_out->size = 0;

	/* Initialize curl */
	curl = curl_easy_init();
	if (!curl)
	{
		*error_msg = pstrdup("Failed to initialize libcurl");
		pfree(response_out->data);
		response_out->data = NULL;
		return false;
	}

	/* Set up headers */
	headers = curl_slist_append(headers, "Content-Type: application/json; charset=utf-8");

	if (auth_header != NULL)
		headers = curl_slist_append(headers, auth_header);

	/* Parse and append extra headers from GUC */
	if (pgedge_vectorizer_extra_headers != NULL &&
		pgedge_vectorizer_extra_headers[0] != '\0')
	{
		char *headers_copy = pstrdup(pgedge_vectorizer_extra_headers);
		char *saveptr = NULL;
		char *token;

		for (token = strtok_r(headers_copy, ";", &saveptr);
			 token != NULL;
			 token = strtok_r(NULL, ";", &saveptr))
		{
			/* Trim leading whitespace */
			while (*token == ' ' || *token == '\t')
				token++;

			/* Trim trailing whitespace */
			{
				char *end = token + strlen(token) - 1;
				while (end > token && (*end == ' ' || *end == '\t'))
					*end-- = '\0';
			}

			/* Skip empty tokens */
			if (*token == '\0')
				continue;

			/* Validate: must contain a colon */
			if (strchr(token, ':') == NULL)
			{
				elog(WARNING, "Ignoring invalid extra header (no colon): %s", token);
				continue;
			}

			headers = curl_slist_append(headers, token);
		}

		pfree(headers_copy);
	}

	/* Configure curl */
	curl_easy_setopt(curl, CURLOPT_URL, url);
	curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
	curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_request);
	/* flawfinder: ignore - json_request is null-terminated */
	curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(json_request));
	curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, provider_write_callback);
	curl_easy_setopt(curl, CURLOPT_WRITEDATA, response_out);
	curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);  /* 5 minute timeout */

	/* Perform the request */
	res = curl_easy_perform(curl);

	if (res != CURLE_OK)
	{
		*error_msg = psprintf("curl_easy_perform() failed: %s",
							  curl_easy_strerror(res));
		curl_slist_free_all(headers);
		curl_easy_cleanup(curl);
		return false;
	}

	/* Check HTTP response code */
	curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
	if (response_code != 200)
	{
		*error_msg = psprintf("%s API returned HTTP %ld: %s",
							  provider_name, response_code, response_out->data);
		curl_slist_free_all(headers);
		curl_easy_cleanup(curl);
		return false;
	}

	curl_slist_free_all(headers);
	curl_easy_cleanup(curl);
	return true;
}

/*
 * Parse OpenAI-format batch embedding response.
 *
 * Expected format:
 * {"data":[{"embedding":[0.1,0.2,...]},{"embedding":[...]}],...}
 *
 * Used by OpenAI, Voyage, and OpenAI-compatible local providers.
 */
float **
provider_parse_openai_embedding_response(const char *json_response, int count,
										 int *dim, char **error_msg)
{
	const char *p;
	float **embeddings = NULL;
	int embedding_idx = 0;
	int value_idx;
	char value_buf[32];
	int value_pos;

	/* Allocate array for embeddings */
	embeddings = (float **) palloc0(sizeof(float *) * count);

	/* Find "data" array */
	p = strstr(json_response, "\"data\"");
	if (p == NULL)
	{
		*error_msg = pstrdup("Invalid response: 'data' field not found");
		goto error;
	}

	/* Find first embedding array */
	p = strstr(p, "\"embedding\"");
	if (p == NULL)
	{
		*error_msg = pstrdup("Invalid response: 'embedding' field not found");
		goto error;
	}

	/* Process each embedding */
	while (embedding_idx < count && p != NULL)
	{
		/* Find opening bracket */
		p = strchr(p, '[');
		if (p == NULL)
			break;
		p++;

		/* Count dimensions if first embedding */
		if (*dim == 0)
		{
			const char *temp = p;
			int comma_count = 0;
			while (*temp && *temp != ']')
			{
				if (*temp == ',')
					comma_count++;
				temp++;
			}
			*dim = comma_count + 1;
		}

		/* Allocate array for this embedding */
		embeddings[embedding_idx] = (float *) palloc(sizeof(float) * (*dim));
		value_idx = 0;

		/* Parse values */
		while (value_idx < *dim && *p && *p != ']')
		{
			/* Skip whitespace and commas */
			while (*p && (*p == ' ' || *p == ',' || *p == '\t' || *p == '\n'))
				p++;

			if (*p == ']')
				break;

			/* Read numeric value */
			value_pos = 0;
			while (*p && (isdigit(*p) || *p == '.' || *p == '-' || *p == '+' || *p == 'e' || *p == 'E'))
			{
				if (value_pos < sizeof(value_buf) - 1)
					value_buf[value_pos++] = *p;
				p++;
			}
			value_buf[value_pos] = '\0';

			if (value_pos > 0)
			{
				embeddings[embedding_idx][value_idx] = atof(value_buf);
				value_idx++;
			}
		}

		if (value_idx != *dim)
		{
			*error_msg = psprintf("Dimension mismatch: expected %d, got %d",
								  *dim, value_idx);
			goto error;
		}

		embedding_idx++;

		/* Find next embedding */
		p = strstr(p, "\"embedding\"");
	}

	if (embedding_idx != count)
	{
		*error_msg = psprintf("Expected %d embeddings, got %d",
							  count, embedding_idx);
		goto error;
	}

	return embeddings;

error:
	if (embeddings != NULL)
	{
		for (int i = 0; i < embedding_idx; i++)
		{
			if (embeddings[i] != NULL)
				pfree(embeddings[i]);
		}
		pfree(embeddings);
	}
	return NULL;
}

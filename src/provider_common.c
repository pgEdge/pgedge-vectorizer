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
 * Per-backend curl handle, kept so that its connection pool outlives a
 * single request.  See provider_do_curl_request() for why.
 */
static CURL *cached_curl = NULL;

/* Initial response buffer size; embedding responses run to megabytes. */
#define RESPONSE_BUFFER_INITIAL	32768

/*
 * Curl write callback - accumulates response data into a ResponseBuffer.
 */
size_t
provider_write_callback(void *contents, size_t size, size_t nmemb, void *userp)
{
	size_t realsize = size * nmemb;
	ResponseBuffer *mem = (ResponseBuffer *) userp;
	size_t needed = mem->size + realsize + 1;

	/*
	 * Grow geometrically rather than to the exact size wanted.  curl hands
	 * the body over in chunks of its own choosing, so sizing precisely meant
	 * a repalloc per chunk for the whole response: an embedding batch runs to
	 * megabytes, which is hundreds of them, each liable to copy everything
	 * received so far.  Doubling makes that a handful.
	 *
	 * Nothing here may throw.  This runs inside curl_easy_perform(), and a
	 * PostgreSQL error is a longjmp, which would abandon curl's handle and its
	 * connection mid-transfer.  The handle is cached for the life of the
	 * backend, so every later request would go on reusing the wreckage.  On
	 * failure we record why and return short instead, which curl reports as
	 * CURLE_WRITE_ERROR through the caller's existing error path.
	 */
	if (needed > mem->capacity)
	{
		size_t newcap = (mem->capacity > 0) ? mem->capacity : needed;
		char *newdata;

		while (newcap < needed)
			newcap *= 2;

		/*
		 * Doubling can overshoot MaxAllocSize while the response itself would
		 * still fit, so try the exact size before giving up on it.
		 */
		if (!AllocSizeIsValid(newcap))
			newcap = needed;

		if (!AllocSizeIsValid(newcap))
		{
			mem->grow_failure = RESPONSE_GROW_TOO_LARGE;
			return 0;
		}

		newdata = repalloc_extended(mem->data, newcap, MCXT_ALLOC_NO_OOM);
		if (newdata == NULL)
		{
			mem->grow_failure = RESPONSE_GROW_NO_MEMORY;
			return 0;
		}

		mem->data = newdata;
		mem->capacity = newcap;
	}

	/* flawfinder: ignore - buffer holds at least mem->size + realsize + 1 */
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
		const char *home = getenv("HOME");  /* nosemgrep */
		if (home)
			return psprintf("%s%s", home, path + 1);
	}
	return pstrdup(path);
}

/*
 * Read API key from file into a persistent (TopMemoryContext) string.
 *
 * Handles tilde expansion, file permission checks, and whitespace trimming.
 */
char *
provider_load_api_key(const char *filepath, char **error_msg)
{
	FILE *fp;
	char *expanded_path;
	StringInfoData key_buf;
	int c;
	struct stat st;
	MemoryContext oldcontext;
	char *persistent_key;

	if (filepath == NULL || filepath[0] == '\0')
	{
		*error_msg = pstrdup("API key file path is not configured");
		return NULL;
	}

	expanded_path = provider_expand_tilde(filepath);

	if (stat(expanded_path, &st) != 0)
	{
		*error_msg = psprintf("API key file not found: %s", expanded_path);
		pfree(expanded_path);
		return NULL;
	}

	/* Bound the read to guard against a misconfigured path (CWE-20) */
	if (st.st_size > MAX_API_KEY_FILE_SIZE)
	{
		*error_msg = psprintf("API key file %s is too large (%lld bytes; limit %d)",
							  expanded_path, (long long) st.st_size,
							  MAX_API_KEY_FILE_SIZE);
		pfree(expanded_path);
		return NULL;
	}

	if (st.st_mode & (S_IRWXG | S_IRWXO))
		elog(WARNING, "API key file %s has permissive permissions (should be 0600)",
			 expanded_path);

	fp = fopen(expanded_path, "r");
	if (fp == NULL)
	{
		*error_msg = psprintf("Failed to open API key file: %s", expanded_path);
		pfree(expanded_path);
		return NULL;
	}

	pfree(expanded_path);
	initStringInfo(&key_buf);

	/* flawfinder: ignore - fgetc reads into auto-resizing StringInfo */
	while ((c = fgetc(fp)) != EOF)
	{
		if (c != '\n' && c != '\r' && c != ' ' && c != '\t')
			appendStringInfoChar(&key_buf, c);
	}
	fclose(fp);

	if (key_buf.len == 0)
	{
		*error_msg = pstrdup("API key file is empty");
		pfree(key_buf.data);
		return NULL;
	}

	oldcontext = MemoryContextSwitchTo(TopMemoryContext);
	persistent_key = pstrdup(key_buf.data);
	MemoryContextSwitchTo(oldcontext);

	pfree(key_buf.data);
	return persistent_key;
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
 * Count dimensions in a JSON float array by counting commas.
 * Pointer should be positioned just after the opening '['.
 */
int
provider_count_array_dimensions(const char *p)
{
	int comma_count = 0;

	while (*p && *p != ']')
	{
		if (*p == ',')
			comma_count++;
		p++;
	}
	return comma_count + 1;
}

/*
 * Parse a JSON float array into a pre-allocated output buffer.
 *
 * Reads up to `dim` float values from the current position (after '[').
 * Advances *pos past the parsed values (to ']' or end of parsed data).
 * Returns the number of values successfully parsed, or
 * PROVIDER_PARSE_MALFORMED on a numeric literal too long to be one, in which
 * case *pos is left on the offending run rather than past it.
 */
int
provider_parse_float_array(const char **pos, float *output, int dim)
{
	const char *p = *pos;
	int idx = 0;
	char value_buf[32];
	int value_pos;

	while (idx < dim && *p && *p != ']')
	{
		/* Skip whitespace and commas */
		while (*p && (*p == ' ' || *p == ',' || *p == '\t' || *p == '\n'))
			p++;

		if (*p == ']')
			break;

		/* Read numeric value */
		value_pos = 0;
		while (*p && (isdigit((unsigned char) *p) || *p == '.' || *p == '-' ||
					  *p == '+' || *p == 'e' || *p == 'E'))
		{
			/*
			 * Stop rather than truncate.  No double needs this many
			 * characters -- %.17g never exceeds 24 -- so a longer run means a
			 * malformed response, and keeping only the leading digits would
			 * feed atof() a number of an entirely different magnitude and
			 * score on it silently.
			 */
			if (value_pos >= (int) sizeof(value_buf) - 1)
			{
				*pos = p;
				return PROVIDER_PARSE_MALFORMED;
			}

			value_buf[value_pos++] = *p;
			p++;
		}
		value_buf[value_pos] = '\0';

		if (value_pos > 0)
		{
			output[idx] = atof(value_buf);
			idx++;
		}
	}

	*pos = p;
	return idx;
}

/*
 * Append extra headers from the pgedge_vectorizer.extra_headers GUC
 * to a curl header list. Parses semicolon-separated "key: value" pairs.
 */
void
provider_append_extra_headers(struct curl_slist **headers)
{
	char *headers_copy;
	char *saveptr = NULL;
	char *token;

	if (pgedge_vectorizer_extra_headers == NULL ||
		pgedge_vectorizer_extra_headers[0] == '\0')
		return;

	headers_copy = pstrdup(pgedge_vectorizer_extra_headers);

	for (token = strtok_r(headers_copy, ";", &saveptr);
		 token != NULL;
		 token = strtok_r(NULL, ";", &saveptr))
	{
		char *end;

		/* Trim leading whitespace */
		while (*token == ' ' || *token == '\t')
			token++;

		/* Trim trailing whitespace */
		/* flawfinder: ignore - token is NUL-terminated by strtok_r */
		end = token + strlen(token) - 1;  /* nosemgrep */
		while (end > token && (*end == ' ' || *end == '\t'))
			*end-- = '\0';

		if (*token == '\0')
			continue;

		if (strchr(token, ':') == NULL)
		{
			elog(WARNING, "Ignoring invalid extra header (no colon): %s", token);
			continue;
		}

		*headers = curl_slist_append(*headers, token);
	}

	pfree(headers_copy);
}

/*
 * Free a partially-allocated embeddings array (for error cleanup).
 */
void
provider_free_embeddings(float **embeddings, int count)
{
	if (embeddings == NULL)
		return;

	for (int i = 0; i < count; i++)
	{
		if (embeddings[i] != NULL)
			pfree(embeddings[i]);
	}
	pfree(embeddings);
}

/*
 * Perform an HTTP POST request via curl.
 *
 * Handles Content-Type, auth header, extra headers from GUC,
 * curl lifecycle, and HTTP response code checking.
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
	response_out->capacity = RESPONSE_BUFFER_INITIAL;
	response_out->data = palloc(response_out->capacity);
	response_out->data[0] = '\0';
	response_out->size = 0;
	response_out->grow_failure = RESPONSE_GROW_OK;

	/*
	 * Reuse this backend's handle rather than making a new one per request.
	 * A fresh handle knows nothing of any connection, so every batch paid for
	 * a TCP connection and, against a real provider, a TLS handshake as well:
	 * one or two extra round trips to a host that is usually not nearby, on
	 * every batch of a table that may have thousands. Keeping the handle
	 * keeps curl's connection pool with it, so subsequent batches to the same
	 * endpoint reuse the established connection.
	 *
	 * curl_easy_reset() clears the options set below without disturbing that
	 * pool, which is what makes reuse survive the reset.
	 *
	 * The handle is deliberately never cleaned up: it lives as long as the
	 * backend, and an idle keep-alive connection is closed by the server at
	 * its own timeout, so nothing is held open indefinitely.
	 */
	if (cached_curl == NULL)
	{
		cached_curl = curl_easy_init();
		if (!cached_curl)
		{
			*error_msg = pstrdup("Failed to initialize libcurl");
			pfree(response_out->data);
			response_out->data = NULL;
			return false;
		}
	}
	else
		curl_easy_reset(cached_curl);

	curl = cached_curl;

	/* Set up headers */
	headers = curl_slist_append(headers, "Content-Type: application/json; charset=utf-8");
	if (auth_header != NULL)
		headers = curl_slist_append(headers, auth_header);
	provider_append_extra_headers(&headers);

	/* Configure and perform request */
	curl_easy_setopt(curl, CURLOPT_URL, url);
	curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
	curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_request);
	/* flawfinder: ignore - json_request is null-terminated */
	curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(json_request));  /* nosemgrep */
	curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, provider_write_callback);
	curl_easy_setopt(curl, CURLOPT_WRITEDATA, response_out);
	curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);

	res = curl_easy_perform(curl);

	if (res != CURLE_OK)
	{
		/*
		 * A buffer we could not grow aborts the transfer, so check it first:
		 * curl only knows the write callback returned short, and would report
		 * that as a generic write failure.
		 */
		if (response_out->grow_failure == RESPONSE_GROW_TOO_LARGE)
			*error_msg = psprintf("Response from %s is larger than can be "
								  "buffered (stopped after %zu bytes)",
								  provider_name, response_out->size);
		else if (response_out->grow_failure == RESPONSE_GROW_NO_MEMORY)
			*error_msg = psprintf("Out of memory buffering the response from "
								  "%s (stopped after %zu bytes)",
								  provider_name, response_out->size);
		else
			*error_msg = psprintf("curl_easy_perform() failed: %s",
								  curl_easy_strerror(res));
		curl_slist_free_all(headers);
		return false;
	}

	curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
	curl_slist_free_all(headers);

	if (response_code != 200)
	{
		*error_msg = psprintf("%s API returned HTTP %ld: %s",
							  provider_name, response_code, response_out->data);
		return false;
	}

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
	float **embeddings;
	int embedding_idx = 0;

	embeddings = (float **) palloc0(sizeof(float *) * count);

	p = strstr(json_response, "\"data\"");
	if (p == NULL)
	{
		*error_msg = pstrdup("Invalid response: 'data' field not found");
		pfree(embeddings);
		return NULL;
	}

	p = strstr(p, "\"embedding\"");
	if (p == NULL)
	{
		*error_msg = pstrdup("Invalid response: 'embedding' field not found");
		pfree(embeddings);
		return NULL;
	}

	while (embedding_idx < count && p != NULL)
	{
		int parsed;

		p = strchr(p, '[');
		if (p == NULL)
			break;
		p++;

		if (*dim == 0)
			*dim = provider_count_array_dimensions(p);

		embeddings[embedding_idx] = (float *) palloc(sizeof(float) * (*dim));
		parsed = provider_parse_float_array(&p, embeddings[embedding_idx], *dim);

		if (parsed != *dim)
		{
			*error_msg = (parsed == PROVIDER_PARSE_MALFORMED)
				? pstrdup("Malformed embedding response: numeric literal too "
						  "long to be a number")
				: psprintf("Dimension mismatch: expected %d, got %d",
						   *dim, parsed);
			provider_free_embeddings(embeddings, embedding_idx + 1);
			return NULL;
		}

		embedding_idx++;
		p = strstr(p, "\"embedding\"");
	}

	if (embedding_idx != count)
	{
		*error_msg = psprintf("Expected %d embeddings, got %d",
							  count, embedding_idx);
		provider_free_embeddings(embeddings, embedding_idx);
		return NULL;
	}

	return embeddings;
}

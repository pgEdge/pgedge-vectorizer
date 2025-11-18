/*-------------------------------------------------------------------------
 *
 * provider_openai.c
 *		OpenAI embedding provider implementation
 *
 * This file implements the OpenAI embedding API integration using libcurl.
 *
 * Copyright (c) 2025, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"

#include <curl/curl.h>
#include <sys/stat.h>
#include <unistd.h>

#include "utils/memutils.h"

/* For JSON parsing - we'll use a simple manual parser */

/*
 * Response buffer for libcurl
 */
typedef struct
{
	char *data;
	size_t size;
} ResponseBuffer;

/*
 * Static variables
 */
static char *api_key = NULL;
static bool provider_initialized = false;

/*
 * Forward declarations
 */
static bool openai_init(char **error_msg);
static void openai_cleanup(void);
static float *openai_generate(const char *text, int *dim, char **error_msg);
static float **openai_generate_batch(const char **texts, int count, int *dim, char **error_msg);

/* Helper functions */
static char *load_api_key(const char *filepath, char **error_msg);
static char *expand_tilde(const char *path);
static char *escape_json_string(const char *str);
static size_t write_callback(void *contents, size_t size, size_t nmemb, void *userp);
static float **parse_batch_embedding_response(const char *json_response, int count, int *dim, char **error_msg);

/*
 * OpenAI Provider struct
 */
EmbeddingProvider OpenAIProvider = {
	.name = "openai",
	.init = openai_init,
	.cleanup = openai_cleanup,
	.generate = openai_generate,
	.generate_batch = openai_generate_batch
};

/*
 * Initialize OpenAI provider
 */
static bool
openai_init(char **error_msg)
{
	if (provider_initialized)
		return true;

	/* Initialize curl globally */
	curl_global_init(CURL_GLOBAL_DEFAULT);

	/* Load API key */
	api_key = load_api_key(pgedge_vectorizer_api_key_file, error_msg);
	if (api_key == NULL)
	{
		curl_global_cleanup();
		return false;
	}

	provider_initialized = true;
	elog(DEBUG1, "OpenAI provider initialized successfully");
	return true;
}

/*
 * Cleanup OpenAI provider
 */
static void
openai_cleanup(void)
{
	if (!provider_initialized)
		return;

	if (api_key != NULL)
	{
		memset(api_key, 0, strlen(api_key));  /* Zero out key */
		pfree(api_key);
		api_key = NULL;
	}

	curl_global_cleanup();
	provider_initialized = false;
	elog(DEBUG1, "OpenAI provider cleaned up");
}

/*
 * Generate a single embedding
 */
static float *
openai_generate(const char *text, int *dim, char **error_msg)
{
	const char *texts[1] = {text};
	float **embeddings;
	float *result;

	/* Use batch function with count=1 */
	embeddings = openai_generate_batch(texts, 1, dim, error_msg);
	if (embeddings == NULL)
		return NULL;

	/* Extract the single embedding */
	result = embeddings[0];
	pfree(embeddings);

	return result;
}

/*
 * Generate embeddings in batch
 */
static float **
openai_generate_batch(const char **texts, int count, int *dim, char **error_msg)
{
	CURL *curl;
	CURLcode res;
	struct curl_slist *headers = NULL;
	char *json_request;
	char *url;
	StringInfoData request_buf;
	ResponseBuffer response;
	char auth_header[512];
	float **embeddings = NULL;
	long response_code;

	if (!provider_initialized)
	{
		if (!openai_init(error_msg))
			return NULL;
	}

	/* Initialize response buffer */
	response.data = palloc(1);
	response.data[0] = '\0';
	response.size = 0;

	/* Build JSON request */
	initStringInfo(&request_buf);
	appendStringInfo(&request_buf, "{\"input\":[");
	for (int i = 0; i < count; i++)
	{
		char *escaped = escape_json_string(texts[i]);
		if (i > 0)
			appendStringInfoChar(&request_buf, ',');
		appendStringInfo(&request_buf, "\"%s\"", escaped);
		pfree(escaped);
	}
	appendStringInfo(&request_buf, "],\"model\":\"%s\"}", pgedge_vectorizer_model);
	json_request = request_buf.data;

	/* Build URL */
	url = psprintf("%s/embeddings", pgedge_vectorizer_api_url);

	/* Initialize curl */
	curl = curl_easy_init();
	if (!curl)
	{
		*error_msg = pstrdup("Failed to initialize libcurl");
		pfree(response.data);
		return NULL;
	}

	/* Set up headers */
	headers = curl_slist_append(headers, "Content-Type: application/json; charset=utf-8");
	snprintf(auth_header, sizeof(auth_header), "Authorization: Bearer %s", api_key);
	headers = curl_slist_append(headers, auth_header);

	/* Configure curl */
	curl_easy_setopt(curl, CURLOPT_URL, url);
	curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
	curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_request);
	curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)strlen(json_request));
	curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
	curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
	curl_easy_setopt(curl, CURLOPT_TIMEOUT, 300L);  /* 5 minute timeout */

	/* Perform the request */
	res = curl_easy_perform(curl);

	if (res != CURLE_OK)
	{
		*error_msg = psprintf("curl_easy_perform() failed: %s", curl_easy_strerror(res));
		goto cleanup;
	}

	/* Check HTTP response code */
	curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response_code);
	if (response_code != 200)
	{
		*error_msg = psprintf("OpenAI API returned HTTP %ld: %s",
							  response_code, response.data);
		goto cleanup;
	}

	/* Parse the response */
	embeddings = parse_batch_embedding_response(response.data, count, dim, error_msg);

cleanup:
	curl_slist_free_all(headers);
	curl_easy_cleanup(curl);
	pfree(json_request);
	pfree(response.data);

	return embeddings;
}

/*
 * Curl write callback
 */
static size_t
write_callback(void *contents, size_t size, size_t nmemb, void *userp)
{
	size_t realsize = size * nmemb;
	ResponseBuffer *mem = (ResponseBuffer *) userp;

	char *ptr = repalloc(mem->data, mem->size + realsize + 1);
	if (!ptr)
		return 0;  /* Out of memory */

	mem->data = ptr;
	memcpy(&(mem->data[mem->size]), contents, realsize);
	mem->size += realsize;
	mem->data[mem->size] = 0;

	return realsize;
}

/*
 * Load API key from file
 */
static char *
load_api_key(const char *filepath, char **error_msg)
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
	expanded_path = expand_tilde(filepath);

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
 * Expand tilde in path
 */
static char *
expand_tilde(const char *path)
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
 * Escape a string for JSON
 */
static char *
escape_json_string(const char *str)
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
 * Parse batch embedding response
 *
 * Expected format:
 * {"data":[{"embedding":[0.1,0.2,...]},{"embedding":[...]}],...}
 *
 * This is a simplified parser. For production, consider using a robust JSON library.
 */
static float **
parse_batch_embedding_response(const char *json_response, int count, int *dim, char **error_msg)
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
			*error_msg = psprintf("Dimension mismatch: expected %d, got %d", *dim, value_idx);
			goto error;
		}

		embedding_idx++;

		/* Find next embedding */
		p = strstr(p, "\"embedding\"");
	}

	if (embedding_idx != count)
	{
		*error_msg = psprintf("Expected %d embeddings, got %d", count, embedding_idx);
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

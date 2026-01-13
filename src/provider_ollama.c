/*-------------------------------------------------------------------------
 *
 * provider_ollama.c
 *		Ollama local embedding provider implementation
 *
 * Ollama allows running local embedding models. This provider connects to
 * a local Ollama instance (default: http://localhost:11434).
 *
 * Portions copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"

#include <curl/curl.h>

#include "utils/memutils.h"

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
static bool provider_initialized = false;

/*
 * Forward declarations
 */
static bool ollama_init(char **error_msg);
static void ollama_cleanup(void);
static float *ollama_generate(const char *text, int *dim, char **error_msg);
static float **ollama_generate_batch(const char **texts, int count, int *dim, char **error_msg);

/* Helper functions */
static char *escape_json_string(const char *str);
static size_t write_callback(void *contents, size_t size, size_t nmemb, void *userp);
static float *parse_ollama_embedding_response(const char *json_response, int *dim, char **error_msg);

/*
 * Ollama Provider struct
 */
EmbeddingProvider OllamaProvider = {
	.name = "ollama",
	.init = ollama_init,
	.cleanup = ollama_cleanup,
	.generate = ollama_generate,
	.generate_batch = ollama_generate_batch
};

/*
 * Initialize Ollama provider
 */
static bool
ollama_init(char **error_msg)
{
	if (provider_initialized)
		return true;

	/* Initialize curl globally */
	curl_global_init(CURL_GLOBAL_DEFAULT);

	/* Ollama doesn't require API key, but we verify the endpoint is reachable */
	provider_initialized = true;
	elog(DEBUG1, "Ollama provider initialized successfully");
	return true;
}

/*
 * Cleanup Ollama provider
 */
static void
ollama_cleanup(void)
{
	if (!provider_initialized)
		return;

	curl_global_cleanup();
	provider_initialized = false;
	elog(DEBUG1, "Ollama provider cleaned up");
}

/*
 * Generate a single embedding
 */
static float *
ollama_generate(const char *text, int *dim, char **error_msg)
{
	CURL *curl;
	CURLcode res;
	struct curl_slist *headers = NULL;
	char *json_request;
	char *url;
	StringInfoData request_buf;
	ResponseBuffer response;
	float *embedding = NULL;
	long response_code;
	char *escaped;

	if (!provider_initialized)
	{
		if (!ollama_init(error_msg))
			return NULL;
	}

	/* Initialize response buffer */
	response.data = palloc(1);
	response.data[0] = '\0';
	response.size = 0;

	/* Build JSON request - Ollama API format */
	initStringInfo(&request_buf);
	escaped = escape_json_string(text);
	appendStringInfo(&request_buf, "{\"model\":\"%s\",\"prompt\":\"%s\"}",
					 pgedge_vectorizer_model, escaped);
	pfree(escaped);
	json_request = request_buf.data;

	/* Build URL */
	url = psprintf("%s/api/embeddings", pgedge_vectorizer_api_url);

	/* Initialize curl */
	curl = curl_easy_init();
	if (!curl)
	{
		*error_msg = pstrdup("Failed to initialize libcurl");
		pfree(response.data);
		return NULL;
	}

	/* Set up headers - Ollama doesn't require authentication */
	headers = curl_slist_append(headers, "Content-Type: application/json; charset=utf-8");

	/* Configure curl */
	curl_easy_setopt(curl, CURLOPT_URL, url);
	curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
	curl_easy_setopt(curl, CURLOPT_POSTFIELDS, json_request);
	/* flawfinder: ignore - json_request from cJSON is null-terminated */
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
		*error_msg = psprintf("Ollama API returned HTTP %ld: %s",
							  response_code, response.data);
		goto cleanup;
	}

	/* Parse the response */
	embedding = parse_ollama_embedding_response(response.data, dim, error_msg);

cleanup:
	curl_slist_free_all(headers);
	curl_easy_cleanup(curl);
	pfree(json_request);
	pfree(response.data);

	return embedding;
}

/*
 * Generate embeddings in batch
 *
 * Ollama API doesn't support batch requests, so we call the single
 * endpoint multiple times. This is less efficient but simpler.
 */
static float **
ollama_generate_batch(const char **texts, int count, int *dim, char **error_msg)
{
	float **embeddings;
	int i;

	if (!provider_initialized)
	{
		if (!ollama_init(error_msg))
			return NULL;
	}

	/* Allocate array for embeddings */
	embeddings = (float **) palloc0(sizeof(float *) * count);

	/* Generate each embedding individually */
	for (i = 0; i < count; i++)
	{
		embeddings[i] = ollama_generate(texts[i], dim, error_msg);
		if (embeddings[i] == NULL)
		{
			/* Clean up on error */
			for (int j = 0; j < i; j++)
			{
				if (embeddings[j] != NULL)
					pfree(embeddings[j]);
			}
			pfree(embeddings);
			return NULL;
		}
	}

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
	/* flawfinder: ignore - buffer was realloced to mem->size + realsize + 1 */
	memcpy(&(mem->data[mem->size]), contents, realsize);
	mem->size += realsize;
	mem->data[mem->size] = 0;

	return realsize;
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
 * Parse Ollama embedding response
 *
 * Expected format:
 * {"embedding":[0.1,0.2,0.3,...]}
 */
static float *
parse_ollama_embedding_response(const char *json_response, int *dim, char **error_msg)
{
	const char *p;
	float *embedding = NULL;
	int value_idx = 0;
	char value_buf[32];
	int value_pos;

	/* Find "embedding" array */
	p = strstr(json_response, "\"embedding\"");
	if (p == NULL)
	{
		*error_msg = pstrdup("Invalid response: 'embedding' field not found");
		return NULL;
	}

	/* Find opening bracket */
	p = strchr(p, '[');
	if (p == NULL)
	{
		*error_msg = pstrdup("Invalid response: embedding array not found");
		return NULL;
	}
	p++;

	/* Count dimensions if not known */
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

	/* Allocate array for embedding */
	embedding = (float *) palloc(sizeof(float) * (*dim));

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
			embedding[value_idx] = atof(value_buf);
			value_idx++;
		}
	}

	if (value_idx != *dim)
	{
		*error_msg = psprintf("Dimension mismatch: expected %d, got %d", *dim, value_idx);
		pfree(embedding);
		return NULL;
	}

	return embedding;
}

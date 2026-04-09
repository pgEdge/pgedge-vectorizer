/*-------------------------------------------------------------------------
 *
 * provider_gemini.c
 *		Google Gemini embedding provider implementation
 *
 * Gemini uses a different API format from OpenAI:
 * - Auth via x-goog-api-key header (not Bearer token)
 * - Model name is part of the URL path
 * - Different request/response JSON structure
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "provider_common.h"

/* Default base URL for Gemini API */
#define GEMINI_DEFAULT_BASE_URL "https://generativelanguage.googleapis.com/v1beta"

/*
 * Static variables
 */
static char *api_key = NULL;
static bool provider_initialized = false;

/*
 * Forward declarations
 */
static bool gemini_init(char **error_msg);
static void gemini_cleanup(void);
static float *gemini_generate(const char *text, int *dim, char **error_msg);
static float **gemini_generate_batch(const char **texts, int count, int *dim,
									 char **error_msg);

/* Gemini-specific response parsers */
static float *parse_gemini_embedding_response(const char *json_response,
											  int *dim, char **error_msg);
static float **parse_gemini_batch_embedding_response(const char *json_response,
													 int count, int *dim,
													 char **error_msg);

/*
 * Gemini Provider struct
 */
EmbeddingProvider GeminiProvider = {
	.name = "gemini",
	.init = gemini_init,
	.cleanup = gemini_cleanup,
	.generate = gemini_generate,
	.generate_batch = gemini_generate_batch
};

/*
 * Initialize Gemini provider
 */
static bool
gemini_init(char **error_msg)
{
	if (provider_initialized)
		return true;

	curl_global_init(CURL_GLOBAL_DEFAULT);

	/* Gemini always requires an API key */
	api_key = provider_load_api_key(pgedge_vectorizer_api_key_file, error_msg);
	if (api_key == NULL)
	{
		curl_global_cleanup();
		return false;
	}

	provider_initialized = true;
	elog(DEBUG1, "Gemini provider initialized successfully");
	return true;
}

/*
 * Cleanup Gemini provider
 */
static void
gemini_cleanup(void)
{
	if (!provider_initialized)
		return;

	if (api_key != NULL)
	{
		/* flawfinder: ignore - api_key is palloc'd, always null-terminated */
		memset(api_key, 0, strlen(api_key));
		pfree(api_key);
		api_key = NULL;
	}

	curl_global_cleanup();
	provider_initialized = false;
	elog(DEBUG1, "Gemini provider cleaned up");
}

/*
 * Generate a single embedding
 *
 * Gemini single embedding endpoint:
 * POST {base_url}/models/{model}:embedContent
 * Body: {"model":"models/{model}","content":{"parts":[{"text":"..."}]}}
 * Response: {"embedding":{"values":[0.1,0.2,...]}}
 */
static float *
gemini_generate(const char *text, int *dim, char **error_msg)
{
	char *json_request;
	char *url;
	const char *base_url;
	char *escaped;
	char auth_header[512];
	StringInfoData request_buf;
	ResponseBuffer response;
	float *embedding;

	if (!provider_initialized)
	{
		if (!gemini_init(error_msg))
			return NULL;
	}

	/* Build JSON request - Gemini format */
	initStringInfo(&request_buf);
	escaped = provider_escape_json_string(text);
	appendStringInfo(&request_buf,
					 "{\"model\":\"models/%s\","
					 "\"content\":{\"parts\":[{\"text\":\"%s\"}]}}",
					 pgedge_vectorizer_model, escaped);
	pfree(escaped);
	json_request = request_buf.data;

	/* Build URL - model name is in the path */
	base_url = (pgedge_vectorizer_api_url != NULL &&
				pgedge_vectorizer_api_url[0] != '\0')
		? pgedge_vectorizer_api_url
		: GEMINI_DEFAULT_BASE_URL;
	url = psprintf("%s/models/%s:embedContent", base_url,
				   pgedge_vectorizer_model);

	/* Build auth header - Gemini uses x-goog-api-key */
	snprintf(auth_header, sizeof(auth_header),
			 "x-goog-api-key: %s", api_key);

	/* Perform request */
	if (!provider_do_curl_request(url, auth_header, json_request,
								  "Gemini", &response, error_msg))
	{
		pfree(json_request);
		pfree(url);
		if (response.data)
			pfree(response.data);
		return NULL;
	}

	/* Parse Gemini-specific response */
	embedding = parse_gemini_embedding_response(response.data, dim, error_msg);

	pfree(json_request);
	pfree(url);
	pfree(response.data);
	return embedding;
}

/*
 * Generate embeddings in batch
 *
 * Gemini batch endpoint:
 * POST {base_url}/models/{model}:batchEmbedContents
 * Body: {"requests":[{"model":"models/{model}","content":{"parts":[{"text":"..."}]}}, ...]}
 * Response: {"embeddings":[{"values":[0.1,0.2,...]}, ...]}
 */
static float **
gemini_generate_batch(const char **texts, int count, int *dim, char **error_msg)
{
	char *json_request;
	char *url;
	const char *base_url;
	char auth_header[512];
	StringInfoData request_buf;
	ResponseBuffer response;
	float **embeddings;

	if (!provider_initialized)
	{
		if (!gemini_init(error_msg))
			return NULL;
	}

	/* Build JSON request - Gemini batch format */
	initStringInfo(&request_buf);
	appendStringInfo(&request_buf, "{\"requests\":[");
	for (int i = 0; i < count; i++)
	{
		char *escaped = provider_escape_json_string(texts[i]);
		if (i > 0)
			appendStringInfoChar(&request_buf, ',');
		appendStringInfo(&request_buf,
						 "{\"model\":\"models/%s\","
						 "\"content\":{\"parts\":[{\"text\":\"%s\"}]}}",
						 pgedge_vectorizer_model, escaped);
		pfree(escaped);
	}
	appendStringInfo(&request_buf, "]}");
	json_request = request_buf.data;

	/* Build URL */
	base_url = (pgedge_vectorizer_api_url != NULL &&
				pgedge_vectorizer_api_url[0] != '\0')
		? pgedge_vectorizer_api_url
		: GEMINI_DEFAULT_BASE_URL;
	url = psprintf("%s/models/%s:batchEmbedContents", base_url,
				   pgedge_vectorizer_model);

	/* Build auth header */
	snprintf(auth_header, sizeof(auth_header),
			 "x-goog-api-key: %s", api_key);

	/* Perform request */
	if (!provider_do_curl_request(url, auth_header, json_request,
								  "Gemini", &response, error_msg))
	{
		pfree(json_request);
		pfree(url);
		if (response.data)
			pfree(response.data);
		return NULL;
	}

	/* Parse Gemini batch response */
	embeddings = parse_gemini_batch_embedding_response(response.data, count,
													   dim, error_msg);

	pfree(json_request);
	pfree(url);
	pfree(response.data);
	return embeddings;
}

/*
 * Parse Gemini single embedding response
 *
 * Expected format: {"embedding":{"values":[0.1,0.2,...]}}
 */
static float *
parse_gemini_embedding_response(const char *json_response, int *dim,
								char **error_msg)
{
	const char *p;
	float *embedding = NULL;
	int value_idx = 0;
	char value_buf[32];
	int value_pos;

	/* Find "values" array inside "embedding" object */
	p = strstr(json_response, "\"embedding\"");
	if (p == NULL)
	{
		*error_msg = pstrdup("Invalid response: 'embedding' field not found");
		return NULL;
	}

	p = strstr(p, "\"values\"");
	if (p == NULL)
	{
		*error_msg = pstrdup("Invalid response: 'values' field not found");
		return NULL;
	}

	/* Find opening bracket */
	p = strchr(p, '[');
	if (p == NULL)
	{
		*error_msg = pstrdup("Invalid response: values array not found");
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

	/* Allocate array */
	embedding = (float *) palloc(sizeof(float) * (*dim));

	/* Parse values */
	while (value_idx < *dim && *p && *p != ']')
	{
		while (*p && (*p == ' ' || *p == ',' || *p == '\t' || *p == '\n'))
			p++;

		if (*p == ']')
			break;

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
		*error_msg = psprintf("Dimension mismatch: expected %d, got %d",
							  *dim, value_idx);
		pfree(embedding);
		return NULL;
	}

	return embedding;
}

/*
 * Parse Gemini batch embedding response
 *
 * Expected format: {"embeddings":[{"values":[0.1,0.2,...]},{"values":[...]}]}
 */
static float **
parse_gemini_batch_embedding_response(const char *json_response, int count,
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

	/* Find "embeddings" array */
	p = strstr(json_response, "\"embeddings\"");
	if (p == NULL)
	{
		*error_msg = pstrdup("Invalid response: 'embeddings' field not found");
		goto error;
	}

	/* Find first "values" array */
	p = strstr(p, "\"values\"");
	if (p == NULL)
	{
		*error_msg = pstrdup("Invalid response: 'values' field not found");
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
			while (*p && (*p == ' ' || *p == ',' || *p == '\t' || *p == '\n'))
				p++;

			if (*p == ']')
				break;

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

		/* Find next values array */
		p = strstr(p, "\"values\"");
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

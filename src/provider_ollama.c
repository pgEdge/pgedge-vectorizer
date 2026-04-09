/*-------------------------------------------------------------------------
 *
 * provider_ollama.c
 *		Ollama local embedding provider implementation
 *
 * Ollama allows running local embedding models. This provider connects to
 * a local Ollama instance. Uses shared infrastructure from provider_common.c
 * but keeps its own request format and response parser.
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "provider_common.h"

/* Default base URL for Ollama */
#define OLLAMA_DEFAULT_BASE_URL "http://localhost:11434"

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
static float **ollama_generate_batch(const char **texts, int count, int *dim,
									 char **error_msg);

/* Ollama-specific response parser */
static float *parse_ollama_embedding_response(const char *json_response,
											  int *dim, char **error_msg);

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

	curl_global_init(CURL_GLOBAL_DEFAULT);

	/* Ollama doesn't require API key */
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
	char *json_request;
	char *url;
	const char *base_url;
	char *escaped;
	StringInfoData request_buf;
	ResponseBuffer response;
	float *embedding;

	if (!provider_initialized)
	{
		if (!ollama_init(error_msg))
			return NULL;
	}

	/* Build JSON request - Ollama API format */
	initStringInfo(&request_buf);
	escaped = provider_escape_json_string(text);
	appendStringInfo(&request_buf, "{\"model\":\"%s\",\"prompt\":\"%s\"}",
					 pgedge_vectorizer_model, escaped);
	pfree(escaped);
	json_request = request_buf.data;

	/* Build URL */
	base_url = (pgedge_vectorizer_api_url != NULL &&
				pgedge_vectorizer_api_url[0] != '\0')
		? pgedge_vectorizer_api_url
		: OLLAMA_DEFAULT_BASE_URL;
	url = psprintf("%s/api/embeddings", base_url);

	/* Perform request - no auth header for Ollama */
	if (!provider_do_curl_request(url, NULL, json_request,
								  "Ollama", &response, error_msg))
	{
		pfree(json_request);
		pfree(url);
		if (response.data)
			pfree(response.data);
		return NULL;
	}

	/* Parse Ollama-specific response */
	embedding = parse_ollama_embedding_response(response.data, dim, error_msg);

	pfree(json_request);
	pfree(url);
	pfree(response.data);
	return embedding;
}

/*
 * Generate embeddings in batch
 *
 * Ollama API doesn't support batch requests, so we call the single
 * endpoint multiple times.
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

	embeddings = (float **) palloc0(sizeof(float *) * count);

	for (i = 0; i < count; i++)
	{
		embeddings[i] = ollama_generate(texts[i], dim, error_msg);
		if (embeddings[i] == NULL)
		{
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
 * Parse Ollama embedding response
 *
 * Expected format: {"embedding":[0.1,0.2,0.3,...]}
 */
static float *
parse_ollama_embedding_response(const char *json_response, int *dim,
								char **error_msg)
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

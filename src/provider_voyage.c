/*-------------------------------------------------------------------------
 *
 * provider_voyage.c
 *		Voyage AI embedding provider implementation
 *
 * Voyage AI provides high-quality embeddings. The API is compatible
 * with OpenAI's API format. Uses shared infrastructure from
 * provider_common.c.
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "provider_common.h"

/* Default base URL for Voyage AI API */
#define VOYAGE_DEFAULT_BASE_URL "https://api.voyageai.com/v1"

/*
 * Static variables
 */
static char *api_key = NULL;
static bool provider_initialized = false;

/*
 * Forward declarations
 */
static bool voyage_init(char **error_msg);
static void voyage_cleanup(void);
static float *voyage_generate(const char *text, int *dim, char **error_msg);
static float **voyage_generate_batch(const char **texts, int count, int *dim,
									 char **error_msg);

/*
 * Voyage AI Provider struct
 */
EmbeddingProvider VoyageProvider = {
	.name = "voyage",
	.init = voyage_init,
	.cleanup = voyage_cleanup,
	.generate = voyage_generate,
	.generate_batch = voyage_generate_batch
};

/*
 * Initialize Voyage provider
 */
static bool
voyage_init(char **error_msg)
{
	if (provider_initialized)
		return true;

	curl_global_init(CURL_GLOBAL_DEFAULT);

	/* Voyage always requires an API key */
	api_key = provider_load_api_key(pgedge_vectorizer_api_key_file, error_msg);
	if (api_key == NULL)
	{
		curl_global_cleanup();
		return false;
	}

	provider_initialized = true;
	elog(DEBUG1, "Voyage AI provider initialized successfully");
	return true;
}

/*
 * Cleanup Voyage AI provider
 */
static void
voyage_cleanup(void)
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
	elog(DEBUG1, "Voyage AI provider cleaned up");
}

/*
 * Generate a single embedding
 */
static float *
voyage_generate(const char *text, int *dim, char **error_msg)
{
	const char *texts[1] = {text};
	float **embeddings;
	float *result;

	embeddings = voyage_generate_batch(texts, 1, dim, error_msg);
	if (embeddings == NULL)
		return NULL;

	result = embeddings[0];
	pfree(embeddings);
	return result;
}

/*
 * Generate embeddings in batch
 */
static float **
voyage_generate_batch(const char **texts, int count, int *dim, char **error_msg)
{
	char *json_request;
	char *url;
	const char *base_url;
	char auth_header[512];
	ResponseBuffer response;
	float **embeddings;

	if (!provider_initialized)
	{
		if (!voyage_init(error_msg))
			return NULL;
	}

	/* Build request body */
	json_request = provider_build_openai_request(texts, count,
												 pgedge_vectorizer_model);

	/* Build URL */
	base_url = (pgedge_vectorizer_api_url != NULL &&
				pgedge_vectorizer_api_url[0] != '\0')
		? pgedge_vectorizer_api_url
		: VOYAGE_DEFAULT_BASE_URL;
	url = psprintf("%s/embeddings", base_url);

	/* Build auth header */
	snprintf(auth_header, sizeof(auth_header),
			 "Authorization: Bearer %s", api_key);

	/* Perform request */
	if (!provider_do_curl_request(url, auth_header, json_request,
								  "Voyage AI", &response, error_msg))
	{
		pfree(json_request);
		pfree(url);
		if (response.data)
			pfree(response.data);
		return NULL;
	}

	/* Parse response */
	embeddings = provider_parse_openai_embedding_response(response.data, count,
														  dim, error_msg);

	pfree(json_request);
	pfree(url);
	pfree(response.data);
	return embeddings;
}

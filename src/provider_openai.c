/*-------------------------------------------------------------------------
 *
 * provider_openai.c
 *		OpenAI embedding provider implementation
 *
 * Uses shared infrastructure from provider_common.c. Supports custom
 * base URLs for OpenAI-compatible local providers (LM Studio, Docker
 * Model Runner, EXO) where API key is optional.
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "provider_common.h"

/* Default base URL for OpenAI API */
#define OPENAI_DEFAULT_BASE_URL "https://api.openai.com/v1"

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
static float **openai_generate_batch(const char **texts, int count, int *dim,
									 char **error_msg);

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
 *
 * API key is required when using the default OpenAI URL. When a custom
 * URL is set (for local OpenAI-compatible providers), key loading is
 * attempted but failure is not fatal.
 */
static bool
openai_init(char **error_msg)
{
	bool using_custom_url;

	if (provider_initialized)
		return true;

	/* Initialize curl globally */
	curl_global_init(CURL_GLOBAL_DEFAULT);

	/* Determine if using a custom URL */
	using_custom_url = (pgedge_vectorizer_api_url != NULL &&
						pgedge_vectorizer_api_url[0] != '\0');

	/* Load API key */
	api_key = provider_load_api_key(pgedge_vectorizer_api_key_file, error_msg);
	if (api_key == NULL)
	{
		if (!using_custom_url)
		{
			/* Default OpenAI URL requires an API key */
			curl_global_cleanup();
			return false;
		}

		/* Custom URL: key is optional (local provider) */
		elog(DEBUG1, "OpenAI provider: no API key loaded (custom URL, key optional)");
		*error_msg = NULL;  /* Clear the error */
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
		/* flawfinder: ignore - api_key is palloc'd, always null-terminated */
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

	embeddings = openai_generate_batch(texts, 1, dim, error_msg);
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
openai_generate_batch(const char **texts, int count, int *dim, char **error_msg)
{
	char *json_request;
	char *url;
	const char *base_url;
	char auth_header[512];
	const char *auth_header_ptr = NULL;
	ResponseBuffer response;
	float **embeddings;

	if (!provider_initialized)
	{
		if (!openai_init(error_msg))
			return NULL;
	}

	/* Build request body */
	json_request = provider_build_openai_request(texts, count,
												 pgedge_vectorizer_model);

	/* Build URL */
	base_url = (pgedge_vectorizer_api_url != NULL &&
				pgedge_vectorizer_api_url[0] != '\0')
		? pgedge_vectorizer_api_url
		: OPENAI_DEFAULT_BASE_URL;
	url = psprintf("%s/embeddings", base_url);

	/* Build auth header if we have a key */
	if (api_key != NULL)
	{
		snprintf(auth_header, sizeof(auth_header),
				 "Authorization: Bearer %s", api_key);
		auth_header_ptr = auth_header;
	}

	/* Perform request */
	if (!provider_do_curl_request(url, auth_header_ptr, json_request,
								  "OpenAI", &response, error_msg))
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

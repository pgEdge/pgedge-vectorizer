/*-------------------------------------------------------------------------
 *
 * provider.c
 *		Provider abstraction layer for embedding generation
 *
 * This file implements the provider registry and selection logic.
 *
 * Copyright (c) 2025, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"

/*
 * Provider registry - Add new providers here
 */
static EmbeddingProvider *providers[] = {
	&OpenAIProvider,
	/* Add more providers here as they are implemented:
	 * &AnthropicProvider,
	 * &OllamaProvider,
	 */
	NULL  /* Sentinel */
};

/*
 * Register all embedding providers
 */
void
register_embedding_providers(void)
{
	int count = 0;

	for (int i = 0; providers[i] != NULL; i++)
	{
		count++;
		elog(DEBUG1, "Registered embedding provider: %s", providers[i]->name);
	}

	elog(DEBUG1, "Total %d embedding provider(s) registered", count);
}

/*
 * Get an embedding provider by name
 *
 * Returns NULL if the provider is not found.
 */
EmbeddingProvider *
get_embedding_provider(const char *name)
{
	if (name == NULL || name[0] == '\0')
		return NULL;

	for (int i = 0; providers[i] != NULL; i++)
	{
		if (strcmp(providers[i]->name, name) == 0)
			return providers[i];
	}

	/* Provider not found */
	elog(WARNING, "Embedding provider '%s' not found", name);
	return NULL;
}

/*
 * Get the currently configured provider
 *
 * This is a convenience function that reads the GUC and returns the provider.
 */
EmbeddingProvider *
get_current_provider(void)
{
	EmbeddingProvider *provider;

	if (pgedge_vectorizer_provider == NULL || pgedge_vectorizer_provider[0] == '\0')
	{
		elog(ERROR, "pgedge_vectorizer.provider is not set");
		return NULL;
	}

	provider = get_embedding_provider(pgedge_vectorizer_provider);
	if (provider == NULL)
	{
		elog(ERROR, "configured provider '%s' is not available",
			 pgedge_vectorizer_provider);
	}

	return provider;
}

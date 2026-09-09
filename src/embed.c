/*-------------------------------------------------------------------------
 *
 * embed.c
 *		Embedding generation functions for queries
 *
 * This file implements SQL-callable functions for generating embeddings
 * from text queries, allowing users to query vectorized data entirely
 * through SQL without external embedding generation.
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"
#include "executor/spi.h"
#include "utils/builtins.h"

/*
 * SQL-callable function to generate an embedding from query text
 *
 * This function takes a text query and returns a vector embedding using
 * the configured provider (OpenAI, Voyage, or Ollama).
 */
/*
 * Resolve the provider for one call.
 *
 * A NULL or empty name means fall back to the GUC, which is exactly what a
 * vectorizer with no override records, so the same rule serves both these
 * SQL-callable functions and the worker.
 */
static EmbeddingProvider *
resolve_provider(const char *name)
{
	const char		   *use;
	EmbeddingProvider  *provider;

	use = (name != NULL && name[0] != '\0') ? name : pgedge_vectorizer_provider;

	if (use == NULL || use[0] == '\0')
		elog(ERROR, "pgedge_vectorizer.provider is not set");

	provider = get_embedding_provider(use);
	if (provider == NULL)
		elog(ERROR, "embedding provider \"%s\" is not available", use);

	return provider;
}

/*
 * As resolve_provider(), for the model name.
 *
 * An unset model is a configuration error rather than something to send: the
 * providers interpolate this straight into their request bodies, so an empty
 * GUC would put "model":"" on the wire and a NULL one would be dereferenced
 * while escaping it. resolve_provider() already refuses an unset provider for
 * the same reason.
 */
static const char *
resolve_model(const char *model)
{
	const char *use;

	use = (model != NULL && model[0] != '\0') ? model : pgedge_vectorizer_model;

	if (use == NULL || use[0] == '\0')
		elog(ERROR, "pgedge_vectorizer.model is not set");

	return use;
}

/* Read an optional text argument as a cstring, or NULL if it was not given. */
static char *
optional_text_arg(FunctionCallInfo fcinfo, int argno)
{
	if (PG_NARGS() <= argno || PG_ARGISNULL(argno))
		return NULL;

	return text_to_cstring(PG_GETARG_TEXT_PP(argno));
}

PG_FUNCTION_INFO_V1(pgedge_vectorizer_generate_embedding);
PG_FUNCTION_INFO_V1(pgedge_vectorizer_detect_embedding_dimension);

Datum
pgedge_vectorizer_generate_embedding(PG_FUNCTION_ARGS)
{
	text *query_text;
	char *query;
	EmbeddingProvider *provider;
	float *embedding;
	int dim = 0;
	char *error_msg = NULL;
	StringInfoData vector_str;
	int ret;
	bool isnull;
	Datum result;
	const char *model;

	/* Check for NULL input */
	if (PG_ARGISNULL(0))
	{
		elog(ERROR, "query text cannot be NULL");
		PG_RETURN_NULL();
	}

	/* Get input text */
	query_text = PG_GETARG_TEXT_PP(0);
	query = text_to_cstring(query_text);

	/* Validate non-empty text */
	if (query[0] == '\0')
	{
		elog(ERROR, "query text cannot be empty");
		PG_RETURN_NULL();
	}

	/*
	 * Provider and model fall back to the GUCs when not given, so an
	 * existing one-argument call behaves exactly as it did.
	 */
	provider = resolve_provider(optional_text_arg(fcinfo, 1));
	model = resolve_model(optional_text_arg(fcinfo, 2));

	/* Initialize the provider if needed */
	if (provider->init != NULL)
	{
		if (!provider->init(&error_msg))
		{
			elog(ERROR, "failed to initialize provider '%s': %s",
				 provider->name,
				 error_msg ? error_msg : "unknown error");
			PG_RETURN_NULL();
		}
	}

	/* Generate embedding */
	embedding = provider->generate(query, model, &dim, &error_msg);
	if (embedding == NULL)
	{
		elog(ERROR, "failed to generate embedding: %s",
			 error_msg ? error_msg : "unknown error");
		if (error_msg)
			pfree(error_msg);
		PG_RETURN_NULL();
	}

	/* Build vector string representation: [0.1, 0.2, 0.3, ...] */
	initStringInfo(&vector_str);
	appendStringInfoChar(&vector_str, '[');
	for (int i = 0; i < dim; i++)
	{
		if (i > 0)
			appendStringInfoChar(&vector_str, ',');
		appendStringInfo(&vector_str, "%.8g", embedding[i]);
	}
	appendStringInfoChar(&vector_str, ']');

	/* Free the embedding array */
	pfree(embedding);

	/* Use SPI to convert string to vector type */
	if (SPI_connect() != SPI_OK_CONNECT)
	{
		pfree(vector_str.data);
		elog(ERROR, "failed to connect to SPI");
		PG_RETURN_NULL();
	}

	/* Execute the cast to vector */
	ret = SPI_execute(psprintf("SELECT '%s'::vector", vector_str.data),
					  true, 1);

	if (ret != SPI_OK_SELECT || SPI_processed != 1)
	{
		SPI_finish();
		pfree(vector_str.data);
		elog(ERROR, "failed to convert embedding to vector type");
		PG_RETURN_NULL();
	}

	/* Get the result */
	result = SPI_getbinval(SPI_tuptable->vals[0],
						   SPI_tuptable->tupdesc,
						   1,
						   &isnull);

	if (isnull)
	{
		SPI_finish();
		pfree(vector_str.data);
		elog(ERROR, "vector conversion returned NULL");
		PG_RETURN_NULL();
	}

	/* Copy the result to the upper executor context */
	result = SPI_datumTransfer(result,
							   false,  /* typByVal for vector (assume pass by reference) */
							   -1);    /* typLen for vector (assume varlena) */

	SPI_finish();
	pfree(vector_str.data);

	PG_RETURN_DATUM(result);
}

/*
 * SQL-callable function to detect the embedding dimension of the
 * currently configured provider/model by generating a probe embedding.
 */
Datum
pgedge_vectorizer_detect_embedding_dimension(PG_FUNCTION_ARGS)
{
	EmbeddingProvider *provider;
	float *embedding;
	int dim = 0;
	char *error_msg = NULL;
	const char *model;

	/*
	 * The probe has to use the provider and model whose dimension is being
	 * asked about, which is not necessarily the configured one: a vectorizer
	 * created with an override needs the dimension of that model, not of
	 * whatever the GUCs happen to name.
	 */
	provider = resolve_provider(optional_text_arg(fcinfo, 0));
	model = resolve_model(optional_text_arg(fcinfo, 1));

	/* Initialize the provider if needed */
	if (provider->init != NULL)
	{
		if (!provider->init(&error_msg))
		{
			elog(ERROR, "failed to initialize provider '%s': %s",
				 provider->name,
				 error_msg ? error_msg : "unknown error");
			PG_RETURN_NULL();
		}
	}

	/* Generate a probe embedding to detect dimension */
	embedding = provider->generate("dimension probe", model, &dim, &error_msg);
	if (embedding == NULL)
	{
		elog(ERROR, "failed to detect embedding dimension: %s",
			 error_msg ? error_msg : "unknown error");
		if (error_msg)
			pfree(error_msg);
		PG_RETURN_NULL();
	}

	pfree(embedding);

	PG_RETURN_INT32(dim);
}

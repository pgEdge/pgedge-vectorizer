/*-------------------------------------------------------------------------
 *
 * embed.c
 *		Embedding generation functions for queries
 *
 * This file implements SQL-callable functions for generating embeddings
 * from text queries, allowing users to query vectorized data entirely
 * through SQL without external embedding generation.
 *
 * Portions copyright (c) 2025, pgEdge, Inc.
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
PG_FUNCTION_INFO_V1(pgedge_vectorizer_generate_embedding);

Datum
pgedge_vectorizer_generate_embedding(PG_FUNCTION_ARGS)
{
	text *query_text;
	char *query;
	EmbeddingProvider *provider;
	float *embedding;
	int dim;
	char *error_msg = NULL;
	StringInfoData vector_str;
	int ret;
	bool isnull;
	Datum result;

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

	/* Get the current provider */
	provider = get_current_provider();
	if (provider == NULL)
	{
		elog(ERROR, "no embedding provider configured");
		PG_RETURN_NULL();
	}

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
	embedding = provider->generate(query, &dim, &error_msg);
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

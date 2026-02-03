/*-------------------------------------------------------------------------
 *
 * chunking.c
 *		Text chunking implementation
 *
 * This file implements various text chunking strategies for vectorization.
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"
#include "catalog/pg_type.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"

/* Forward declarations */
/* chunk_by_tokens is declared in header for use by hybrid_chunking.c fallback */

/*
 * Parse chunk strategy string
 */
ChunkStrategy
parse_chunk_strategy(const char *strategy_str)
{
	if (strategy_str == NULL)
		return CHUNK_STRATEGY_TOKEN;

	if (pg_strcasecmp(strategy_str, "token_based") == 0 ||
		pg_strcasecmp(strategy_str, "token") == 0)
		return CHUNK_STRATEGY_TOKEN;
	else if (pg_strcasecmp(strategy_str, "semantic") == 0)
		return CHUNK_STRATEGY_SEMANTIC;
	else if (pg_strcasecmp(strategy_str, "markdown") == 0)
		return CHUNK_STRATEGY_MARKDOWN;
	else if (pg_strcasecmp(strategy_str, "sentence") == 0)
		return CHUNK_STRATEGY_SENTENCE;
	else if (pg_strcasecmp(strategy_str, "recursive") == 0)
		return CHUNK_STRATEGY_RECURSIVE;
	else if (pg_strcasecmp(strategy_str, "hybrid") == 0)
		return CHUNK_STRATEGY_HYBRID;

	elog(WARNING, "Unknown chunk strategy '%s', defaulting to token_based",
		 strategy_str);
	return CHUNK_STRATEGY_TOKEN;
}

/*
 * Main chunking function
 *
 * Chunks text according to the specified strategy and configuration.
 * Returns a PostgreSQL text array.
 */
ArrayType *
chunk_text(const char *content, ChunkConfig *config)
{
	if (content == NULL || content[0] == '\0')
	{
		/* Return empty array */
		return construct_empty_array(TEXTOID);
	}

	switch (config->strategy)
	{
		case CHUNK_STRATEGY_TOKEN:
			return chunk_by_tokens(content, config);

		case CHUNK_STRATEGY_HYBRID:
			return chunk_hybrid(content, config);

		case CHUNK_STRATEGY_MARKDOWN:
			return chunk_markdown(content, config);

		case CHUNK_STRATEGY_SEMANTIC:
		case CHUNK_STRATEGY_SENTENCE:
		case CHUNK_STRATEGY_RECURSIVE:
			/* Not yet implemented - fall back to token-based */
			elog(WARNING, "Chunking strategy not yet implemented, using token_based");
			return chunk_by_tokens(content, config);

		default:
			elog(ERROR, "Invalid chunking strategy: %d", config->strategy);
			return NULL;  /* Not reached */
	}
}

/*
 * Strip non-ASCII characters from text
 *
 * Replaces non-ASCII characters with spaces to avoid API issues.
 */
static char *
strip_non_ascii(const char *text)
{
	int len;
	char *result;
	int i;
	int j;

	if (text == NULL)
		return NULL;

	/* flawfinder: ignore - text from PostgreSQL text datum is null-terminated */
	len = strlen(text);
	result = palloc(len + 1);
	j = 0;

	for (i = 0; i < len; i++)
	{
		unsigned char c = (unsigned char) text[i];

		if (c < 128)
		{
			/* ASCII character - keep it */
			result[j++] = text[i];
		}
		else
		{
			/* Non-ASCII character - replace with space */
			/* Skip consecutive non-ASCII to avoid multiple spaces */
			if (j > 0 && result[j - 1] != ' ')
				result[j++] = ' ';
		}
	}

	result[j] = '\0';
	return result;
}

/*
 * Token-based chunking
 *
 * Splits text into chunks of approximately chunk_size tokens with
 * chunk_overlap tokens overlapping between consecutive chunks.
 *
 * This function is also called directly by hybrid_chunking.c when
 * falling back from markdown/hybrid strategies for plain text.
 */
ArrayType *
chunk_by_tokens(const char *content, ChunkConfig *config)
{
	int content_len;
	int total_tokens;
	List *chunks = NIL;
	int start_offset = 0;
	int chunk_num = 0;
	Datum *chunk_datums;
	int n_chunks;
	ArrayType *result;
	ListCell *lc;
	int i;
	char *processed_content;
	bool should_free = false;

	if (content == NULL || content[0] == '\0')
		return construct_empty_array(TEXTOID);

	/* Strip non-ASCII characters if configured */
	if (pgedge_vectorizer_strip_non_ascii)
	{
		processed_content = strip_non_ascii(content);
		should_free = true;
	}
	else
	{
		processed_content = (char *) content;
	}

	/* flawfinder: ignore - processed_content is null-terminated (from PG or strip_non_ascii) */
	content_len = strlen(processed_content);
	if (content_len == 0)
	{
		if (should_free)
			pfree(processed_content);
		return construct_empty_array(TEXTOID);
	}

	/* Count total tokens */
	total_tokens = count_tokens(processed_content, pgedge_vectorizer_model);

	elog(DEBUG1, "Chunking text: %d chars, ~%d tokens, chunk_size=%d, overlap=%d",
		 content_len, total_tokens, config->chunk_size, config->overlap);

	/* If content is smaller than chunk size, return as single chunk */
	if (total_tokens <= config->chunk_size)
	{
		text *chunk_text = cstring_to_text(processed_content);
		chunks = lappend(chunks, chunk_text);
	}
	else
	{
		/* Split into multiple chunks */
		while (start_offset < content_len)
		{
			int target_offset, end_offset;
			int chunk_tokens;
			text *chunk_text;
			char *chunk_str;

			/* Calculate target end offset for this chunk */
			target_offset = get_char_offset_for_tokens(
				processed_content + start_offset,
				config->chunk_size,
				pgedge_vectorizer_model
			);

			/* Find a good break point (sentence/word boundary) */
			end_offset = find_good_break_point(
				processed_content + start_offset,
				target_offset,
				content_len - start_offset
			);

			/* Ensure we make progress */
			if (end_offset <= 0)
				end_offset = target_offset > 0 ? target_offset : content_len - start_offset;

			/* Extract chunk */
			chunk_str = pnstrdup(processed_content + start_offset, end_offset);
			chunk_tokens = count_tokens(chunk_str, pgedge_vectorizer_model);

			elog(DEBUG2, "Chunk %d: offset=%d, length=%d, ~%d tokens",
				 chunk_num, start_offset, end_offset, chunk_tokens);

			chunk_text = cstring_to_text(chunk_str);
			chunks = lappend(chunks, chunk_text);

			/* Move to next chunk, accounting for overlap */
			/* Calculate overlap offset BEFORE freeing chunk_str */
			if (config->overlap > 0 && config->overlap < chunk_tokens)
			{
				int overlap_offset = get_char_offset_for_tokens(
					chunk_str,  /* Use chunk text, not full remaining text */
					chunk_tokens - config->overlap,
					pgedge_vectorizer_model
				);

				/*
				 * Adjust overlap_offset to a word boundary to avoid starting
				 * the next chunk mid-word. Search forward for a space within
				 * the chunk, as going backward could result in too much overlap
				 * and tiny subsequent chunks.
				 */
				while (overlap_offset < end_offset &&
					   chunk_str[overlap_offset] != ' ' &&
					   chunk_str[overlap_offset] != '\n' &&
					   chunk_str[overlap_offset] != '\t')
				{
					overlap_offset++;
				}

				/*
				 * If we reached the end of chunk without finding a space,
				 * use end_offset (no overlap for this chunk).
				 */
				if (overlap_offset >= end_offset)
				{
					overlap_offset = end_offset;
				}

				start_offset += overlap_offset;
			}
			else
			{
				start_offset += end_offset;
			}

			pfree(chunk_str);
			chunk_num++;

			/* Safety check to prevent infinite loop */
			if (start_offset >= content_len)
				break;

			/* Skip leading whitespace */
			while (start_offset < content_len &&
				   (processed_content[start_offset] == ' ' ||
					processed_content[start_offset] == '\t' ||
					processed_content[start_offset] == '\n' ||
					processed_content[start_offset] == '\r'))
			{
				start_offset++;
			}
		}
	}

	/* Convert list to array */
	n_chunks = list_length(chunks);
	chunk_datums = (Datum *) palloc(n_chunks * sizeof(Datum));

	i = 0;
	foreach(lc, chunks)
	{
		chunk_datums[i++] = PointerGetDatum(lfirst(lc));
	}

	result = construct_array(chunk_datums, n_chunks, TEXTOID, -1, false, TYPALIGN_INT);

	pfree(chunk_datums);
	list_free(chunks);

	/* Free processed_content if we allocated it */
	if (should_free)
		pfree(processed_content);

	elog(DEBUG1, "Created %d chunks from text", n_chunks);

	return result;
}

/*
 * SQL-callable function to chunk text
 */
PG_FUNCTION_INFO_V1(pgedge_vectorizer_chunk_text_sql);

Datum
pgedge_vectorizer_chunk_text_sql(PG_FUNCTION_ARGS)
{
	text *content_text;
	char *content;
	text *strategy_text;
	char *strategy_str;
	int chunk_size;
	int overlap;
	ChunkConfig config;
	ArrayType *result;

	/* Check for NULL inputs */
	if (PG_ARGISNULL(0))
		PG_RETURN_NULL();

	content_text = PG_GETARG_TEXT_PP(0);
	content = text_to_cstring(content_text);

	/* Get strategy (default to configured default) */
	if (PG_ARGISNULL(1))
		strategy_str = pgedge_vectorizer_default_chunk_strategy;
	else
	{
		strategy_text = PG_GETARG_TEXT_PP(1);
		strategy_str = text_to_cstring(strategy_text);
	}

	/* Get chunk size (default to configured default) */
	chunk_size = PG_ARGISNULL(2) ?
		pgedge_vectorizer_default_chunk_size : PG_GETARG_INT32(2);

	/* Get overlap (default to configured default) */
	overlap = PG_ARGISNULL(3) ?
		pgedge_vectorizer_default_chunk_overlap : PG_GETARG_INT32(3);

	/* Build configuration */
	config.strategy = parse_chunk_strategy(strategy_str);
	config.chunk_size = chunk_size;
	config.overlap = overlap;
	config.separators = NULL;

	/* Perform chunking */
	result = chunk_text(content, &config);

	PG_RETURN_ARRAYTYPE_P(result);
}

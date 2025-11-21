/*-------------------------------------------------------------------------
 *
 * tokenizer.c
 *		Text tokenization for chunking
 *
 * This file provides tokenization functionality for text chunking.
 *
 * CURRENT IMPLEMENTATION: Uses character-based approximation (4 chars ≈ 1 token)
 * FUTURE: Integrate tiktoken library for accurate tokenization
 *
 * To integrate tiktoken:
 * 1. Add tiktoken library to build (see https://github.com/openai/tiktoken)
 * 2. Link against tiktoken
 * 3. Replace approximation functions with tiktoken calls
 * 4. Use cl100k_base encoding for OpenAI models
 *
 * Portions copyright (c) 2025, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"

/*
 * Approximate token count
 *
 * This is a simple approximation: ~4 characters per token for English text.
 * This is reasonably accurate for most use cases but not perfect.
 *
 * For production use with OpenAI models, consider integrating tiktoken.
 */
int
count_tokens(const char *text, const char *model)
{
	int char_count = 0;
	int token_estimate;
	const char *p;

	if (text == NULL || text[0] == '\0')
		return 0;

	/* Count characters (UTF-8 aware) */
	for (p = text; *p; p++)
	{
		/* Only count the start of each UTF-8 character */
		if ((*p & 0xC0) != 0x80)
			char_count++;
	}

	/* Estimate tokens (4 chars per token is a reasonable approximation) */
	token_estimate = (char_count + 3) / 4;

	elog(DEBUG2, "Token count estimate: %d (from %d characters)",
		 token_estimate, char_count);

	return token_estimate;
}

/*
 * Tokenize text into token IDs
 *
 * This is a placeholder for tiktoken integration.
 * Currently returns NULL as we don't need actual token IDs for chunking.
 *
 * When integrating tiktoken:
 * - Load the appropriate encoding (e.g., cl100k_base)
 * - Call tiktoken's encode function
 * - Return array of token IDs
 */
int *
tokenize_text(const char *text, const char *model, int *token_count)
{
	/* For now, we don't need actual tokenization, just counting */
	*token_count = count_tokens(text, model);

	elog(DEBUG1, "Tokenization not fully implemented - using approximation");
	return NULL;
}

/*
 * Detokenize token IDs back to text
 *
 * This is a placeholder for tiktoken integration.
 *
 * When integrating tiktoken:
 * - Call tiktoken's decode function
 * - Return the decoded text
 */
char *
detokenize_tokens(const int *tokens, int token_count, const char *model)
{
	/* Placeholder */
	elog(DEBUG1, "Detokenization not implemented");
	return NULL;
}

/*
 * Get character offset for a given token count
 *
 * This function estimates where in the text a certain number of tokens
 * would end. Used for chunking.
 */
int
get_char_offset_for_tokens(const char *text, int target_tokens, const char *model)
{
	int estimated_chars;
	const char *p;
	int actual_chars = 0;

	if (text == NULL || target_tokens <= 0)
		return 0;

	/* Estimate character position (4 chars per token) */
	estimated_chars = target_tokens * 4;

	/* Count actual characters (UTF-8 aware) */
	for (p = text; *p && actual_chars < estimated_chars; p++)
	{
		/* Only count the start of each UTF-8 character */
		if ((*p & 0xC0) != 0x80)
			actual_chars++;
	}

	/* Return byte offset */
	return p - text;
}

/*
 * Find a good break point near the target position
 *
 * Tries to break at sentence or paragraph boundaries if possible.
 */
int
find_good_break_point(const char *text, int target_offset, int max_offset)
{
	int best_offset = target_offset;
	int search_window = 50;  /* Look 50 chars before and after */

	if (target_offset >= max_offset)
		return max_offset;

	/* Look for paragraph break (double newline) */
	for (int offset = target_offset - search_window;
		 offset < target_offset + search_window && offset < max_offset;
		 offset++)
	{
		if (offset > 0 && text[offset-1] == '\n' && text[offset] == '\n')
			return offset;
	}

	/* Look for sentence break (period, question mark, exclamation) */
	for (int offset = target_offset - search_window;
		 offset < target_offset + search_window && offset < max_offset;
		 offset++)
	{
		if (offset > 0 &&
			(text[offset-1] == '.' || text[offset-1] == '?' || text[offset-1] == '!') &&
			(text[offset] == ' ' || text[offset] == '\n'))
		{
			return offset;
		}
	}

	/* Look for word break (space) */
	for (int offset = target_offset - search_window;
		 offset < target_offset + search_window && offset < max_offset;
		 offset++)
	{
		if (text[offset] == ' ' || text[offset] == '\n')
			return offset;
	}

	/* Fall back to target offset */
	return best_offset < max_offset ? best_offset : max_offset;
}

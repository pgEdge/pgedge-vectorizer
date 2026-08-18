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
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"

#include "mb/pg_wchar.h"

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
 * Estimates where in the text a certain number of tokens would end, as a byte
 * offset. Used for chunking.
 *
 * The offset must land between characters. Callers cut there with pnstrdup()
 * and nothing downstream validates the encoding, so an offset inside a
 * character stores a partial one, and any later read that walks characters
 * fails on that row. Counting lead bytes by hand stopped one byte past the
 * last one; pg_mbcharcliplen() clips where a character ends, and does it in
 * the server encoding rather than assuming UTF-8.
 */
int
get_char_offset_for_tokens(const char *text, int target_tokens, const char *model)
{
	int64		estimated_chars;
	int64		byte_bound;
	int			maxlen;
	int			len;

	if (text == NULL || target_tokens <= 0)
		return 0;

	/* Estimate character position (4 chars per token) */
	estimated_chars = (int64) target_tokens * 4;

	/*
	 * Bound the read at what the wanted characters can occupy, so this costs
	 * one chunk rather than the whole remaining text on every call.
	 *
	 * Both bounds saturate at INT_MAX rather than being scaled to fit, and
	 * they saturate independently: shrinking the character limit to keep the
	 * byte span in range would return fewer characters than were asked for and
	 * cut the chunk short.  The SQL entry point takes an unbounded chunk_size,
	 * so it can ask for more than either bound holds.  A text datum cannot
	 * exceed 1GB, so a saturated byte bound just means "to the end".  Computed
	 * in int64 so the product cannot wrap.
	 */
	maxlen = pg_database_encoding_max_length();
	byte_bound = Min(estimated_chars * maxlen, (int64) INT_MAX);
	len = (int) strnlen(text, (size_t) byte_bound);

	return pg_mbcharcliplen(text, len,
							(int) Min(estimated_chars, (int64) INT_MAX));
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
	int search_start;

	if (target_offset >= max_offset)
		return max_offset;

	/* Calculate search start, preventing negative index */
	search_start = target_offset - search_window;
	if (search_start < 0)
		search_start = 0;

	/* Look for paragraph break (double newline) */
	for (int offset = search_start;
		 offset < target_offset + search_window && offset < max_offset;
		 offset++)
	{
		if (offset > 0 && text[offset-1] == '\n' && text[offset] == '\n')
			return offset;
	}

	/* Look for sentence break (period, question mark, exclamation) */
	for (int offset = search_start;
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
	for (int offset = search_start;
		 offset < target_offset + search_window && offset < max_offset;
		 offset++)
	{
		if (text[offset] == ' ' || text[offset] == '\n')
			return offset;
	}

	/* Fall back to target offset */
	return best_offset < max_offset ? best_offset : max_offset;
}

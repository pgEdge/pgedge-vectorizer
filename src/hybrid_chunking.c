/*-------------------------------------------------------------------------
 *
 * hybrid_chunking.c
 *		Hybrid chunking implementation inspired by Docling's approach
 *
 * This implements a two-pass hybrid chunking strategy:
 * 1. Parse document structure (markdown) into hierarchical elements
 * 2. Apply tokenization-aware refinement:
 *    - Split oversized chunks that exceed token limits
 *    - Merge undersized consecutive chunks with same heading context
 *
 * Portions copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"
#include "catalog/pg_type.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"

/* Maximum heading levels in markdown (h1-h6) */
#define MAX_HEADING_LEVELS 6

/* Forward declarations */
static List *split_oversized_chunks(List *chunks, int max_tokens);
static List *merge_undersized_chunks(List *chunks, int min_tokens, int max_tokens);
static HybridChunk *create_hybrid_chunk(const char *content, const char *heading_context);
static void free_hybrid_chunk(HybridChunk *chunk);
static char *build_heading_context(char **heading_stack, int stack_depth);
static bool is_blank_line(const char *line, int len);
static int get_heading_level(const char *line, int len);
static bool is_code_fence(const char *line, int len);
static bool is_list_item(const char *line, int len);
static bool is_blockquote(const char *line, int len);
static bool is_horizontal_rule(const char *line, int len);
static bool is_table_row(const char *line, int len);
static bool is_likely_markdown(const char *content);
static ArrayType *elements_to_chunks_simple(List *elements, ChunkConfig *config);

/*
 * Detect if content is likely to be markdown
 *
 * Returns true if the content contains markdown-specific syntax that
 * would benefit from structure-aware chunking. Falls back to token-based
 * chunking for plain text to avoid unnecessary overhead.
 *
 * Detection criteria (need at least 2 indicators for confidence):
 * - Headings (# at start of line)
 * - Code fences (``` or ~~~)
 * - List items (-, *, +, or numbered)
 * - Blockquotes (>)
 * - Tables (| characters)
 * - Links/images ([text](url) or ![alt](url))
 */
static bool
is_likely_markdown(const char *content)
{
	int indicators = 0;
	const char *pos = content;
	bool at_line_start = true;
	bool has_heading = false;
	bool has_code_fence = false;
	bool has_list = false;
	bool has_blockquote = false;
	bool has_table = false;
	bool has_link = false;

	if (content == NULL || content[0] == '\0')
		return false;

	/* Quick scan for markdown indicators */
	while (*pos != '\0')
	{
		/* Check line-start patterns */
		if (at_line_start)
		{
			/* Skip leading whitespace (up to 3 spaces for markdown) */
			const char *line_start = pos;
			int spaces = 0;
			while (*pos == ' ' && spaces < 4)
			{
				pos++;
				spaces++;
			}

			/* Heading: # at start of line */
			if (*pos == '#' && !has_heading)
			{
				int level = 0;
				while (level < MAX_HEADING_LEVELS && pos[level] == '#')
					level++;
				if (level > 0 && (pos[level] == ' ' || pos[level] == '\t' || pos[level] == '\n' || pos[level] == '\0'))
				{
					has_heading = true;
					indicators++;
				}
			}

			/* Code fence: ``` or ~~~ */
			if ((*pos == '`' || *pos == '~') && !has_code_fence)
			{
				if (pos[1] != '\0' && pos[2] != '\0' &&
					pos[0] == pos[1] && pos[1] == pos[2])
				{
					has_code_fence = true;
					indicators++;
				}
			}

			/* List item: -, *, +, or digit followed by . or ) */
			if (!has_list)
			{
				if ((*pos == '-' || *pos == '*' || *pos == '+') &&
					pos[1] != '\0' && (pos[1] == ' ' || pos[1] == '\t'))
				{
					has_list = true;
					indicators++;
				}
				else if (*pos >= '0' && *pos <= '9')
				{
					const char *p = pos;
					while (*p >= '0' && *p <= '9')
						p++;
					if ((*p == '.' || *p == ')') && p[1] != '\0' && (p[1] == ' ' || p[1] == '\t'))
					{
						has_list = true;
						indicators++;
					}
				}
			}

			/* Blockquote: > at start */
			if (*pos == '>' && !has_blockquote)
			{
				has_blockquote = true;
				indicators++;
			}

			pos = line_start;  /* Reset to scan rest of line */
		}

		/* Check inline patterns */
		/* Table: | character (simple heuristic) */
		if (*pos == '|' && !has_table)
		{
			/* Look for another | on the same line to confirm table */
			const char *p = pos + 1;
			while (*p != '\0' && *p != '\n')
			{
				if (*p == '|')
				{
					has_table = true;
					indicators++;
					break;
				}
				p++;
			}
		}

		/* Links: [text](url) or images: ![alt](url) */
		if (*pos == '[' && !has_link)
		{
			const char *p = pos + 1;
			int bracket_depth = 1;
			while (*p != '\0' && bracket_depth > 0)
			{
				if (*p == '[')
					bracket_depth++;
				else if (*p == ']')
					bracket_depth--;
				p++;
			}
			if (bracket_depth == 0 && *p == '(')
			{
				has_link = true;
				indicators++;
			}
		}

		/* Track line boundaries */
		if (*pos == '\n')
		{
			at_line_start = true;
			pos++;
		}
		else
		{
			at_line_start = false;
			pos++;
		}

		/* Early exit if we have enough indicators */
		if (indicators >= 2)
			return true;
	}

	/* Require at least 1 strong indicator (heading or code fence) or 2 weak indicators */
	if (has_heading || has_code_fence)
		return true;

	return indicators >= 2;
}

/*
 * Parse markdown content into structured elements
 *
 * This function identifies markdown structural elements:
 * - Headings (# through ######)
 * - Code blocks (``` ... ```)
 * - List items (-, *, 1.)
 * - Blockquotes (>)
 * - Tables (| ... |)
 * - Paragraphs (default text blocks)
 */
List *
parse_markdown_structure(const char *content)
{
	List *elements = NIL;
	const char *pos = content;
	const char *line_start;
	int line_len;
	bool in_code_block = false;
	StringInfoData current_block;
	MarkdownElementType current_type = MD_ELEMENT_PARAGRAPH;
	char *heading_stack[MAX_HEADING_LEVELS] = {NULL};
	char *current_heading_context = NULL;

	if (content == NULL || content[0] == '\0')
		return NIL;

	initStringInfo(&current_block);

	while (*pos != '\0')
	{
		int heading_level;

		/* Find end of current line */
		line_start = pos;
		while (*pos != '\0' && *pos != '\n')
			pos++;
		line_len = pos - line_start;

		/* Handle code block toggle */
		if (is_code_fence(line_start, line_len))
		{
			if (in_code_block)
			{
				/* End code block - save accumulated content */
				appendBinaryStringInfo(&current_block, line_start, line_len);
				if (*pos == '\n')
				{
					appendStringInfoChar(&current_block, '\n');
					pos++;
				}

				if (current_block.len > 0)
				{
					MarkdownElement *elem = palloc0(sizeof(MarkdownElement));
					elem->type = MD_ELEMENT_CODE_BLOCK;
					elem->heading_level = 0;
					elem->content = pstrdup(current_block.data);
					elem->token_count = count_tokens(elem->content, pgedge_vectorizer_model);
					elem->heading_context = current_heading_context ? pstrdup(current_heading_context) : NULL;
					elements = lappend(elements, elem);
				}

				resetStringInfo(&current_block);
				in_code_block = false;
				current_type = MD_ELEMENT_PARAGRAPH;
				continue;
			}
			else
			{
				/* Start code block - save any pending content first */
				if (current_block.len > 0)
				{
					MarkdownElement *elem = palloc0(sizeof(MarkdownElement));
					elem->type = current_type;
					elem->heading_level = 0;
					elem->content = pstrdup(current_block.data);
					elem->token_count = count_tokens(elem->content, pgedge_vectorizer_model);
					elem->heading_context = current_heading_context ? pstrdup(current_heading_context) : NULL;
					elements = lappend(elements, elem);
					resetStringInfo(&current_block);
				}

				in_code_block = true;
				current_type = MD_ELEMENT_CODE_BLOCK;
			}
		}

		/* If in code block, just accumulate */
		if (in_code_block)
		{
			appendBinaryStringInfo(&current_block, line_start, line_len);
			if (*pos == '\n')
			{
				appendStringInfoChar(&current_block, '\n');
				pos++;
			}
			continue;
		}

		/* Check for blank line - paragraph separator */
		if (is_blank_line(line_start, line_len))
		{
			if (current_block.len > 0)
			{
				MarkdownElement *elem = palloc0(sizeof(MarkdownElement));
				elem->type = current_type;
				elem->heading_level = 0;
				elem->content = pstrdup(current_block.data);
				elem->token_count = count_tokens(elem->content, pgedge_vectorizer_model);
				elem->heading_context = current_heading_context ? pstrdup(current_heading_context) : NULL;
				elements = lappend(elements, elem);
				resetStringInfo(&current_block);
			}
			current_type = MD_ELEMENT_PARAGRAPH;
			if (*pos == '\n')
				pos++;
			continue;
		}

		/* Check for heading */
		heading_level = get_heading_level(line_start, line_len);
		if (heading_level > 0)
		{
			const char *heading_text;
			int heading_text_len;
			int i;
			MarkdownElement *elem;

			/* Save any pending content */
			if (current_block.len > 0)
			{
				MarkdownElement *pending_elem = palloc0(sizeof(MarkdownElement));
				pending_elem->type = current_type;
				pending_elem->heading_level = 0;
				pending_elem->content = pstrdup(current_block.data);
				pending_elem->token_count = count_tokens(pending_elem->content, pgedge_vectorizer_model);
				pending_elem->heading_context = current_heading_context ? pstrdup(current_heading_context) : NULL;
				elements = lappend(elements, pending_elem);
				resetStringInfo(&current_block);
			}

			/* Update heading stack */
			/* Clear deeper levels */
			for (i = heading_level; i < MAX_HEADING_LEVELS; i++)
			{
				if (heading_stack[i] != NULL)
				{
					pfree(heading_stack[i]);
					heading_stack[i] = NULL;
				}
			}

			/* Extract heading text (skip # symbols and space) */
			heading_text = line_start + heading_level;
			while (*heading_text == ' ' || *heading_text == '\t')
				heading_text++;
			heading_text_len = line_len - (heading_text - line_start);

			/* Store in heading stack */
			if (heading_stack[heading_level - 1] != NULL)
				pfree(heading_stack[heading_level - 1]);
			heading_stack[heading_level - 1] = pnstrdup(heading_text, heading_text_len);

			/* Update current heading context */
			if (current_heading_context != NULL)
				pfree(current_heading_context);
			current_heading_context = build_heading_context(heading_stack, MAX_HEADING_LEVELS);

			/* Create heading element */
			elem = palloc0(sizeof(MarkdownElement));
			elem->type = MD_ELEMENT_HEADING;
			elem->heading_level = heading_level;
			elem->content = pnstrdup(line_start, line_len);
			elem->token_count = count_tokens(elem->content, pgedge_vectorizer_model);
			elem->heading_context = current_heading_context ? pstrdup(current_heading_context) : NULL;
			elements = lappend(elements, elem);

			current_type = MD_ELEMENT_PARAGRAPH;
			if (*pos == '\n')
				pos++;
			continue;
		}

		/* Check for horizontal rule */
		if (is_horizontal_rule(line_start, line_len))
		{
			if (current_block.len > 0)
			{
				MarkdownElement *elem = palloc0(sizeof(MarkdownElement));
				elem->type = current_type;
				elem->heading_level = 0;
				elem->content = pstrdup(current_block.data);
				elem->token_count = count_tokens(elem->content, pgedge_vectorizer_model);
				elem->heading_context = current_heading_context ? pstrdup(current_heading_context) : NULL;
				elements = lappend(elements, elem);
				resetStringInfo(&current_block);
			}

			{
				MarkdownElement *elem = palloc0(sizeof(MarkdownElement));
				elem->type = MD_ELEMENT_HORIZONTAL_RULE;
				elem->heading_level = 0;
				elem->content = pnstrdup(line_start, line_len);
				elem->token_count = 1;
				elem->heading_context = current_heading_context ? pstrdup(current_heading_context) : NULL;
				elements = lappend(elements, elem);
			}

			current_type = MD_ELEMENT_PARAGRAPH;
			if (*pos == '\n')
				pos++;
			continue;
		}

		/* Check for list item */
		if (is_list_item(line_start, line_len))
		{
			/* If switching from non-list, save pending content */
			if (current_type != MD_ELEMENT_LIST_ITEM && current_block.len > 0)
			{
				MarkdownElement *elem = palloc0(sizeof(MarkdownElement));
				elem->type = current_type;
				elem->heading_level = 0;
				elem->content = pstrdup(current_block.data);
				elem->token_count = count_tokens(elem->content, pgedge_vectorizer_model);
				elem->heading_context = current_heading_context ? pstrdup(current_heading_context) : NULL;
				elements = lappend(elements, elem);
				resetStringInfo(&current_block);
			}

			current_type = MD_ELEMENT_LIST_ITEM;
		}

		/* Check for blockquote */
		if (is_blockquote(line_start, line_len))
		{
			if (current_type != MD_ELEMENT_BLOCKQUOTE && current_block.len > 0)
			{
				MarkdownElement *elem = palloc0(sizeof(MarkdownElement));
				elem->type = current_type;
				elem->heading_level = 0;
				elem->content = pstrdup(current_block.data);
				elem->token_count = count_tokens(elem->content, pgedge_vectorizer_model);
				elem->heading_context = current_heading_context ? pstrdup(current_heading_context) : NULL;
				elements = lappend(elements, elem);
				resetStringInfo(&current_block);
			}

			current_type = MD_ELEMENT_BLOCKQUOTE;
		}

		/* Check for table */
		if (is_table_row(line_start, line_len))
		{
			if (current_type != MD_ELEMENT_TABLE && current_block.len > 0)
			{
				MarkdownElement *elem = palloc0(sizeof(MarkdownElement));
				elem->type = current_type;
				elem->heading_level = 0;
				elem->content = pstrdup(current_block.data);
				elem->token_count = count_tokens(elem->content, pgedge_vectorizer_model);
				elem->heading_context = current_heading_context ? pstrdup(current_heading_context) : NULL;
				elements = lappend(elements, elem);
				resetStringInfo(&current_block);
			}

			current_type = MD_ELEMENT_TABLE;
		}

		/* Accumulate line to current block */
		if (current_block.len > 0)
			appendStringInfoChar(&current_block, '\n');
		appendBinaryStringInfo(&current_block, line_start, line_len);

		if (*pos == '\n')
			pos++;
	}

	/* Save final block */
	if (current_block.len > 0)
	{
		MarkdownElement *elem = palloc0(sizeof(MarkdownElement));
		elem->type = current_type;
		elem->heading_level = 0;
		elem->content = pstrdup(current_block.data);
		elem->token_count = count_tokens(elem->content, pgedge_vectorizer_model);
		elem->heading_context = current_heading_context ? pstrdup(current_heading_context) : NULL;
		elements = lappend(elements, elem);
	}

	/* Cleanup */
	pfree(current_block.data);
	for (int i = 0; i < MAX_HEADING_LEVELS; i++)
	{
		if (heading_stack[i] != NULL)
			pfree(heading_stack[i]);
	}
	if (current_heading_context != NULL)
		pfree(current_heading_context);

	return elements;
}

/*
 * Free list of markdown elements
 */
void
free_markdown_elements(List *elements)
{
	ListCell *lc;

	foreach(lc, elements)
	{
		MarkdownElement *elem = (MarkdownElement *) lfirst(lc);
		if (elem->content)
			pfree(elem->content);
		if (elem->heading_context)
			pfree(elem->heading_context);
		pfree(elem);
	}
	list_free(elements);
}

/*
 * Build heading context string from heading stack
 * Format: "# H1 > ## H2 > ### H3"
 */
static char *
build_heading_context(char **heading_stack, int stack_size)
{
	StringInfoData result;
	bool first = true;

	initStringInfo(&result);

	for (int i = 0; i < stack_size; i++)
	{
		if (heading_stack[i] != NULL)
		{
			if (!first)
				appendStringInfoString(&result, " > ");
			first = false;

			/* Add heading level markers */
			for (int j = 0; j <= i; j++)
				appendStringInfoChar(&result, '#');
			appendStringInfoChar(&result, ' ');
			appendStringInfoString(&result, heading_stack[i]);
		}
	}

	if (result.len == 0)
	{
		pfree(result.data);
		return NULL;
	}

	return result.data;
}

/*
 * Create a hybrid chunk with content and heading context
 */
static HybridChunk *
create_hybrid_chunk(const char *content, const char *heading_context)
{
	HybridChunk *chunk = palloc0(sizeof(HybridChunk));
	chunk->content = pstrdup(content);
	chunk->token_count = count_tokens(content, pgedge_vectorizer_model);
	chunk->heading_context = heading_context ? pstrdup(heading_context) : NULL;
	chunk->chunk_index = 0;
	return chunk;
}

/*
 * Free a hybrid chunk
 */
static void
free_hybrid_chunk(HybridChunk *chunk)
{
	if (chunk->content)
		pfree(chunk->content);
	if (chunk->heading_context)
		pfree(chunk->heading_context);
	pfree(chunk);
}

/*
 * Check if line is blank (empty or whitespace only)
 */
static bool
is_blank_line(const char *line, int len)
{
	for (int i = 0; i < len; i++)
	{
		if (line[i] != ' ' && line[i] != '\t' && line[i] != '\r')
			return false;
	}
	return true;
}

/*
 * Get heading level (1-6) from line, or 0 if not a heading
 */
static int
get_heading_level(const char *line, int len)
{
	int level = 0;

	if (len == 0)
		return 0;

	/* Count # at start */
	while (level < len && level < MAX_HEADING_LEVELS && line[level] == '#')
		level++;

	/* Must have at least one # and be followed by space or end of line */
	if (level == 0)
		return 0;
	if (level < len && line[level] != ' ' && line[level] != '\t')
		return 0;

	return level;
}

/*
 * Check if line is a code fence (``` or ~~~)
 */
static bool
is_code_fence(const char *line, int len)
{
	int i = 0;

	/* Skip leading whitespace (up to 3 spaces) */
	while (i < len && i < 3 && line[i] == ' ')
		i++;

	if (len - i < 3)
		return false;

	/* Check for ``` or ~~~ */
	if ((line[i] == '`' && line[i+1] == '`' && line[i+2] == '`') ||
		(line[i] == '~' && line[i+1] == '~' && line[i+2] == '~'))
		return true;

	return false;
}

/*
 * Check if line is a list item
 */
static bool
is_list_item(const char *line, int len)
{
	int i = 0;

	/* Skip leading whitespace */
	while (i < len && (line[i] == ' ' || line[i] == '\t'))
		i++;

	if (i >= len)
		return false;

	/* Check for unordered list markers: -, *, + followed by space/tab */
	if ((line[i] == '-' || line[i] == '*' || line[i] == '+'))
	{
		if (i + 1 < len && (line[i+1] == ' ' || line[i+1] == '\t'))
			return true;
		return false;
	}

	/* Check for ordered list: digit(s) followed by . or ) and space/tab */
	if (line[i] >= '0' && line[i] <= '9')
	{
		while (i < len && line[i] >= '0' && line[i] <= '9')
			i++;
		if (i < len && (line[i] == '.' || line[i] == ')'))
		{
			if (i + 1 < len && (line[i+1] == ' ' || line[i+1] == '\t'))
				return true;
		}
	}

	return false;
}

/*
 * Check if line is a blockquote
 */
static bool
is_blockquote(const char *line, int len)
{
	int i = 0;

	/* Skip leading whitespace (up to 3 spaces) */
	while (i < len && i < 3 && line[i] == ' ')
		i++;

	if (i < len && line[i] == '>')
		return true;

	return false;
}

/*
 * Check if line is a horizontal rule (---, ***, ___)
 */
static bool
is_horizontal_rule(const char *line, int len)
{
	int i = 0;
	char rule_char = '\0';
	int count = 0;

	/* Skip leading whitespace (up to 3 spaces) */
	while (i < len && i < 3 && line[i] == ' ')
		i++;

	if (i >= len)
		return false;

	/* Must start with -, *, or _ */
	if (line[i] != '-' && line[i] != '*' && line[i] != '_')
		return false;

	rule_char = line[i];

	/* Count rule characters (allowing spaces between) */
	while (i < len)
	{
		if (line[i] == rule_char)
			count++;
		else if (line[i] != ' ')
			return false;
		i++;
	}

	/* Must have at least 3 rule characters */
	return count >= 3;
}

/*
 * Check if line is a table row
 */
static bool
is_table_row(const char *line, int len)
{
	bool has_pipe = false;

	for (int i = 0; i < len; i++)
	{
		if (line[i] == '|')
			has_pipe = true;
	}

	/* Simple heuristic: line contains | character */
	return has_pipe;
}

/*
 * Split chunks that exceed the token limit
 *
 * Pass 1 of hybrid refinement: Split oversized chunks
 */
static List *
split_oversized_chunks(List *chunks, int max_tokens)
{
	List *result = NIL;
	ListCell *lc;

	foreach(lc, chunks)
	{
		HybridChunk *chunk = (HybridChunk *) lfirst(lc);

		if (chunk->token_count <= max_tokens)
		{
			/* Chunk is within limits, keep as is */
			result = lappend(result, chunk);
		}
		else
		{
			/* Split oversized chunk */
			const char *content = chunk->content;
			int content_len = strlen(content);
			int start_offset = 0;

			while (start_offset < content_len)
			{
				int target_offset;
				int end_offset;
				char *sub_content;
				HybridChunk *sub_chunk;

				/* Find target end position based on token count */
				target_offset = get_char_offset_for_tokens(
					content + start_offset,
					max_tokens,
					pgedge_vectorizer_model
				);

				/* Find good break point */
				end_offset = find_good_break_point(
					content + start_offset,
					target_offset,
					content_len - start_offset
				);

				/* Ensure progress */
				if (end_offset <= 0)
					end_offset = target_offset > 0 ? target_offset : content_len - start_offset;

				/* Extract sub-chunk */
				sub_content = pnstrdup(content + start_offset, end_offset);
				sub_chunk = create_hybrid_chunk(sub_content, chunk->heading_context);
				pfree(sub_content);

				result = lappend(result, sub_chunk);

				/* Move to next portion */
				start_offset += end_offset;

				/* Skip whitespace */
				while (start_offset < content_len &&
					   (content[start_offset] == ' ' ||
						content[start_offset] == '\t' ||
						content[start_offset] == '\n' ||
						content[start_offset] == '\r'))
				{
					start_offset++;
				}
			}

			/* Free original oversized chunk */
			free_hybrid_chunk(chunk);
		}
	}

	return result;
}

/*
 * Merge consecutive undersized chunks with same heading context
 *
 * Pass 2 of hybrid refinement: Merge undersized chunks
 */
static List *
merge_undersized_chunks(List *chunks, int min_tokens, int max_tokens)
{
	List *result = NIL;
	ListCell *lc;
	HybridChunk *pending = NULL;

	foreach(lc, chunks)
	{
		HybridChunk *chunk = (HybridChunk *) lfirst(lc);

		if (pending == NULL)
		{
			/* First chunk or after flush */
			if (chunk->token_count >= min_tokens)
			{
				/* Chunk is large enough, output directly */
				result = lappend(result, chunk);
			}
			else
			{
				/* Undersized, start accumulating */
				pending = chunk;
			}
		}
		else
		{
			/* We have a pending undersized chunk */
			bool same_context = false;

			/* Check if contexts match (both NULL or equal strings) */
			if (pending->heading_context == NULL && chunk->heading_context == NULL)
				same_context = true;
			else if (pending->heading_context != NULL && chunk->heading_context != NULL &&
					 strcmp(pending->heading_context, chunk->heading_context) == 0)
				same_context = true;

			/* Check if we can merge */
			if (same_context && pending->token_count + chunk->token_count <= max_tokens)
			{
				/* Merge chunks */
				StringInfoData merged;
				initStringInfo(&merged);
				appendStringInfoString(&merged, pending->content);
				appendStringInfoString(&merged, "\n\n");
				appendStringInfoString(&merged, chunk->content);

				/* Update pending chunk */
				pfree(pending->content);
				pending->content = merged.data;
				pending->token_count = count_tokens(pending->content, pgedge_vectorizer_model);

				/* Free merged chunk */
				free_hybrid_chunk(chunk);
			}
			else
			{
				/* Cannot merge - flush pending and set new pending/output */
				result = lappend(result, pending);

				if (chunk->token_count >= min_tokens)
				{
					result = lappend(result, chunk);
					pending = NULL;
				}
				else
				{
					pending = chunk;
				}
			}
		}
	}

	/* Flush any remaining pending chunk */
	if (pending != NULL)
		result = lappend(result, pending);

	return result;
}

/*
 * Convert parsed markdown elements to simple chunks (no refinement)
 *
 * Used by the pure 'markdown' strategy - respects structure but doesn't
 * do the split/merge refinement passes.
 */
static ArrayType *
elements_to_chunks_simple(List *elements, ChunkConfig *config)
{
	ListCell *lc;
	int chunk_count;
	Datum *chunk_datums;
	ArrayType *result;
	int i;
	List *chunks = NIL;

	if (elements == NIL)
		return construct_empty_array(TEXTOID);

	/* Convert elements to chunks, respecting structure boundaries */
	foreach(lc, elements)
	{
		MarkdownElement *elem = (MarkdownElement *) lfirst(lc);

		/* Skip horizontal rules */
		if (elem->type == MD_ELEMENT_HORIZONTAL_RULE)
			continue;

		/* If element exceeds chunk size, we need to split it */
		if (elem->token_count > config->chunk_size)
		{
			/* Split large elements at natural boundaries */
			const char *content = elem->content;
			int content_len = strlen(content);
			int start_offset = 0;

			while (start_offset < content_len)
			{
				int target_offset;
				int end_offset;
				char *sub_content;
				HybridChunk *chunk;

				target_offset = get_char_offset_for_tokens(
					content + start_offset,
					config->chunk_size,
					pgedge_vectorizer_model
				);

				end_offset = find_good_break_point(
					content + start_offset,
					target_offset,
					content_len - start_offset
				);

				if (end_offset <= 0)
					end_offset = target_offset > 0 ? target_offset : content_len - start_offset;

				sub_content = pnstrdup(content + start_offset, end_offset);
				chunk = create_hybrid_chunk(sub_content, elem->heading_context);
				pfree(sub_content);

				chunks = lappend(chunks, chunk);

				start_offset += end_offset;
				while (start_offset < content_len &&
					   (content[start_offset] == ' ' ||
						content[start_offset] == '\t' ||
						content[start_offset] == '\n'))
				{
					start_offset++;
				}
			}
		}
		else
		{
			/* Element fits in one chunk */
			HybridChunk *chunk = create_hybrid_chunk(elem->content, elem->heading_context);
			chunks = lappend(chunks, chunk);
		}
	}

	/* Convert to array */
	chunk_count = list_length(chunks);
	if (chunk_count == 0)
		return construct_empty_array(TEXTOID);

	chunk_datums = palloc(chunk_count * sizeof(Datum));

	i = 0;
	foreach(lc, chunks)
	{
		HybridChunk *chunk = (HybridChunk *) lfirst(lc);
		StringInfoData chunk_text;

		initStringInfo(&chunk_text);

		if (chunk->heading_context != NULL && strlen(chunk->heading_context) > 0)
		{
			appendStringInfoString(&chunk_text, "[Context: ");
			appendStringInfoString(&chunk_text, chunk->heading_context);
			appendStringInfoString(&chunk_text, "]\n\n");
		}

		appendStringInfoString(&chunk_text, chunk->content);

		chunk_datums[i++] = PointerGetDatum(cstring_to_text(chunk_text.data));
		pfree(chunk_text.data);
	}

	result = construct_array(chunk_datums, chunk_count, TEXTOID, -1, false, TYPALIGN_INT);

	/* Cleanup */
	pfree(chunk_datums);
	foreach(lc, chunks)
	{
		free_hybrid_chunk((HybridChunk *) lfirst(lc));
	}
	list_free(chunks);

	return result;
}

/*
 * Pure markdown chunking (structure-aware, no refinement)
 *
 * Respects markdown structure boundaries but doesn't apply the
 * split/merge refinement passes. Simpler and faster than hybrid,
 * but may produce less optimal chunk sizes for embeddings.
 *
 * Falls back to token-based chunking if content isn't markdown.
 */
ArrayType *
chunk_markdown(const char *content, ChunkConfig *config)
{
	List *elements;
	ArrayType *result;

	if (content == NULL || content[0] == '\0')
		return construct_empty_array(TEXTOID);

	/* Check if content is actually markdown */
	if (!is_likely_markdown(content))
	{
		elog(DEBUG1, "Content doesn't appear to be markdown, falling back to token-based chunking");
		return chunk_by_tokens(content, config);
	}

	elog(DEBUG1, "Markdown chunking: chunk_size=%d", config->chunk_size);

	/* Parse structure */
	elements = parse_markdown_structure(content);

	if (elements == NIL)
		return construct_empty_array(TEXTOID);

	elog(DEBUG2, "Parsed %d markdown elements", list_length(elements));

	/* Convert to chunks (simple, no refinement) */
	result = elements_to_chunks_simple(elements, config);

	/* Cleanup */
	free_markdown_elements(elements);

	return result;
}

/*
 * Main hybrid chunking function
 *
 * Implements Docling-style hybrid chunking:
 * 1. Detect if content is markdown (fall back to token-based if not)
 * 2. Parse markdown structure into elements
 * 3. Convert elements to initial chunks with heading context
 * 4. Split oversized chunks (Pass 1)
 * 5. Merge undersized consecutive chunks with same context (Pass 2)
 * 6. Return as PostgreSQL text array
 */
ArrayType *
chunk_hybrid(const char *content, ChunkConfig *config)
{
	List *elements;
	List *chunks = NIL;
	List *refined_chunks;
	ListCell *lc;
	int chunk_count;
	Datum *chunk_datums;
	ArrayType *result;
	int i;
	int min_tokens;

	if (content == NULL || content[0] == '\0')
		return construct_empty_array(TEXTOID);

	/* Step 0: Check if content is actually markdown */
	if (!is_likely_markdown(content))
	{
		elog(DEBUG1, "Content doesn't appear to be markdown, falling back to token-based chunking");
		return chunk_by_tokens(content, config);
	}

	elog(DEBUG1, "Hybrid chunking: chunk_size=%d, overlap=%d",
		 config->chunk_size, config->overlap);

	/* Step 1: Parse markdown structure */
	elements = parse_markdown_structure(content);

	if (elements == NIL)
		return construct_empty_array(TEXTOID);

	elog(DEBUG2, "Parsed %d markdown elements", list_length(elements));

	/* Step 2: Convert elements to initial chunks with heading context */
	foreach(lc, elements)
	{
		MarkdownElement *elem = (MarkdownElement *) lfirst(lc);
		HybridChunk *chunk;

		/* Skip horizontal rules - they don't add content value */
		if (elem->type == MD_ELEMENT_HORIZONTAL_RULE)
			continue;

		chunk = create_hybrid_chunk(elem->content, elem->heading_context);
		chunks = lappend(chunks, chunk);
	}

	/* Free elements (we've copied the content) */
	free_markdown_elements(elements);

	if (chunks == NIL)
		return construct_empty_array(TEXTOID);

	elog(DEBUG2, "Created %d initial chunks", list_length(chunks));

	/* Step 3: Split oversized chunks (Pass 1) */
	refined_chunks = split_oversized_chunks(chunks, config->chunk_size);
	list_free(chunks);  /* List structure only, chunks moved to refined_chunks */

	elog(DEBUG2, "After split pass: %d chunks", list_length(refined_chunks));

	/* Step 4: Merge undersized chunks (Pass 2) */
	/* Use 25% of chunk_size as minimum threshold for merging */
	min_tokens = config->chunk_size / 4;
	if (min_tokens < 20)
		min_tokens = 20;

	chunks = merge_undersized_chunks(refined_chunks, min_tokens, config->chunk_size);
	list_free(refined_chunks);  /* List structure only */

	elog(DEBUG2, "After merge pass: %d chunks", list_length(chunks));

	/* Step 5: Convert to PostgreSQL text array */
	chunk_count = list_length(chunks);
	if (chunk_count == 0)
		return construct_empty_array(TEXTOID);

	chunk_datums = palloc(chunk_count * sizeof(Datum));

	i = 0;
	foreach(lc, chunks)
	{
		HybridChunk *chunk = (HybridChunk *) lfirst(lc);
		StringInfoData chunk_text;

		initStringInfo(&chunk_text);

		/* Optionally prepend heading context for better retrieval */
		if (chunk->heading_context != NULL && strlen(chunk->heading_context) > 0)
		{
			appendStringInfoString(&chunk_text, "[Context: ");
			appendStringInfoString(&chunk_text, chunk->heading_context);
			appendStringInfoString(&chunk_text, "]\n\n");
		}

		appendStringInfoString(&chunk_text, chunk->content);

		chunk_datums[i++] = PointerGetDatum(cstring_to_text(chunk_text.data));
		pfree(chunk_text.data);
	}

	result = construct_array(chunk_datums, chunk_count, TEXTOID, -1, false, TYPALIGN_INT);

	/* Cleanup */
	pfree(chunk_datums);
	foreach(lc, chunks)
	{
		free_hybrid_chunk((HybridChunk *) lfirst(lc));
	}
	list_free(chunks);

	elog(DEBUG1, "Hybrid chunking produced %d chunks", chunk_count);

	return result;
}

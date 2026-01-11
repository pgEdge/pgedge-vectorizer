/*-------------------------------------------------------------------------
 *
 * pgedge_vectorizer.h
 *		Main header file for pgEdge Vectorizer extension
 *
 * Portions copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PGEDGE_VECTORIZER_H
#define PGEDGE_VECTORIZER_H

#include "postgres.h"
#include "fmgr.h"

/* PostgreSQL headers */
#include "access/xact.h"
#include "catalog/pg_type.h"
#include "executor/spi.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "storage/proc.h"
#include "storage/shmem.h"
#include "utils/builtins.h"
#include "utils/guc.h"
#include "utils/snapmgr.h"

/* Version compatibility */
#if PG_VERSION_NUM < 140000
#error "pgedge_vectorizer requires PostgreSQL 14 or later"
#endif

/* pg_noreturn compatibility for PostgreSQL 18+ */
#if PG_VERSION_NUM < 180000
#define PGEDGE_NORETURN
#define PGEDGE_NORETURN_SUFFIX pg_attribute_noreturn()
#else
#define PGEDGE_NORETURN pg_noreturn
#define PGEDGE_NORETURN_SUFFIX
#endif

/*
 * GUC Variables (declared extern, defined in guc.c)
 */
extern char *pgedge_vectorizer_provider;
extern char *pgedge_vectorizer_api_key_file;
extern char *pgedge_vectorizer_api_url;
extern char *pgedge_vectorizer_model;
extern char *pgedge_vectorizer_databases;
extern int pgedge_vectorizer_num_workers;
extern int pgedge_vectorizer_batch_size;
extern int pgedge_vectorizer_max_retries;
extern int pgedge_vectorizer_worker_poll_interval;
extern bool pgedge_vectorizer_auto_chunk;
extern char *pgedge_vectorizer_default_chunk_strategy;
extern int pgedge_vectorizer_default_chunk_size;
extern int pgedge_vectorizer_default_chunk_overlap;
extern bool pgedge_vectorizer_strip_non_ascii;
extern int pgedge_vectorizer_auto_cleanup_hours;

/*
 * Chunking strategy enumeration
 */
typedef enum
{
	CHUNK_STRATEGY_TOKEN,      /* Fixed token count */
	CHUNK_STRATEGY_SEMANTIC,   /* Semantic boundaries (future) */
	CHUNK_STRATEGY_MARKDOWN,   /* Respect markdown structure (future) */
	CHUNK_STRATEGY_SENTENCE,   /* Sentence-based (future) */
	CHUNK_STRATEGY_RECURSIVE,  /* Recursive character splitting (future) */
	CHUNK_STRATEGY_HYBRID      /* Hierarchical + tokenization-aware refinement */
} ChunkStrategy;

/*
 * Markdown element types for hierarchical parsing
 */
typedef enum
{
	MD_ELEMENT_HEADING,        /* # Heading */
	MD_ELEMENT_PARAGRAPH,      /* Regular text block */
	MD_ELEMENT_CODE_BLOCK,     /* ``` code ``` */
	MD_ELEMENT_LIST_ITEM,      /* - or * or 1. list item */
	MD_ELEMENT_BLOCKQUOTE,     /* > quoted text */
	MD_ELEMENT_TABLE,          /* | table | rows | */
	MD_ELEMENT_HORIZONTAL_RULE /* --- or *** */
} MarkdownElementType;

/*
 * Parsed markdown element
 */
typedef struct MarkdownElement
{
	MarkdownElementType type;
	int heading_level;         /* 1-6 for headings, 0 otherwise */
	char *content;             /* Text content of element */
	int token_count;           /* Approximate token count */
	char *heading_context;     /* Current heading hierarchy (e.g., "# H1 > ## H2") */
} MarkdownElement;

/*
 * Chunk with metadata for hybrid chunking
 */
typedef struct HybridChunk
{
	char *content;             /* Chunk text */
	int token_count;           /* Token count */
	char *heading_context;     /* Heading hierarchy for this chunk */
	int chunk_index;           /* Position in sequence */
} HybridChunk;

/*
 * Chunk configuration
 */
typedef struct ChunkConfig
{
	ChunkStrategy strategy;
	int chunk_size;        /* Target size in tokens */
	int overlap;           /* Overlap in tokens */
	char *separators;      /* For semantic chunking (future) */
} ChunkConfig;

/*
 * Provider interface
 */
typedef struct EmbeddingProvider
{
	const char *name;
	bool (*init)(char **error_msg);
	void (*cleanup)(void);
	float *(*generate)(const char *text, int *dim, char **error_msg);
	float **(*generate_batch)(const char **texts, int count, int *dim, char **error_msg);
} EmbeddingProvider;

/*
 * Function declarations
 */

/* guc.c */
void pgedge_vectorizer_init_guc(void);

/* provider.c */
EmbeddingProvider *get_embedding_provider(const char *name);
EmbeddingProvider *get_current_provider(void);
void register_embedding_providers(void);

/* provider_openai.c */
extern EmbeddingProvider OpenAIProvider;

/* provider_voyage.c */
extern EmbeddingProvider VoyageProvider;

/* provider_ollama.c */
extern EmbeddingProvider OllamaProvider;

/* tokenizer.c */
int count_tokens(const char *text, const char *model);
int *tokenize_text(const char *text, const char *model, int *token_count);
char *detokenize_tokens(const int *tokens, int token_count, const char *model);
int get_char_offset_for_tokens(const char *text, int target_tokens, const char *model);
int find_good_break_point(const char *text, int target_offset, int max_offset);

/* chunking.c */
ArrayType *chunk_text(const char *content, ChunkConfig *config);
ChunkStrategy parse_chunk_strategy(const char *strategy_str);

/* hybrid_chunking.c */
ArrayType *chunk_hybrid(const char *content, ChunkConfig *config);
List *parse_markdown_structure(const char *content);
void free_markdown_elements(List *elements);

/* worker.c */
extern PGDLLEXPORT PGEDGE_NORETURN void pgedge_vectorizer_worker_main(Datum main_arg) PGEDGE_NORETURN_SUFFIX;
void register_background_workers(void);

/* queue.c */
Datum pgedge_vectorizer_queue_status(PG_FUNCTION_ARGS);
Datum pgedge_vectorizer_worker_stats(PG_FUNCTION_ARGS);

#endif   /* PGEDGE_VECTORIZER_H */

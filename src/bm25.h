/*-------------------------------------------------------------------------
 *
 * bm25.h
 *		BM25 sparse vector computation for hybrid search support
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PGEDGE_BM25_H
#define PGEDGE_BM25_H

#include "pgedge_vectorizer.h"
#include "utils/hsearch.h"

/*
 * Vocabulary size for hashing terms to sparse vector dimensions.
 * Large enough to keep collision rates low for typical corpora.
 */
#define BM25_VOCAB_SIZE     65536

/*
 * Maximum number of characters stored in a hash key for a term.
 * Vocabulary words never approach this limit; it caps key memory only.
 */
#define BM25_MAX_TERM_LEN   128

/*
 * Term frequency entry produced by bm25_tokenize()
 */
typedef struct
{
	char   *term;
	int     tf;       /* term frequency in this document */
} BM25Term;

/*
 * Hash entry for O(1) IDF lookups — key must be the first field.
 * Built by bm25_load_idf_stats() and consumed by bm25_compute_sparse_str().
 */
typedef struct
{
	char    key[BM25_MAX_TERM_LEN]; /* null-terminated term — must be first */
	float8  idf_weight;
} IdfHashEntry;

/*
 * GUC variables defined in guc.c, extern-declared here so that
 * bm25.c and worker.c can read them after including this header.
 */
extern bool   pgedge_vectorizer_enable_hybrid;
extern double pgedge_vectorizer_bm25_k1;
extern double pgedge_vectorizer_bm25_b;

/*
 * Internal functions — callers must have an active SPI connection
 * for bm25_load_idf_stats, bm25_update_idf_stats, and
 * bm25_avg_doc_len_internal.
 *
 * bm25_load_idf_stats returns a palloc'd HTAB (or NULL if the stats
 * table does not yet exist).  Callers should call hash_destroy() on it
 * when done to release memory promptly.
 */
BM25Term *bm25_tokenize(const char *text, int *ntokens);
HTAB     *bm25_load_idf_stats(const char *chunk_table);
char     *bm25_compute_sparse_str(BM25Term *tokens, int ntokens,
								  HTAB *idf_htab,
								  float8 k1, float8 b,
								  float8 avg_doc_len, int doc_len);
Datum     bm25_compute_sparse_vector(BM25Term *tokens, int ntokens,
									 HTAB *idf_htab,
									 float8 k1, float8 b,
									 float8 avg_doc_len, int doc_len);
void      bm25_update_idf_stats(const char *chunk_table,
								BM25Term *tokens, int ntokens);
float8    bm25_avg_doc_len_internal(const char *chunk_table);

/* SQL-callable wrappers (PG_FUNCTION_INFO_V1 defined in bm25.c only) */
extern Datum pgedge_vectorizer_bm25_query_vector(PG_FUNCTION_ARGS);
extern Datum pgedge_vectorizer_bm25_avg_doc_len(PG_FUNCTION_ARGS);
extern Datum pgedge_vectorizer_bm25_tokenize(PG_FUNCTION_ARGS);

#endif   /* PGEDGE_BM25_H */

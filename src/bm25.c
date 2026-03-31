/*-------------------------------------------------------------------------
 *
 * bm25.c
 *		BM25 sparse vector computation for hybrid search support
 *
 * Implements tokenization, IDF statistics management, and BM25 scoring
 * to produce sparsevec values stored alongside dense embeddings in chunk
 * tables.  Functions that touch the database assume the caller holds an
 * active SPI connection (except the SQL-callable wrappers, which open
 * their own SPI session).
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "bm25.h"

#include <ctype.h>
#include <math.h>
#include <string.h>

#include "access/xact.h"
#include "lib/stringinfo.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/errcodes.h"
#include "utils/hsearch.h"
#include "utils/memutils.h"

/* ----------------------------------------------------------------
 * English stopword list — must stay sorted (used with bsearch)
 * ----------------------------------------------------------------
 */
static const char *stopwords[] = {
	"a", "above", "after", "again", "an", "and", "are", "as",
	"at", "be", "been", "before", "being", "below", "both",
	"but", "by", "can", "could", "dare", "did", "do", "does",
	"down", "during", "either", "for", "from", "further",
	"had", "has", "have", "if", "in", "into", "is", "may",
	"might", "need", "neither", "nor", "not", "of", "off",
	"on", "once", "or", "ought", "out", "over", "shall",
	"should", "so", "the", "then", "through", "to", "under",
	"up", "used", "was", "were", "whether", "while", "will",
	"with", "would", "yet"
};

#define STOPWORDS_COUNT \
	((int) (sizeof(stopwords) / sizeof(stopwords[0])))

/* Comparator for bsearch against the stopwords array */
static int
stopword_cmp(const void *a, const void *b)
{
	return strcmp((const char *) a, *(const char * const *) b);
}

/*
 * is_stopword — true if term appears in the sorted stopword list
 */
static bool
is_stopword(const char *term)
{
	return bsearch(term, stopwords, STOPWORDS_COUNT,
				   sizeof(stopwords[0]), stopword_cmp) != NULL;
}

/*
 * djb2_hash — fast string hash for mapping terms to dimension indices
 */
static uint32
djb2_hash(const char *str)
{
	uint32				hash = 5381;
	const unsigned char *p = (const unsigned char *) str;

	while (*p)
		hash = ((hash << 5) + hash) ^ *p++;

	return hash;
}

/*
 * term_to_dim — map a term to a 1-based sparse vector dimension
 * in [1, BM25_VOCAB_SIZE]
 */
static int
term_to_dim(const char *term)
{
	return (int) (djb2_hash(term) % (uint32) BM25_VOCAB_SIZE) + 1;
}

/*
 * normalize_text_inplace — lowercase and replace non-alpha with spaces
 */
static void
normalize_text_inplace(char *buf)
{
	char *p;

	for (p = buf; *p; p++)
	{
		if (isalpha((unsigned char) *p))
			*p = (char) tolower((unsigned char) *p);
		else
			*p = ' ';
	}
}

/*
 * IDF row read from the _idf_stats table via SPI.
 * Internal to this file; not exposed in bm25.h.
 */
typedef struct
{
	char   *term;
	int     doc_freq;
	int     total_docs;
	float8  idf_weight;
} IdfStat;

/*
 * Term deduplication hash entry — used only inside bm25_tokenize.
 * Maps a term string to its index in the output terms[] array.
 * Key must be the first field for dynahash.
 */
typedef struct
{
	char key[BM25_MAX_TERM_LEN]; /* null-terminated term — must be first */
	int  idx;                     /* index in the returned terms[] array */
} TermDedupEntry;

/*
 * bm25_tokenize
 *
 * Lowercase the input, replace non-alpha chars with spaces, split on
 * whitespace, strip English stopwords, deduplicate, and count term
 * frequencies.  Returns a palloc'd BM25Term array; *ntokens is the
 * number of distinct terms.  Returns an empty array (never NULL) for
 * NULL or empty input.
 *
 * Deduplication uses a short-lived dynahash for O(1) lookups instead
 * of the previous O(n) linear scan.
 */
BM25Term *
bm25_tokenize(const char *text, int *ntokens)
{
	char           *buf;
	char           *tok;
	char           *saveptr = NULL;
	int             cap = 16;
	BM25Term       *terms;
	int             nterms = 0;
	HASHCTL         ctl;
	HTAB           *dedup;

	*ntokens = 0;

	if (text == NULL || *text == '\0')
		return palloc0(sizeof(BM25Term));

	/* Short-lived hash table for O(1) within-document deduplication */
	memset(&ctl, 0, sizeof(ctl));
	ctl.keysize   = BM25_MAX_TERM_LEN;
	ctl.entrysize = sizeof(TermDedupEntry);
	dedup = hash_create("bm25_tokenize_dedup", 64, &ctl,
						HASH_ELEM | HASH_STRINGS);

	terms = palloc(cap * sizeof(BM25Term));
	buf   = pstrdup(text);
	normalize_text_inplace(buf);

	/* strtok_r is reentrant; strtok relies on global static state */
	tok = strtok_r(buf, " ", &saveptr);
	while (tok != NULL)
	{
		if (!is_stopword(tok))
		{
			bool            found;
			TermDedupEntry *entry;

			entry = hash_search(dedup, tok, HASH_ENTER, &found);
			if (found)
			{
				terms[entry->idx].tf++;
			}
			else
			{
				/* New distinct term — append to output array */
				if (nterms >= cap)
				{
					cap   = cap * 2;
					terms = repalloc(terms, cap * sizeof(BM25Term));
				}
				terms[nterms].term = pstrdup(tok);
				terms[nterms].tf   = 1;
				entry->idx         = nterms;
				nterms++;
			}
		}
		tok = strtok_r(NULL, " ", &saveptr);
	}

	hash_destroy(dedup);
	pfree(buf);

	*ntokens = nterms;
	return terms;
}

/*
 * bm25_load_idf_stats
 *
 * Load all rows from {chunk_table}_idf_stats via SPI and return them as
 * a dynahash keyed on term for O(1) IDF lookups.  Returns NULL (not an
 * error) if the stats table does not exist yet.
 *
 * Uses a subtransaction so a missing table does not abort the outer
 * worker transaction.  Re-throws all errors except ERRCODE_UNDEFINED_TABLE.
 * Caller must have an active SPI connection.
 * Caller should call hash_destroy() on the returned HTAB when done.
 */

/*
 * read_idf_row — extract one IdfStat from a SPI result row
 */
static IdfStat
read_idf_row(SPITupleTable *tuptable, int i)
{
	IdfStat  s;
	bool     isnull;
	Datum    val;

	val = SPI_getbinval(tuptable->vals[i], tuptable->tupdesc, 1, &isnull);
	s.term = isnull ? pstrdup("") : pstrdup(TextDatumGetCString(val));

	val = SPI_getbinval(tuptable->vals[i], tuptable->tupdesc, 2, &isnull);
	s.doc_freq = isnull ? 1 : DatumGetInt32(val);

	val = SPI_getbinval(tuptable->vals[i], tuptable->tupdesc, 3, &isnull);
	s.total_docs = isnull ? 1 : DatumGetInt32(val);

	val = SPI_getbinval(tuptable->vals[i], tuptable->tupdesc, 4, &isnull);
	s.idf_weight = isnull ? 0.693 : DatumGetFloat8(val);

	return s;
}

HTAB *
bm25_load_idf_stats(const char *chunk_table)
{
	char            *sql;
	int              ret;
	bool             ok = false;
	MemoryContext    oldctx;
	ResourceOwner    oldowner;
	HTAB            *htab = NULL;
	HASHCTL          ctl;

	{
		char       *tbl_name = psprintf("%s_idf_stats", chunk_table);
		const char *qtbl     = quote_identifier(tbl_name);

		sql = psprintf(
			"SELECT term, doc_freq, total_docs, idf_weight FROM %s", qtbl);
		pfree(tbl_name);
	}

	oldctx   = CurrentMemoryContext;
	oldowner = CurrentResourceOwner;

	/*
	 * Wrap in a subtransaction so that "table does not exist" is
	 * handled gracefully rather than aborting the worker's batch.
	 */
	BeginInternalSubTransaction(NULL);
	PG_TRY();
	{
		ret = SPI_execute(sql, true, 0);
		ok  = true;
		ReleaseCurrentSubTransaction();
	}
	PG_CATCH();
	{
		int		errcode_saved = geterrcode();

		MemoryContextSwitchTo(oldctx);
		CurrentResourceOwner = oldowner;
		RollbackAndReleaseCurrentSubTransaction();

		if (errcode_saved != ERRCODE_UNDEFINED_TABLE)
		{
			/* Not a missing-table error — re-throw so caller sees it */
			PG_RE_THROW();
		}

		FlushErrorState();
		pfree(sql);
		return NULL;
	}
	PG_END_TRY();

	pfree(sql);

	if (!ok || ret != SPI_OK_SELECT || SPI_processed == 0)
		return NULL;

	/* Build hash table from SPI results for O(1) lookups */
	memset(&ctl, 0, sizeof(ctl));
	ctl.keysize   = BM25_MAX_TERM_LEN;
	ctl.entrysize = sizeof(IdfHashEntry);
	htab = hash_create("bm25_idf_stats",
					   (int) SPI_processed * 2,
					   &ctl,
					   HASH_ELEM | HASH_STRINGS);

	for (int i = 0; i < (int) SPI_processed; i++)
	{
		IdfStat       row   = read_idf_row(SPI_tuptable, i);
		bool          found;
		IdfHashEntry *entry;

		entry = hash_search(htab, row.term, HASH_ENTER, &found);
		if (!found)
			entry->idf_weight = row.idf_weight;
		/* Duplicate terms: keep the first weight encountered */
	}

	return htab;
}

/*
 * bm25_avg_doc_len_internal
 *
 * Return AVG(token_count) from chunk_table via SPI.
 * Returns 1.0 if the table is empty.
 * Caller must have an active SPI connection.
 */
float8
bm25_avg_doc_len_internal(const char *chunk_table)
{
	char   *sql;
	int     ret;
	bool    isnull;
	Datum   val;
	float8  result = 1.0;

	sql = psprintf("SELECT AVG(token_count) FROM %s",
				   quote_identifier(chunk_table));
	ret = SPI_execute(sql, true, 1);
	pfree(sql);

	if (ret != SPI_OK_SELECT)
	{
		elog(WARNING,
			 "bm25_avg_doc_len_internal: SPI error for table %s",
			 chunk_table);
		return 1.0;
	}

	if (SPI_processed == 0)
		return 1.0;

	val = SPI_getbinval(SPI_tuptable->vals[0],
						SPI_tuptable->tupdesc, 1, &isnull);
	if (!isnull)
		result = DatumGetFloat8(val);

	return (result <= 0.0) ? 1.0 : result;
}

/*
 * lookup_idf — find the IDF weight for a term via O(1) hash lookup.
 * Returns ln(2) ≈ 0.693 (i.e. idf = ln(1+1)) when not found.
 */
static float8
lookup_idf(const char *term, HTAB *idf_htab)
{
	IdfHashEntry *entry;

	if (idf_htab == NULL)
		return log(2.0);

	entry = hash_search(idf_htab, term, HASH_FIND, NULL);
	return entry ? entry->idf_weight : log(2.0);
}

typedef struct { int dim; float8 score; } DimScore;

/*
 * Hash entry mapping a sparse vector dimension to its index in the pairs[]
 * array.  Key is the dimension (int); must be first field for dynahash.
 * Used inside bm25_compute_sparse_str for O(1) collision resolution.
 */
typedef struct { int dim; int idx; } DimIndexEntry;

/*
 * accumulate_dim_score — add score to existing dim or append a new entry.
 *
 * dim_map is a HTAB keyed on int (the sparse vector dimension).  It maps
 * each dimension to the index of its DimScore entry in pairs[], giving O(1)
 * collision resolution instead of the previous O(n) linear scan.
 */
static void
accumulate_dim_score(DimScore **pairs, int *npairs, int *cap,
					 HTAB *dim_map, int dim, float8 score)
{
	DimIndexEntry *entry;
	bool           found;

	entry = hash_search(dim_map, &dim, HASH_ENTER, &found);
	if (found)
	{
		(*pairs)[entry->idx].score += score;
		return;
	}

	/* New dimension — append to pairs[] and record its index */
	if (*npairs >= *cap)
	{
		*cap = (*cap == 0) ? 16 : *cap * 2;
		if (*pairs == NULL)
			*pairs = palloc(*cap * sizeof(DimScore));
		else
			*pairs = repalloc(*pairs, *cap * sizeof(DimScore));
	}
	(*pairs)[*npairs].dim   = dim;
	(*pairs)[*npairs].score = score;
	entry->idx              = *npairs;
	(*npairs)++;
}

/*
 * build_sparsevec_string — format DimScore pairs as "{d:s,...}/N"
 */
static char *
build_sparsevec_string(DimScore *pairs, int npairs)
{
	StringInfoData  buf;
	bool            first = true;

	initStringInfo(&buf);
	appendStringInfoChar(&buf, '{');
	for (int i = 0; i < npairs; i++)
	{
		if (!first)
			appendStringInfoChar(&buf, ',');
		appendStringInfo(&buf, "%d:%f", pairs[i].dim, pairs[i].score);
		first = false;
	}
	appendStringInfo(&buf, "}/%d", BM25_VOCAB_SIZE);
	return buf.data;
}

/*
 * bm25_compute_sparse_str
 *
 * Compute BM25 scores for every token and build a sparsevec string of
 * the form "{dim1:score1,dim2:score2}/VOCAB_SIZE".  Terms that hash to
 * the same dimension have their scores summed (collision resolution).
 * Only terms with score > 0 are included.
 *
 * Returns a palloc'd string; never returns NULL.
 */
char *
bm25_compute_sparse_str(BM25Term *tokens, int ntokens,
						HTAB *idf_htab,
						float8 k1, float8 b,
						float8 avg_doc_len, int doc_len)
{
	DimScore   *pairs = NULL;
	int         npairs = 0;
	int         cap = 0;
	float8      dl_ratio;
	char       *result;
	HASHCTL     ctl;
	HTAB       *dim_map;

	if (avg_doc_len <= 0.0)
		avg_doc_len = 1.0;
	dl_ratio = (float8) doc_len / avg_doc_len;

	/* O(1) dimension → pairs[] index map for collision resolution */
	memset(&ctl, 0, sizeof(ctl));
	ctl.keysize   = sizeof(int);
	ctl.entrysize = sizeof(DimIndexEntry);
	dim_map = hash_create("bm25_dim_index", 64, &ctl,
						  HASH_ELEM | HASH_BLOBS);

	for (int i = 0; i < ntokens; i++)
	{
		float8  tf    = (float8) tokens[i].tf;
		float8  idf   = lookup_idf(tokens[i].term, idf_htab);
		float8  denom = tf + k1 * (1.0 - b + b * dl_ratio);
		float8  score = (denom <= 0.0) ? 0.0 :
						idf * (tf * (k1 + 1.0)) / denom;

		if (score > 0.0)
			accumulate_dim_score(&pairs, &npairs, &cap, dim_map,
								 term_to_dim(tokens[i].term), score);
	}

	hash_destroy(dim_map);

	result = build_sparsevec_string(pairs, npairs);

	if (pairs != NULL)
		pfree(pairs);

	return result;
}

/*
 * bm25_compute_sparse_vector
 *
 * Wraps bm25_compute_sparse_str and casts the string to a sparsevec
 * Datum via SPI.  Caller must have an active SPI connection.
 */
Datum
bm25_compute_sparse_vector(BM25Term *tokens, int ntokens,
						   HTAB *idf_htab,
						   float8 k1, float8 b,
						   float8 avg_doc_len, int doc_len)
{
	char   *vec_str;
	char   *sql;
	int     ret;
	Datum   result;
	bool    isnull;

	vec_str = bm25_compute_sparse_str(tokens, ntokens,
									  idf_htab,
									  k1, b,
									  avg_doc_len, doc_len);

	sql = psprintf("SELECT %s::sparsevec", quote_literal_cstr(vec_str));
	ret = SPI_execute(sql, true, 1);
	pfree(sql);
	pfree(vec_str);

	if (ret != SPI_OK_SELECT || SPI_processed != 1)
		elog(ERROR,
			 "bm25_compute_sparse_vector: "
			 "failed to cast string to sparsevec");

	result = SPI_getbinval(SPI_tuptable->vals[0],
						   SPI_tuptable->tupdesc, 1, &isnull);

	if (isnull)
		elog(ERROR,
			 "bm25_compute_sparse_vector: NULL sparsevec result");

	return SPI_datumTransfer(result, false, -1);
}

/*
 * bm25_update_idf_stats
 *
 * Upsert each token's term into {chunk_table}_idf_stats, incrementing
 * doc_freq and recomputing idf_weight.  Runs inside a subtransaction
 * so that a failure does not abort the outer worker transaction.
 * Caller must have an active SPI connection.
 */
/*
 * upsert_term_idf — insert or update a single term's IDF stats row.
 * total_docs is pre-computed once by the caller; passing it here
 * avoids a full-table count(*) scan per term.
 */
static void
upsert_term_idf(const char *chunk_table, const char *term, int total_docs)
{
	char       *safe_term  = quote_literal_cstr(term);
	char       *tbl_name   = psprintf("%s_idf_stats", chunk_table);
	const char *qidf       = quote_identifier(tbl_name);
	char       *sql;
	int         ret;

	sql = psprintf(
		"INSERT INTO %s"
		"    (term, doc_freq, total_docs, idf_weight)"
		" VALUES (%s, 1, %d,"
		"         ln(1.0 + (%d - 1.0 + 0.5) / (1.0 + 0.5)))"
		" ON CONFLICT (term) DO UPDATE SET"
		"    doc_freq   = %s.doc_freq + 1,"
		"    total_docs = %d,"
		"    idf_weight = ln(1.0 +"
		"        (%d - (%s.doc_freq + 1) + 0.5)"
		"        / ((%s.doc_freq + 1) + 0.5)),"
		"    updated_at = now()",
		qidf, safe_term, total_docs, total_docs,
		qidf,
		total_docs, total_docs, qidf, qidf);

	pfree(tbl_name);
	pfree(safe_term);
	ret = SPI_execute(sql, false, 0);
	pfree(sql);

	if (ret != SPI_OK_INSERT && ret != SPI_OK_UPDATE)
		elog(WARNING,
			 "bm25_update_idf_stats: unexpected SPI result %d "
			 "for term in table %s", ret, chunk_table);
}

void
bm25_update_idf_stats(const char *chunk_table,
					  BM25Term *tokens, int ntokens)
{
	MemoryContext oldctx;
	ResourceOwner oldowner;
	int           total_docs = 0;
	bool          isnull;
	Datum         val;
	char         *sql;
	int           ret;

	if (ntokens <= 0)
		return;

	/* Pre-compute total_docs once to avoid per-term count(*) scans */
	sql = psprintf("SELECT count(*)::int FROM %s",
				   quote_identifier(chunk_table));
	ret = SPI_execute(sql, true, 1);
	pfree(sql);

	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		val = SPI_getbinval(SPI_tuptable->vals[0],
							SPI_tuptable->tupdesc, 1, &isnull);
		if (!isnull)
			total_docs = DatumGetInt32(val);
	}

	if (total_docs <= 0)
		total_docs = 1;

	oldctx   = CurrentMemoryContext;
	oldowner = CurrentResourceOwner;

	BeginInternalSubTransaction(NULL);
	PG_TRY();
	{
		for (int i = 0; i < ntokens; i++)
			upsert_term_idf(chunk_table, tokens[i].term, total_docs);

		ReleaseCurrentSubTransaction();
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(oldctx);
		CurrentResourceOwner = oldowner;
		RollbackAndReleaseCurrentSubTransaction();
		FlushErrorState();
		elog(WARNING,
			 "bm25_update_idf_stats: subtransaction rolled back "
			 "for chunk table %s; IDF stats may be stale",
			 chunk_table);
	}
	PG_END_TRY();
}

/* ----------------------------------------------------------------
 * SQL-callable wrappers — PG_FUNCTION_INFO_V1 must appear in exactly
 * one translation unit (bm25.c); bm25.h uses plain extern declarations.
 * ----------------------------------------------------------------
 */
PG_FUNCTION_INFO_V1(pgedge_vectorizer_bm25_query_vector);
PG_FUNCTION_INFO_V1(pgedge_vectorizer_bm25_avg_doc_len);
PG_FUNCTION_INFO_V1(pgedge_vectorizer_bm25_tokenize);

/* ----------------------------------------------------------------
 * SQL-callable wrapper:
 *   pgedge_vectorizer.bm25_query_vector(query TEXT, chunk_table TEXT)
 *   RETURNS sparsevec
 * ----------------------------------------------------------------
 */
Datum
pgedge_vectorizer_bm25_query_vector(PG_FUNCTION_ARGS)
{
	text       *query_text;
	text       *chunk_table_text;
	const char *query;
	const char *chunk_table;
	BM25Term   *tokens;
	HTAB       *idf_htab;
	int         ntokens;
	float8      avg_doc_len;
	Datum       result;

	if (PG_ARGISNULL(0) || PG_ARGISNULL(1))
		ereport(ERROR,
				(errmsg("bm25_query_vector: query and chunk_table "
						"must not be NULL")));

	query_text       = PG_GETARG_TEXT_PP(0);
	chunk_table_text = PG_GETARG_TEXT_PP(1);
	query            = TextDatumGetCString(
						   PointerGetDatum(query_text));
	chunk_table      = TextDatumGetCString(
						   PointerGetDatum(chunk_table_text));

	SPI_connect();

	tokens      = bm25_tokenize(query, &ntokens);
	idf_htab    = bm25_load_idf_stats(chunk_table);
	avg_doc_len = bm25_avg_doc_len_internal(chunk_table);

	result = bm25_compute_sparse_vector(
				 tokens, ntokens,
				 idf_htab,
				 pgedge_vectorizer_bm25_k1,
				 pgedge_vectorizer_bm25_b,
				 avg_doc_len,
				 ntokens);

	if (idf_htab != NULL)
		hash_destroy(idf_htab);

	SPI_finish();

	PG_RETURN_DATUM(result);
}

/* ----------------------------------------------------------------
 * SQL-callable wrapper:
 *   pgedge_vectorizer.bm25_avg_doc_len(chunk_table TEXT)
 *   RETURNS float8
 * ----------------------------------------------------------------
 */
Datum
pgedge_vectorizer_bm25_avg_doc_len(PG_FUNCTION_ARGS)
{
	text       *chunk_table_text;
	const char *chunk_table;
	float8      result;

	if (PG_ARGISNULL(0))
		ereport(ERROR,
				(errmsg("bm25_avg_doc_len: chunk_table must "
						"not be NULL")));

	chunk_table_text = PG_GETARG_TEXT_PP(0);
	chunk_table = TextDatumGetCString(
					  PointerGetDatum(chunk_table_text));

	SPI_connect();
	result = bm25_avg_doc_len_internal(chunk_table);
	SPI_finish();

	PG_RETURN_FLOAT8(result);
}

/* ----------------------------------------------------------------
 * SQL-callable wrapper:
 *   pgedge_vectorizer.bm25_tokenize(query TEXT) RETURNS TEXT[]
 *
 * Exposes the tokenizer for testing and debugging.
 * ----------------------------------------------------------------
 */
Datum
pgedge_vectorizer_bm25_tokenize(PG_FUNCTION_ARGS)
{
	text       *input;
	const char *text_str;
	BM25Term   *tokens;
	int         ntokens;
	ArrayType  *result;
	Datum      *elems;
	int         i;

	if (PG_ARGISNULL(0))
	{
		result = construct_empty_array(TEXTOID);
		PG_RETURN_ARRAYTYPE_P(result);
	}

	input    = PG_GETARG_TEXT_PP(0);
	text_str = TextDatumGetCString(PointerGetDatum(input));

	tokens = bm25_tokenize(text_str, &ntokens);

	if (ntokens == 0)
	{
		result = construct_empty_array(TEXTOID);
		PG_RETURN_ARRAYTYPE_P(result);
	}

	elems = palloc(ntokens * sizeof(Datum));
	for (i = 0; i < ntokens; i++)
		elems[i] = CStringGetTextDatum(tokens[i].term);

	result = construct_array(elems, ntokens, TEXTOID,
							 -1, false, TYPALIGN_INT);

	PG_RETURN_ARRAYTYPE_P(result);
}

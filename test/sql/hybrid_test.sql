-- hybrid_test.sql
-- Regression tests for hybrid BM25 + dense vector search feature.

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------

CREATE TABLE hybrid_test_docs (
    id      BIGSERIAL PRIMARY KEY,
    content TEXT
);

-- Use a fixed embedding dimension to avoid needing an API key
SELECT pgedge_vectorizer.enable_vectorization(
    'hybrid_test_docs'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

---------------------------------------------------------------------------
-- Test 1: GUC parameters exist
---------------------------------------------------------------------------

-- Verify all three hybrid GUC params are registered
SELECT name
FROM pg_settings
WHERE name IN (
    'pgedge_vectorizer.enable_hybrid',
    'pgedge_vectorizer.bm25_k1',
    'pgedge_vectorizer.bm25_b'
)
ORDER BY name;

---------------------------------------------------------------------------
-- Test 2: sparse_embedding column exists in chunk table
---------------------------------------------------------------------------

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name   = 'hybrid_test_docs_content_chunks'
  AND column_name  = 'sparse_embedding';

---------------------------------------------------------------------------
-- Test 3: token_count column exists in chunk table (used for BM25 doc length)
---------------------------------------------------------------------------

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_name  = 'hybrid_test_docs_content_chunks'
  AND column_name = 'token_count';

---------------------------------------------------------------------------
-- Test 4: IDF stats table was created
---------------------------------------------------------------------------

SELECT tablename
FROM pg_tables
WHERE tablename = 'hybrid_test_docs_content_chunks_idf_stats';

---------------------------------------------------------------------------
-- Test 5: HNSW sparse index was created
---------------------------------------------------------------------------

SELECT indexname
FROM pg_indexes
WHERE tablename = 'hybrid_test_docs_content_chunks'
  AND indexname LIKE '%sparse%';

---------------------------------------------------------------------------
-- Test 6: vectorizers registry was populated
---------------------------------------------------------------------------

SELECT source_table, source_column, chunk_table
FROM pgedge_vectorizer.vectorizers
WHERE source_table = 'hybrid_test_docs';

---------------------------------------------------------------------------
-- Test 7: hybrid_search function exists
---------------------------------------------------------------------------

SELECT proname
FROM pg_proc
WHERE proname = 'hybrid_search'
  AND pronamespace = (
      SELECT oid FROM pg_namespace
      WHERE nspname = 'pgedge_vectorizer'
  );

---------------------------------------------------------------------------
-- Test 8: hybrid_search_simple function exists
---------------------------------------------------------------------------

SELECT proname
FROM pg_proc
WHERE proname = 'hybrid_search_simple'
  AND pronamespace = (
      SELECT oid FROM pg_namespace
      WHERE nspname = 'pgedge_vectorizer'
  );

---------------------------------------------------------------------------
-- Test 9: BM25 tokenizer returns non-empty output for normal text
---------------------------------------------------------------------------

SELECT array_length(
    pgedge_vectorizer.bm25_tokenize('the quick brown fox jumps'),
    1
) > 0 AS has_tokens;

---------------------------------------------------------------------------
-- Test 10: BM25 tokenizer strips stopwords
-- 'the', 'is', 'a' are stopwords; 'cat' and 'test' should remain
---------------------------------------------------------------------------

SELECT token
FROM unnest(pgedge_vectorizer.bm25_tokenize('the cat is a test')) AS token
ORDER BY token;

---------------------------------------------------------------------------
-- Test 11: BM25 tokenizer handles empty string
---------------------------------------------------------------------------

SELECT COALESCE(
    array_length(pgedge_vectorizer.bm25_tokenize(''), 1),
    0
) AS token_count;

---------------------------------------------------------------------------
-- Test 12: hybrid_search raises a clear exception for unknown table
---------------------------------------------------------------------------

SET pgedge_vectorizer.enable_hybrid = true;

DO $$
BEGIN
    PERFORM pgedge_vectorizer.hybrid_search(
        'pg_class'::regclass, 'test query', 5
    );
    RAISE EXCEPTION 'Expected exception was not raised';
EXCEPTION
    WHEN OTHERS THEN
        IF sqlerrm LIKE '%No vectorizer found%' THEN
            RAISE NOTICE 'Got expected exception: %', sqlerrm;
        ELSE
            RAISE;
        END IF;
END;
$$;

RESET pgedge_vectorizer.enable_hybrid;

---------------------------------------------------------------------------
-- Test 13: hybrid_search raises when enable_hybrid is false
---------------------------------------------------------------------------

-- Explicitly disable so the test is deterministic regardless of postgresql.conf
SET pgedge_vectorizer.enable_hybrid = false;

DO $$
BEGIN
    PERFORM pgedge_vectorizer.hybrid_search(
        'hybrid_test_docs'::regclass, 'test query', 5
    );
    RAISE EXCEPTION 'Expected exception was not raised';
EXCEPTION
    WHEN OTHERS THEN
        IF sqlerrm LIKE '%Hybrid search is disabled%' THEN
            RAISE NOTICE 'Got expected exception: %', sqlerrm;
        ELSE
            RAISE;
        END IF;
END;
$$;

RESET pgedge_vectorizer.enable_hybrid;

---------------------------------------------------------------------------
-- Test 14: bm25_query_vector returns a non-null sparsevec
---------------------------------------------------------------------------

SELECT pg_typeof(
    pgedge_vectorizer.bm25_query_vector(
        'quick brown fox',
        'hybrid_test_docs_content_chunks'
    )
)::text AS result_type;

---------------------------------------------------------------------------
-- Test 15: bm25_avg_doc_len returns a sensible default for an empty table
---------------------------------------------------------------------------

SELECT pgedge_vectorizer.bm25_avg_doc_len(
    'hybrid_test_docs_content_chunks'
) >= 0 AS non_negative;

---------------------------------------------------------------------------
-- Test 15b: bm25_avg_doc_len equals the actual average
---------------------------------------------------------------------------

-- AVG() over an integer column yields numeric, so reading its Datum as a
-- float8 without a cast gives a denormal rather than the mean.  ">= 0" above
-- cannot catch that: a denormal is positive.  Compare against the value SQL
-- computes, on a table with rows in it.

CREATE TABLE avg_len_docs (id BIGSERIAL PRIMARY KEY, body TEXT);
INSERT INTO avg_len_docs (body)
SELECT repeat('alpha beta gamma delta ', 40) FROM generate_series(1, 5);

SELECT pgedge_vectorizer.enable_vectorization('avg_len_docs', 'body',
                                              embedding_dimension => 3);

SELECT pgedge_vectorizer.bm25_avg_doc_len('avg_len_docs_body_chunks')
       = (SELECT AVG(token_count)::float8 FROM avg_len_docs_body_chunks)
       AS avg_doc_len_matches_sql;

-- and it must be a plausible document length, not a denormal
SELECT pgedge_vectorizer.bm25_avg_doc_len('avg_len_docs_body_chunks') > 1.0
       AS avg_doc_len_is_realistic;

SELECT pgedge_vectorizer.disable_vectorization('avg_len_docs', 'body', true);
DROP TABLE avg_len_docs;

---------------------------------------------------------------------------
-- Test 15c: a missing chunk table is reported, not absorbed
---------------------------------------------------------------------------

-- The stats load runs in a subtransaction that tolerates a missing table,
-- which is right for the stats table (not vectorized yet) but wrong for the
-- chunk table, where it means the registry points at something that is gone.
-- Reading the corpus figures inside that subtransaction would swallow it and
-- return a silently degraded vector.

CREATE TABLE orphan_idf_stats (
    term TEXT PRIMARY KEY,
    doc_freq INT,
    updated_at TIMESTAMPTZ DEFAULT now()
);
INSERT INTO orphan_idf_stats (term, doc_freq) VALUES ('alpha', 1), ('beta', 1);

DO $$
BEGIN
    PERFORM pgedge_vectorizer.bm25_query_vector('alpha beta', 'orphan');
    RAISE EXCEPTION 'Expected exception was not raised';
EXCEPTION
    WHEN undefined_table THEN
        RAISE NOTICE 'Got expected exception for missing chunk table';
END;
$$;

DROP TABLE orphan_idf_stats;

---------------------------------------------------------------------------
-- Test 16: BM25 tokenizer returns empty array for NULL input
---------------------------------------------------------------------------

SELECT COALESCE(
    array_length(pgedge_vectorizer.bm25_tokenize(NULL), 1),
    0
) AS token_count;

---------------------------------------------------------------------------
-- Test 17: BM25 tokenizer returns empty array for all-stopword input
---------------------------------------------------------------------------

SELECT COALESCE(
    array_length(pgedge_vectorizer.bm25_tokenize('the is a an and'), 1),
    0
) AS token_count;

---------------------------------------------------------------------------
-- Test 17b: terms too long for the hash key are dropped, not merged
---------------------------------------------------------------------------

-- The dedup and IDF hashes both key on BM25_MAX_TERM_LEN (128) bytes, so
-- dynahash truncates anything longer. Two distinct terms sharing that much
-- of a prefix would merge into one entry with a combined term frequency and
-- a shared weight. They are dropped instead.

SELECT COALESCE(
    array_length(pgedge_vectorizer.bm25_tokenize(repeat('a', 200)), 1),
    0
) AS overlong_term_dropped;

-- Two distinct 151-character terms differing only in their last character.
-- Truncated to 127 bytes they are identical, so before this change the pair
-- collapsed to a single token.
SELECT COALESCE(
    array_length(
        pgedge_vectorizer.bm25_tokenize(
            repeat('a', 150) || 'x ' || repeat('a', 150) || 'y'),
        1),
    0
) AS overlong_pair_dropped;

-- A term just inside the limit is still indexed
SELECT COALESCE(
    array_length(pgedge_vectorizer.bm25_tokenize(repeat('a', 127)), 1),
    0
) AS max_length_term_kept;

-- The other side of the boundary: two distinct terms just inside the limit
-- must stay distinct. Dropping what does not fit is only correct if nothing
-- below the limit merges, so this is what would catch a guard that shortened
-- the effective key rather than one that failed to apply.
SELECT COALESCE(
    array_length(
        pgedge_vectorizer.bm25_tokenize(
            repeat('a', 126) || 'x ' || repeat('a', 126) || 'y'),
        1),
    0
) AS max_length_pair_distinct;

---------------------------------------------------------------------------
-- Test 18: bm25_decrement_idf_stats handles NULL/empty terms gracefully
---------------------------------------------------------------------------

-- Should return without error for NULL terms
SELECT pgedge_vectorizer.bm25_decrement_idf_stats(
    'hybrid_test_docs_content_chunks', NULL, 1
);

-- Should return without error for empty array
SELECT pgedge_vectorizer.bm25_decrement_idf_stats(
    'hybrid_test_docs_content_chunks', '{}'::text[], 1
);

---------------------------------------------------------------------------
-- Test 19: bm25_decrement_idf_stats adjusts counts correctly
---------------------------------------------------------------------------

-- Seed a term into the IDF stats table
INSERT INTO hybrid_test_docs_content_chunks_idf_stats
    (term, doc_freq)
VALUES ('testterm', 5);

-- Decrement by 1
SELECT pgedge_vectorizer.bm25_decrement_idf_stats(
    'hybrid_test_docs_content_chunks',
    ARRAY['testterm'],
    1
);

-- Verify the count was reduced
SELECT term, doc_freq
FROM hybrid_test_docs_content_chunks_idf_stats
WHERE term = 'testterm';

-- bm25_query_vector against a populated stats table.  Test 14 calls it while
-- _idf_stats is empty, which returns early without building the IDF hash.
SELECT pgedge_vectorizer.bm25_query_vector(
    'testterm sample', 'hybrid_test_docs_content_chunks'
) IS NOT NULL AS query_vector_with_populated_stats;

-- The loader fetches only the query's own terms, so vocabulary belonging to
-- other documents must not affect the result. This guards the scoping against
-- changing output; it cannot show the resource saving, which is why the number
-- of rows loaded is not asserted here.
--
SELECT pgedge_vectorizer.bm25_query_vector(
    'testterm sample', 'hybrid_test_docs_content_chunks')::text AS baseline \gset

INSERT INTO hybrid_test_docs_content_chunks_idf_stats (term, doc_freq)
SELECT 'unrelated' || g, 1 FROM generate_series(1, 5000) g;

SELECT :'baseline'::sparsevec
       = pgedge_vectorizer.bm25_query_vector(
             'testterm sample', 'hybrid_test_docs_content_chunks')
       AS unchanged_by_unrelated_vocabulary;

DELETE FROM hybrid_test_docs_content_chunks_idf_stats WHERE term LIKE 'unrelated%';

-- bm25_query_vector() inside a statement that owns relations. The loader runs
-- its SPI query in a subtransaction; if it does not restore the caller's
-- resource owner on release, this aborts the backend with "relcache reference
-- is not owned by resource owner". A plain SELECT does not catch it.
CREATE TABLE bm25_owner_check AS
SELECT pgedge_vectorizer.bm25_query_vector(
    'testterm sample', 'hybrid_test_docs_content_chunks') AS v;
SELECT count(*) AS rows_written FROM bm25_owner_check;
DROP TABLE bm25_owner_check;

-- Clean up the test row
DELETE FROM hybrid_test_docs_content_chunks_idf_stats WHERE term = 'testterm';

---------------------------------------------------------------------------
-- Test 20: disable_vectorization with drop_chunk_table also drops _idf_stats
---------------------------------------------------------------------------

-- Create a second vectorized column to test cleanup
CREATE TABLE hybrid_cleanup_test (
    id      BIGSERIAL PRIMARY KEY,
    body    TEXT
);

SELECT pgedge_vectorizer.enable_vectorization(
    'hybrid_cleanup_test'::regclass,
    'body',
    'token_based',
    100,
    10,
    1536
);

-- Verify _idf_stats table exists before disable
SELECT tablename
FROM pg_tables
WHERE tablename = 'hybrid_cleanup_test_body_chunks_idf_stats';

-- Disable with drop
SELECT pgedge_vectorizer.disable_vectorization(
    'hybrid_cleanup_test'::regclass, 'body', true
);

-- Verify _idf_stats table was also dropped
SELECT count(*) AS idf_stats_exists
FROM pg_tables
WHERE tablename = 'hybrid_cleanup_test_body_chunks_idf_stats';

DROP TABLE hybrid_cleanup_test;

---------------------------------------------------------------------------
-- Test 21: multi-column disambiguation error in hybrid_search
---------------------------------------------------------------------------

-- Create a table with two vectorized columns
CREATE TABLE hybrid_multi_test (
    id    BIGSERIAL PRIMARY KEY,
    title TEXT,
    body  TEXT
);

SELECT pgedge_vectorizer.enable_vectorization(
    'hybrid_multi_test'::regclass,
    'title',
    'token_based', 100, 10, 1536
);

SELECT pgedge_vectorizer.enable_vectorization(
    'hybrid_multi_test'::regclass,
    'body',
    'token_based', 100, 10, 1536
);

-- hybrid_search without specifying column should raise
SET pgedge_vectorizer.enable_hybrid = true;

DO $$
BEGIN
    PERFORM pgedge_vectorizer.hybrid_search(
        'hybrid_multi_test'::regclass, 'test query', 5
    );
    RAISE EXCEPTION 'Expected exception was not raised';
EXCEPTION
    WHEN OTHERS THEN
        IF sqlerrm LIKE '%multiple vectorized columns%' THEN
            RAISE NOTICE 'Got expected exception: %', sqlerrm;
        ELSE
            RAISE;
        END IF;
END;
$$;

RESET pgedge_vectorizer.enable_hybrid;

-- Clean up
SELECT pgedge_vectorizer.disable_vectorization(
    'hybrid_multi_test'::regclass, NULL, true
);

DROP TABLE hybrid_multi_test;

---------------------------------------------------------------------------
-- Test 20: the corpus statistics cache does not change results
---------------------------------------------------------------------------

-- N and the mean document length feed a ranking heuristic, and reading them
-- costs an unindexable scan of the chunk table on every call. Each backend
-- therefore holds them for corpus_stats_cache_ttl seconds. Whatever the
-- setting, the vector produced for a given corpus must be the same, so this
-- compares the two paths directly rather than asserting on either alone.

CREATE TABLE cache_docs (id BIGSERIAL PRIMARY KEY, body TEXT);
INSERT INTO cache_docs (body)
SELECT 'alpha beta gamma document number ' || g FROM generate_series(1, 25) g;

SELECT pgedge_vectorizer.enable_vectorization(
    'cache_docs', 'body', embedding_dimension => 3);

SET pgedge_vectorizer.corpus_stats_cache_ttl = 0;
SELECT pgedge_vectorizer.bm25_query_vector('alpha beta', 'cache_docs_body_chunks')
    AS uncached \gset

SET pgedge_vectorizer.corpus_stats_cache_ttl = 60;
SELECT pgedge_vectorizer.bm25_query_vector('alpha beta', 'cache_docs_body_chunks')
    AS cached \gset

SELECT :'uncached'::sparsevec = :'cached'::sparsevec AS cache_matches_uncached;

-- A second table must not read the first one's cached figures.
SELECT pgedge_vectorizer.bm25_avg_doc_len('cache_docs_body_chunks')
    <> pgedge_vectorizer.bm25_avg_doc_len('hybrid_test_docs_content_chunks')
    AS each_table_cached_separately;

RESET pgedge_vectorizer.corpus_stats_cache_ttl;

SELECT pgedge_vectorizer.disable_vectorization('cache_docs', 'body', true);
DROP TABLE cache_docs;

---------------------------------------------------------------------------
-- Test 21: the corpus statistics cache is keyed by relation, not by name
---------------------------------------------------------------------------

-- A chunk table is named unqualified and resolved through search_path, so one
-- string means different relations in a schema-per-tenant deployment. Keyed by
-- name, a pooled backend that switched tenants was handed whichever tenant's
-- corpus it had seen first, and scored the second tenant's queries against the
-- first one's statistics. The two corpora below differ only in document
-- length, so the vectors must differ; keyed by name they came back identical.

CREATE SCHEMA cache_tenant_a;
CREATE SCHEMA cache_tenant_b;

CREATE TABLE cache_tenant_a.t_chunks (id BIGSERIAL PRIMARY KEY, content TEXT,
                                      token_count INT);
CREATE TABLE cache_tenant_b.t_chunks (id BIGSERIAL PRIMARY KEY, content TEXT,
                                      token_count INT);
INSERT INTO cache_tenant_a.t_chunks (content, token_count)
SELECT 'alpha', 10 FROM generate_series(1, 50);
INSERT INTO cache_tenant_b.t_chunks (content, token_count)
SELECT 'alpha', 900 FROM generate_series(1, 50);

CREATE TABLE cache_tenant_a.t_chunks_idf_stats (term TEXT PRIMARY KEY,
                                                doc_freq INT NOT NULL);
CREATE TABLE cache_tenant_b.t_chunks_idf_stats (term TEXT PRIMARY KEY,
                                                doc_freq INT NOT NULL);
INSERT INTO cache_tenant_a.t_chunks_idf_stats VALUES ('alpha', 5);
INSERT INTO cache_tenant_b.t_chunks_idf_stats VALUES ('alpha', 5);

SET pgedge_vectorizer.corpus_stats_cache_ttl = 60;

SET search_path = cache_tenant_a, public;
SELECT pgedge_vectorizer.bm25_query_vector('alpha', 't_chunks') AS tenant_a \gset

SET search_path = cache_tenant_b, public;
SELECT pgedge_vectorizer.bm25_query_vector('alpha', 't_chunks') AS tenant_b \gset

-- RESET rather than SET, so that whatever the session started with is what
-- the rest of the file runs under. The comparison below needs no relation
-- lookup of its own.
RESET search_path;
SELECT :'tenant_a'::sparsevec <> :'tenant_b'::sparsevec
    AS same_name_different_schema_not_confused;

RESET pgedge_vectorizer.corpus_stats_cache_ttl;
DROP SCHEMA cache_tenant_a CASCADE;
DROP SCHEMA cache_tenant_b CASCADE;

---------------------------------------------------------------------------
-- Test 24: the corpus statistics cache re-reads once the corpus has grown
---------------------------------------------------------------------------

-- A time bound alone lets a small, fast-growing corpus go badly stale, and
-- the figures are written into stored vectors rather than only used for a
-- query. corpus_stats_cache_max_uses_pct bounds staleness in proportion instead:
-- at 5% of twenty documents, one cached use is allowed before a re-read.

CREATE TABLE growth_chunks (id BIGSERIAL PRIMARY KEY, content TEXT,
                            token_count INT);
CREATE TABLE growth_chunks_idf_stats (term TEXT PRIMARY KEY,
                                      doc_freq INT NOT NULL);
INSERT INTO growth_chunks (content, token_count)
SELECT 'alpha', 10 FROM generate_series(1, 20);
INSERT INTO growth_chunks_idf_stats VALUES ('alpha', 5);

-- Long enough that the time bound cannot be what fires.
SET pgedge_vectorizer.corpus_stats_cache_ttl = 3600;
SET pgedge_vectorizer.corpus_stats_cache_max_uses_pct = 5;

SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'growth_chunks') AS g1 \gset
INSERT INTO growth_chunks (content, token_count)
SELECT 'alpha', 900 FROM generate_series(1, 60);
SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'growth_chunks') AS g2 \gset
SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'growth_chunks') AS g3 \gset

SET pgedge_vectorizer.corpus_stats_cache_ttl = 0;
SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'growth_chunks') AS gtruth \gset

SELECT :'g1'::sparsevec = :'g2'::sparsevec AS use_within_budget_is_cached,
       :'g1'::sparsevec <> :'g3'::sparsevec AS budget_spent_forces_reread,
       :'g3'::sparsevec = :'gtruth'::sparsevec AS reread_matches_uncached;

-- With the use bound off, the same sequence stays on the stale figures.
SET pgedge_vectorizer.corpus_stats_cache_ttl = 3600;
SET pgedge_vectorizer.corpus_stats_cache_max_uses_pct = 0;

SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'growth_chunks') AS h1 \gset
INSERT INTO growth_chunks (content, token_count)
SELECT 'alpha', 900 FROM generate_series(1, 200);
SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'growth_chunks') AS h2 \gset
SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'growth_chunks') AS h3 \gset

-- All three, not just the ends: with the bound off no number of uses moves the
-- figures, which is what distinguishes this from the block above.
SELECT :'h1'::sparsevec = :'h2'::sparsevec
       AND :'h2'::sparsevec = :'h3'::sparsevec AS time_bound_alone_stays_stale;

RESET pgedge_vectorizer.corpus_stats_cache_ttl;
RESET pgedge_vectorizer.corpus_stats_cache_max_uses_pct;
DROP TABLE growth_chunks, growth_chunks_idf_stats;

---------------------------------------------------------------------------
-- Test 25: a doc_freq larger than the corpus does not lose the term
---------------------------------------------------------------------------

-- doc_freq is read fresh while the corpus size may be cached, so doc_freq
-- can outrun it. Unclamped that makes ln((N+1)/(df+0.5)) negative, and a
-- negative score is dropped, so the term vanishes from the vector rather
-- than merely being underweighted. The weight below is near zero, which is
-- what a term appearing in every document should score.

CREATE TABLE clamp_chunks (id BIGSERIAL PRIMARY KEY, content TEXT,
                           token_count INT);
CREATE TABLE clamp_chunks_idf_stats (term TEXT PRIMARY KEY,
                                     doc_freq INT NOT NULL);
INSERT INTO clamp_chunks (content, token_count)
SELECT 'alpha', 10 FROM generate_series(1, 10);
INSERT INTO clamp_chunks_idf_stats VALUES ('alpha', 5000);

SET pgedge_vectorizer.corpus_stats_cache_ttl = 0;
SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'clamp_chunks')
           <> '{}/65536'::sparsevec AS term_survives_df_over_n;

-- And that it is underweighted rather than merely present: a term in every
-- document carries almost no information, so bound the weight rather than
-- restating the claim in a comment.
SELECT split_part(split_part(
           pgedge_vectorizer.bm25_query_vector('alpha', 'clamp_chunks')::text,
           ':', 2), '}', 1)::float8 < 0.001 AS weight_is_near_zero;

RESET pgedge_vectorizer.corpus_stats_cache_ttl;
DROP TABLE clamp_chunks, clamp_chunks_idf_stats;

---------------------------------------------------------------------------
-- Test 26: a doc_freq above the cached corpus size re-reads it
---------------------------------------------------------------------------

-- doc_freq cannot exceed the corpus, so doc_freq above N is proof that the
-- cached N is stale rather than merely inconvenient. Clamping the weight alone
-- would leave the stale entry in place, so every later chunk in the window
-- would be scored against the same wrong corpus and have it persisted. The use
-- bound is disabled here so that only the re-read can refresh the entry.

CREATE TABLE reread_chunks (id BIGSERIAL PRIMARY KEY, content TEXT,
                            token_count INT);
CREATE TABLE reread_chunks_idf_stats (term TEXT PRIMARY KEY,
                                      doc_freq INT NOT NULL);
INSERT INTO reread_chunks (content, token_count)
SELECT 'alpha', 10 FROM generate_series(1, 20);
INSERT INTO reread_chunks_idf_stats VALUES ('alpha', 5);

SET pgedge_vectorizer.corpus_stats_cache_ttl = 3600;
SET pgedge_vectorizer.corpus_stats_cache_max_uses_pct = 0;

SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'reread_chunks') AS warm \gset

-- The corpus grows and doc_freq passes the cached 20, staying under the truth.
INSERT INTO reread_chunks (content, token_count)
SELECT 'alpha', 10 FROM generate_series(1, 200);
UPDATE reread_chunks_idf_stats SET doc_freq = 100 WHERE term = 'alpha';

SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'reread_chunks') AS r1 \gset
SET pgedge_vectorizer.corpus_stats_cache_ttl = 0;
SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'reread_chunks') AS fresh \gset

-- Merely clamping would score against doc_freq, 100, rather than the real 220.
SELECT :'r1'::sparsevec = :'fresh'::sparsevec AS reread_matches_a_fresh_read;

-- And the entry was repaired, not patched for one call: with doc_freq back
-- below N nothing triggers a re-read, so this can only match if the cached
-- corpus size is now the grown one.
SET pgedge_vectorizer.corpus_stats_cache_ttl = 3600;
UPDATE reread_chunks_idf_stats SET doc_freq = 5 WHERE term = 'alpha';
SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'reread_chunks') AS r2 \gset
SET pgedge_vectorizer.corpus_stats_cache_ttl = 0;
SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'reread_chunks') AS fresh2 \gset

SELECT :'r2'::sparsevec = :'fresh2'::sparsevec AS later_calls_use_the_refreshed_size;

RESET pgedge_vectorizer.corpus_stats_cache_ttl;
RESET pgedge_vectorizer.corpus_stats_cache_max_uses_pct;
DROP TABLE reread_chunks, reread_chunks_idf_stats;

---------------------------------------------------------------------------
-- Test 27: statistics a re-read cannot reconcile are adopted, not re-scanned
---------------------------------------------------------------------------

-- Test 26 covers the doc_freq that a re-read explains. This covers the one it
-- does not: a doc_freq left above the true corpus size by an earlier failure,
-- which no amount of re-reading will bring back under it. Re-reading on every
-- call would then scan the table forever to reach the same answer, so the
-- largest doc_freq is adopted as the entry's corpus size and the contradiction
-- stops. The use bound is off so that only the re-read can refresh the entry.

CREATE TABLE adopt_chunks (id BIGSERIAL PRIMARY KEY, content TEXT,
                           token_count INT);
CREATE TABLE adopt_chunks_idf_stats (term TEXT PRIMARY KEY,
                                     doc_freq INT NOT NULL);
INSERT INTO adopt_chunks (content, token_count)
SELECT 'alpha', 10 FROM generate_series(1, 10);
INSERT INTO adopt_chunks_idf_stats VALUES ('alpha', 5000);

SET pgedge_vectorizer.corpus_stats_cache_ttl = 3600;
SET pgedge_vectorizer.corpus_stats_cache_max_uses_pct = 0;

SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'adopt_chunks') AS a1 \gset

-- The term survives, as in test 25, but by the cached path rather than the
-- uncached one: this is the branch that writes a corpus size the table never
-- reported into the entry, and a term dropped here would be persisted.
SELECT :'a1'::sparsevec <> '{}/65536'::sparsevec AS term_survives_when_unreconcilable;

-- Grow the corpus with documents an order of magnitude longer. The corpus size
-- alone would not show a second re-read, since a fresh reading is still below
-- doc_freq and 5000 would be adopted again, but the mean document length would:
-- it is read by the same scan and is not clamped by anything.
INSERT INTO adopt_chunks (content, token_count)
SELECT 'alpha', 1000 FROM generate_series(1, 200);

SELECT pgedge_vectorizer.bm25_query_vector('alpha', 'adopt_chunks') AS a2 \gset

-- Unchanged, so the second call neither re-read nor contradicted the entry:
-- doc_freq was written into it rather than substituted for one call.
SELECT :'a1'::sparsevec = :'a2'::sparsevec AS adopted_size_ends_the_rescan;

-- And what was adopted is doc_freq itself, not some other figure: at N = df the
-- term appears in every document and carries almost no information, so the
-- weight lands just above zero, where the real size of ten would have put it
-- below zero and lost the term.
SELECT split_part(split_part(:'a1', ':', 2), '}', 1)::float8 < 0.001
           AS adopted_size_is_the_doc_freq;

RESET pgedge_vectorizer.corpus_stats_cache_ttl;
RESET pgedge_vectorizer.corpus_stats_cache_max_uses_pct;
DROP TABLE adopt_chunks, adopt_chunks_idf_stats;

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------

SELECT pgedge_vectorizer.disable_vectorization(
    'hybrid_test_docs'::regclass, 'content', true
);

DROP TABLE hybrid_test_docs;

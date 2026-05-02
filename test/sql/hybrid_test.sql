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

-- Explicitly disable hybrid search regardless of postgresql.conf value
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
    (term, doc_freq, total_docs, idf_weight)
VALUES ('testterm', 5, 10, 1.0);

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
-- Cleanup
---------------------------------------------------------------------------

SELECT pgedge_vectorizer.disable_vectorization(
    'hybrid_test_docs'::regclass, 'content', true
);

DROP TABLE hybrid_test_docs;

-- pgedge_vectorizer upgrade: 1.0 → 1.1
--
-- Adds hybrid BM25 + dense vector search support:
--   • pgedge_vectorizer.vectorizers registry table
--   • BM25 C functions (bm25_query_vector, bm25_avg_doc_len, bm25_tokenize)
--   • hybrid_search() and hybrid_search_simple() SQL functions
--   • sparse_embedding column and HNSW index on existing chunk tables
--   • Updated disable_vectorization() that drops _idf_stats tables correctly
--
-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION pgedge_vectorizer UPDATE TO '1.1'" to load this file. \quit

---------------------------------------------------------------------------
-- 1. Vectorizers registry
--    Tracks which chunk tables have been created for source tables.
--    Used by hybrid_search() to resolve chunk table names.
---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS pgedge_vectorizer.vectorizers (
    id            BIGSERIAL PRIMARY KEY,
    source_table  TEXT NOT NULL,
    source_column NAME NOT NULL,
    chunk_table   TEXT NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (source_table, source_column)
);

COMMENT ON TABLE pgedge_vectorizer.vectorizers IS
'Registry of active vectorizer configurations (source table → chunk table)';

---------------------------------------------------------------------------
-- 2. BM25 C functions
---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgedge_vectorizer.bm25_query_vector(
    query TEXT,
    chunk_table TEXT
) RETURNS sparsevec
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_bm25_query_vector'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.bm25_query_vector IS
'Compute a BM25 sparse vector for a query text using IDF stats from the given chunk table';

CREATE OR REPLACE FUNCTION pgedge_vectorizer.bm25_avg_doc_len(
    chunk_table TEXT
) RETURNS FLOAT8
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_bm25_avg_doc_len'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.bm25_avg_doc_len IS
'Return the average document length (in tokens) for the given chunk table';

CREATE OR REPLACE FUNCTION pgedge_vectorizer.bm25_tokenize(
    query TEXT
) RETURNS TEXT[]
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_bm25_tokenize'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.bm25_tokenize IS
'Tokenize text and return the non-stopword terms (useful for testing)';

---------------------------------------------------------------------------
-- 3. Hybrid search functions
---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgedge_vectorizer.hybrid_search(
    p_source_table   REGCLASS,
    p_query          TEXT,
    p_limit          INT     DEFAULT 10,
    p_alpha          FLOAT8  DEFAULT 0.7,
    p_rrf_k          INT     DEFAULT 60
)
RETURNS TABLE (
    source_id   TEXT,
    chunk       TEXT,
    dense_rank  INT,
    sparse_rank INT,
    rrf_score   FLOAT8
)
LANGUAGE plpgsql AS $$
DECLARE
    v_chunk_table  TEXT;
    v_query_dense  vector;
    v_query_sparse sparsevec;
BEGIN
    -- Look up the chunk table name from the vectorizers registry
    SELECT vz.chunk_table INTO v_chunk_table
    FROM pgedge_vectorizer.vectorizers vz
    WHERE vz.source_table = p_source_table::TEXT
    LIMIT 1;

    IF v_chunk_table IS NULL THEN
        RAISE EXCEPTION
            'No vectorizer found for table %. '
            'Call pgedge_vectorizer.enable_vectorization() first.',
            p_source_table;
    END IF;

    -- Generate dense query vector via the existing C function
    v_query_dense := pgedge_vectorizer.generate_embedding(p_query);

    -- Generate sparse BM25 query vector
    v_query_sparse := pgedge_vectorizer.bm25_query_vector(
                          p_query, v_chunk_table);

    -- Run both ranked lists and merge with Reciprocal Rank Fusion.
    -- Join on chunk id (not source_id) to avoid mixing unrelated chunks
    -- from the same document.  source_id is cast to TEXT to support
    -- arbitrary PK types (BIGINT, UUID, VARCHAR, etc.).
    RETURN QUERY EXECUTE format($sql$
        WITH dense AS (
            SELECT
                id,
                source_id::text AS source_id,
                content AS chunk,
                ROW_NUMBER() OVER (
                    ORDER BY embedding <=> %L::vector
                ) AS rnk
            FROM %I
            WHERE embedding IS NOT NULL
            LIMIT %s * 3
        ),
        sparse AS (
            SELECT
                id,
                source_id::text AS source_id,
                content AS chunk,
                ROW_NUMBER() OVER (
                    ORDER BY sparse_embedding <#> %L::sparsevec ASC
                ) AS rnk
            FROM %I
            WHERE sparse_embedding IS NOT NULL
            LIMIT %s * 3
        ),
        merged AS (
            SELECT
                COALESCE(d.source_id, s.source_id)  AS source_id,
                COALESCE(d.chunk,     s.chunk)       AS chunk,
                COALESCE(d.rnk, 9999)::INT           AS dense_rank,
                COALESCE(s.rnk, 9999)::INT           AS sparse_rank,
                (
                      %s::float8  / (%s + COALESCE(d.rnk, 9999))
                    + (1.0 - %s::float8) / (%s + COALESCE(s.rnk, 9999))
                )                                    AS rrf_score
            FROM dense d
            FULL OUTER JOIN sparse s USING (id)
        )
        SELECT
            source_id,
            chunk,
            dense_rank,
            sparse_rank,
            rrf_score
        FROM merged
        ORDER BY rrf_score DESC
        LIMIT %s
    $sql$,
        v_query_dense,   v_chunk_table, p_limit,
        v_query_sparse,  v_chunk_table, p_limit,
        p_alpha, p_rrf_k,
        p_alpha, p_rrf_k,
        p_limit
    );
END;
$$;

COMMENT ON FUNCTION pgedge_vectorizer.hybrid_search IS
'Hybrid BM25 + dense vector search using Reciprocal Rank Fusion.
 p_alpha controls the weight of dense results (0 = pure sparse, 1 = pure dense).
 p_rrf_k is the RRF rank smoothing constant (default 60).
 Requires pgedge_vectorizer.enable_hybrid = true in postgresql.conf.';

CREATE OR REPLACE FUNCTION pgedge_vectorizer.hybrid_search_simple(
    p_source_table REGCLASS,
    p_query        TEXT,
    p_limit        INT DEFAULT 10
)
RETURNS TABLE (
    source_id  TEXT,
    chunk      TEXT,
    rrf_score  FLOAT8
)
LANGUAGE sql AS $$
    SELECT source_id, chunk, rrf_score
    FROM pgedge_vectorizer.hybrid_search(
             p_source_table, p_query, p_limit);
$$;

COMMENT ON FUNCTION pgedge_vectorizer.hybrid_search_simple IS
'Convenience wrapper for hybrid_search() returning only source_id, chunk, and rrf_score';

---------------------------------------------------------------------------
-- 4. Replace disable_vectorization with the updated version that correctly
--    drops _idf_stats tables when source_column IS NULL.
---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgedge_vectorizer.disable_vectorization(
    source_table REGCLASS,
    source_column NAME DEFAULT NULL,
    drop_chunk_table BOOLEAN DEFAULT FALSE
) RETURNS VOID AS $$
DECLARE
    trigger_name TEXT;
    chunk_table TEXT;
    trigger_rec RECORD;
    chunk_tables_to_drop TEXT[];
    ct TEXT;
BEGIN
    -- If column specified, drop that specific trigger
    IF source_column IS NOT NULL THEN
        trigger_name := source_table::TEXT || '_' || source_column || '_vectorization_trigger';
        chunk_table := source_table::TEXT || '_' || source_column || '_chunks';

        -- Drop trigger
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', trigger_name, source_table);

        -- Remove orphaned queue items for this chunk table
        EXECUTE format('DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = %L AND status IN (''pending'', ''processing'')', chunk_table);

        -- Remove from vectorizers registry.
        -- Use EXECUTE...USING to avoid PL/pgSQL variable/column
        -- name ambiguity for source_table and source_column.
        EXECUTE
            'DELETE FROM pgedge_vectorizer.vectorizers
              WHERE source_table = $1 AND source_column = $2'
        USING source_table::TEXT, source_column;

        -- Optionally drop chunk table and IDF stats table
        IF drop_chunk_table THEN
            EXECUTE format('DROP TABLE IF EXISTS %I CASCADE',
                           chunk_table || '_idf_stats');
            EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', chunk_table);
            RAISE NOTICE 'Vectorization disabled and chunk table dropped: %', chunk_table;
        ELSE
            RAISE NOTICE 'Vectorization disabled (chunk table preserved): %', chunk_table;
        END IF;
    ELSE
        -- Drop all vectorization triggers for this table
        FOR trigger_rec IN
            SELECT tgname
            FROM pg_trigger t
            JOIN pg_class c ON t.tgrelid = c.oid
            WHERE c.oid = source_table
            AND tgname LIKE source_table::TEXT || '%_vectorization_trigger'
        LOOP
            EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', trigger_rec.tgname, source_table);
            RAISE NOTICE 'Dropped trigger: %', trigger_rec.tgname;
        END LOOP;

        -- Remove orphaned queue items for all chunk tables of this source
        DELETE FROM pgedge_vectorizer.queue q
        WHERE q.chunk_table LIKE source_table::TEXT || '_%_chunks'
        AND q.status IN ('pending', 'processing');

        -- Collect chunk table names before deleting registry entries
        SELECT ARRAY(
            SELECT v.chunk_table
            FROM pgedge_vectorizer.vectorizers v
            WHERE v.source_table = source_table::TEXT
        ) INTO chunk_tables_to_drop;

        -- Remove all vectorizer registry entries for this source table
        EXECUTE
            'DELETE FROM pgedge_vectorizer.vectorizers WHERE source_table = $1'
        USING source_table::TEXT;

        -- Optionally drop all chunk tables and their IDF stats tables
        IF drop_chunk_table THEN
            FOREACH ct IN ARRAY COALESCE(chunk_tables_to_drop, '{}') LOOP
                EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', ct || '_idf_stats');
                EXECUTE format('DROP TABLE IF EXISTS %I CASCADE', ct);
                RAISE NOTICE 'Vectorization disabled and chunk table dropped: %', ct;
            END LOOP;
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.disable_vectorization IS
'Disable automatic vectorization for a table';

---------------------------------------------------------------------------
-- 5. Backfill vectorizers registry from existing triggers, then add
--    sparse_embedding column and HNSW index to each discovered chunk table.
--
--    Trigger args layout (set by enable_vectorization):
--      TG_ARGV[0] = source_column
--      TG_ARGV[1] = chunk_table
--      TG_ARGV[2] = strategy
--      TG_ARGV[3] = chunk_size
--      TG_ARGV[4] = chunk_overlap
--      TG_ARGV[5] = source_pk
--      TG_ARGV[6] = pk_col_type
---------------------------------------------------------------------------

DO $$
DECLARE
    rec     RECORD;
    args    TEXT[];
    src_col TEXT;
    chk_tbl TEXT;
BEGIN
    -- Populate vectorizers from existing vectorization triggers
    FOR rec IN
        SELECT c.oid::regclass::text AS source_table,
               t.tgargs
        FROM pg_trigger t
        JOIN pg_class  c ON t.tgrelid = c.oid
        WHERE t.tgfoid = (
            SELECT p.oid
            FROM pg_proc p
            JOIN pg_namespace n ON p.pronamespace = n.oid
            WHERE n.nspname = 'pgedge_vectorizer'
              AND p.proname = 'vectorization_trigger'
        )
    LOOP
        -- tgargs is a bytea of null-separated strings with a trailing null.
        -- Split on chr(0); last element will be an empty string — ignore it.
        args    := string_to_array(convert_from(rec.tgargs, 'UTF8'), chr(0));
        src_col := args[1];   -- TG_ARGV[0]
        chk_tbl := args[2];   -- TG_ARGV[1]

        IF src_col IS NOT NULL AND src_col <> ''
           AND chk_tbl IS NOT NULL AND chk_tbl <> ''
        THEN
            INSERT INTO pgedge_vectorizer.vectorizers
                        (source_table, source_column, chunk_table)
            VALUES      (rec.source_table, src_col, chk_tbl)
            ON CONFLICT (source_table, source_column)
            DO UPDATE SET chunk_table = EXCLUDED.chunk_table;
        END IF;
    END LOOP;

    -- Add sparse_embedding column and HNSW index to every known chunk table
    FOR rec IN
        SELECT chunk_table FROM pgedge_vectorizer.vectorizers
    LOOP
        chk_tbl := rec.chunk_table;

        EXECUTE format(
            'ALTER TABLE %I ADD COLUMN IF NOT EXISTS sparse_embedding sparsevec(65536)',
            chk_tbl);

        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS %I ON %I '
            'USING hnsw (sparse_embedding sparsevec_ip_ops) '
            'WHERE sparse_embedding IS NOT NULL',
            chk_tbl || '_sparse_embedding_idx', chk_tbl);
    END LOOP;
END;
$$;

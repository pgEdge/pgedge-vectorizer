-- pgedge_vectorizer extension
-- Version 1.1
--
-- Asynchronous text chunking and vectorization for PostgreSQL

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgedge_vectorizer" to load this file. \quit

---------------------------------------------------------------------------
-- Create schema
---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS pgedge_vectorizer;

---------------------------------------------------------------------------
-- Vectorizers registry
-- Tracks which chunk tables have been created for source tables.
-- Used by hybrid_search() to resolve chunk table names.
---------------------------------------------------------------------------

CREATE TABLE pgedge_vectorizer.vectorizers (
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
-- Queue table for async embedding generation
---------------------------------------------------------------------------

CREATE TABLE pgedge_vectorizer.queue (
    id BIGSERIAL PRIMARY KEY,
    chunk_id BIGINT NOT NULL,          -- ID of the chunk in the chunk table
    chunk_table TEXT NOT NULL,          -- Name of the chunk table
    content TEXT NOT NULL,              -- Text content to embed
    status TEXT NOT NULL DEFAULT 'pending'
        CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    attempts INT NOT NULL DEFAULT 0,
    max_attempts INT NOT NULL DEFAULT 3,
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processing_started_at TIMESTAMPTZ,
    processed_at TIMESTAMPTZ,
    next_retry_at TIMESTAMPTZ,
    metadata JSONB
);

-- Indexes for efficient queue processing
CREATE INDEX idx_queue_status ON pgedge_vectorizer.queue(status, next_retry_at)
    WHERE status IN ('pending', 'failed');

CREATE INDEX idx_queue_chunk ON pgedge_vectorizer.queue(chunk_table, chunk_id);

CREATE INDEX idx_queue_created_at ON pgedge_vectorizer.queue(created_at)
    WHERE status = 'pending';

---------------------------------------------------------------------------
-- C function declarations
---------------------------------------------------------------------------

-- Chunking function
CREATE FUNCTION pgedge_vectorizer.chunk_text(
    content TEXT,
    strategy TEXT DEFAULT NULL,
    chunk_size INT DEFAULT NULL,
    overlap INT DEFAULT NULL
) RETURNS TEXT[]
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_chunk_text_sql'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.chunk_text IS
'Split text into chunks according to the specified strategy';

-- Embedding generation function
CREATE FUNCTION pgedge_vectorizer.generate_embedding(
    query_text TEXT
) RETURNS vector
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_generate_embedding'
LANGUAGE C STABLE STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.generate_embedding IS
'Generate an embedding vector from query text using the configured provider';

-- Embedding dimension detection function
CREATE FUNCTION pgedge_vectorizer.detect_embedding_dimension()
RETURNS INT
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_detect_embedding_dimension'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.detect_embedding_dimension IS
'Detect the embedding dimension of the currently configured provider/model';

-- BM25 query vector function
-- Tokenizes the query and computes a sparse vector using current IDF stats.
-- Used by hybrid_search() for the query-side sparse representation.
CREATE FUNCTION pgedge_vectorizer.bm25_query_vector(
    query TEXT,
    chunk_table TEXT
) RETURNS sparsevec
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_bm25_query_vector'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.bm25_query_vector IS
'Compute a BM25 sparse vector for a query text using IDF stats from the given chunk table';

-- BM25 average document length helper
CREATE FUNCTION pgedge_vectorizer.bm25_avg_doc_len(
    chunk_table TEXT
) RETURNS FLOAT8
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_bm25_avg_doc_len'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.bm25_avg_doc_len IS
'Return the average document length (in tokens) for the given chunk table';

-- BM25 tokenizer (exposed for testing)
CREATE FUNCTION pgedge_vectorizer.bm25_tokenize(
    query TEXT
) RETURNS TEXT[]
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_bm25_tokenize'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.bm25_tokenize IS
'Tokenize text and return the non-stopword terms (useful for testing)';

-- UTF-8 aware approximate token counter (C implementation)
CREATE FUNCTION pgedge_vectorizer.count_tokens(
    p_text TEXT
) RETURNS INT
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_count_tokens_sql'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.count_tokens IS
'Approximate token count using UTF-8 character counting (~4 chars/token).';

-- Internal plpython3u implementation (created only if plpython3u is available)
DO $tiktoken_init$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_language WHERE lanname = 'plpython3u') THEN
        CREATE FUNCTION pgedge_vectorizer._tiktoken_internal(
            p_text     TEXT,
            p_encoding TEXT DEFAULT 'cl100k_base'
        ) RETURNS INT
        LANGUAGE plpython3u STABLE STRICT
        AS $py$
            """Return the exact token count for p_text using the given tiktoken encoding."""
            import tiktoken
            enc = tiktoken.get_encoding(p_encoding)
            return len(enc.encode(p_text, disallowed_special=()))
        $py$;
        COMMENT ON FUNCTION pgedge_vectorizer._tiktoken_internal IS
        'Internal plpython3u helper used by tiktoken_count_tokens(); do not call directly.';
    END IF;
END;
$tiktoken_init$;

-- Recovery path: (re)creates _tiktoken_internal when plpython3u is installed
-- after the extension was first loaded.  Call via enable_tiktoken_support().
CREATE FUNCTION pgedge_vectorizer.enable_tiktoken_support()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_language WHERE lanname = 'plpython3u') THEN
        RETURN 'plpython3u is not available; install the postgresql-plpython3 '
               'package for your PostgreSQL version and retry';
    END IF;

    EXECUTE $inner$
        CREATE OR REPLACE FUNCTION pgedge_vectorizer._tiktoken_internal(
            p_text     TEXT,
            p_encoding TEXT DEFAULT 'cl100k_base'
        ) RETURNS INT
        LANGUAGE plpython3u STABLE STRICT
        AS $py$
            import tiktoken
            enc = tiktoken.get_encoding(p_encoding)
            return len(enc.encode(p_text, disallowed_special=()))
        $py$
    $inner$;

    -- Register with the extension; silently skip if already a member
    -- (happens when plpython3u was available at CREATE EXTENSION time).
    BEGIN
        EXECUTE $inner$
            ALTER EXTENSION pgedge_vectorizer ADD FUNCTION
                pgedge_vectorizer._tiktoken_internal(TEXT, TEXT)
        $inner$;
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;

    EXECUTE $inner$
        COMMENT ON FUNCTION pgedge_vectorizer._tiktoken_internal(TEXT, TEXT) IS
        'Internal plpython3u helper used by tiktoken_count_tokens(); do not call directly.'
    $inner$;

    -- Verify tiktoken Python package is importable at runtime
    BEGIN
        PERFORM pgedge_vectorizer._tiktoken_internal('', 'cl100k_base');
    EXCEPTION WHEN OTHERS THEN
        RETURN 'tiktoken not available: ' || SQLERRM;
    END;

    RETURN 'ok';
END;
$$;

COMMENT ON FUNCTION pgedge_vectorizer.enable_tiktoken_support IS
'Creates or recreates the _tiktoken_internal plpython3u helper. Call this '
'after installing plpython3u (postgresql-plpython3-XX) and the tiktoken '
'Python package when the extension was originally installed without plpython3u. '
'Returns ''ok'' on success or a message describing what is missing.';

-- Tiktoken-based token counting with graceful fallback to approximation
CREATE FUNCTION pgedge_vectorizer.tiktoken_count_tokens(
    p_text     TEXT,
    p_encoding TEXT DEFAULT 'cl100k_base'
) RETURNS INT
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    result INT;
BEGIN
    IF p_text IS NULL OR p_text = '' THEN
        RETURN 0;
    END IF;

    IF NOT COALESCE(
        current_setting('pgedge_vectorizer.use_tiktoken', true),
        'false'
    )::BOOLEAN THEN
        RETURN pgedge_vectorizer.count_tokens(p_text);
    END IF;

    -- use_tiktoken = on: delegate to plpython3u internal function
    BEGIN
        SELECT pgedge_vectorizer._tiktoken_internal(p_text, p_encoding) INTO result;
        RETURN result;
    EXCEPTION WHEN OTHERS THEN
        RETURN pgedge_vectorizer.count_tokens(p_text);
    END;
END;
$$;

COMMENT ON FUNCTION pgedge_vectorizer.tiktoken_count_tokens IS
'Count tokens using tiktoken when pgedge_vectorizer.use_tiktoken = on, '
'otherwise returns a character-based approximation via count_tokens(). '
'Requires plpython3u and the tiktoken Python package when use_tiktoken is on. '
'Used by enable_vectorization() and recreate_chunks() for stored token_count accuracy. '
'The vectorization_trigger() always uses count_tokens() for hot-path performance.';

---------------------------------------------------------------------------
-- SQL Functions
---------------------------------------------------------------------------

-- Enable vectorization for a table/column
CREATE FUNCTION pgedge_vectorizer.enable_vectorization(
    source_table REGCLASS,
    source_column NAME,
    chunk_strategy TEXT DEFAULT NULL,
    chunk_size INT DEFAULT NULL,
    chunk_overlap INT DEFAULT NULL,
    embedding_dimension INT DEFAULT NULL,
    chunk_table_name TEXT DEFAULT NULL,
    source_pk NAME DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    chunk_table TEXT;
    trigger_name TEXT;
    actual_strategy TEXT;
    actual_chunk_size INT;
    actual_chunk_overlap INT;
    pk_col_type TEXT;
    pk_count INT;
BEGIN
    -- Use defaults from GUC if not provided
    actual_strategy := COALESCE(chunk_strategy,
        current_setting('pgedge_vectorizer.default_chunk_strategy'));
    actual_chunk_size := COALESCE(chunk_size,
        current_setting('pgedge_vectorizer.default_chunk_size')::INT);
    actual_chunk_overlap := COALESCE(chunk_overlap,
        current_setting('pgedge_vectorizer.default_chunk_overlap')::INT);

    -- Auto-detect embedding dimension from configured model if not specified
    IF embedding_dimension IS NULL THEN
        embedding_dimension := pgedge_vectorizer.detect_embedding_dimension();
        RAISE NOTICE 'Auto-detected embedding dimension: %', embedding_dimension;
    END IF;

    -- Detect PK column count to reject composite PKs
    SELECT count(*)
    INTO pk_count
    FROM pg_index i
    JOIN pg_attribute a ON a.attrelid = i.indrelid
      AND a.attnum = ANY(i.indkey)
    WHERE i.indrelid = source_table
      AND i.indisprimary;

    IF pk_count = 0 AND source_pk IS NULL THEN
        RAISE EXCEPTION 'Table % has no primary key. Use the source_pk parameter to specify the column to use as document identifier.',
            source_table;
    END IF;

    IF pk_count > 1 AND source_pk IS NULL THEN
        RAISE EXCEPTION 'Table % has a composite primary key (% columns), which is not supported by auto-detection. Use the source_pk parameter to specify a single column.',
            source_table, pk_count;
    END IF;

    -- Auto-detect PK column name and type if source_pk not specified
    IF source_pk IS NULL THEN
        SELECT a.attname, format_type(a.atttypid, a.atttypmod)
        INTO source_pk, pk_col_type
        FROM pg_index i
        JOIN pg_attribute a ON a.attrelid = i.indrelid
          AND a.attnum = ANY(i.indkey)
        WHERE i.indrelid = source_table
          AND i.indisprimary;
    ELSE
        -- User specified a column; look up its type
        SELECT format_type(a.atttypid, a.atttypmod)
        INTO pk_col_type
        FROM pg_attribute a
        WHERE a.attrelid = source_table
          AND a.attname = source_pk
          AND NOT a.attisdropped;

        IF pk_col_type IS NULL THEN
            RAISE EXCEPTION 'Column "%" does not exist on table %',
                source_pk, source_table;
        END IF;
    END IF;

    RAISE NOTICE 'Using primary key column: % (%)', source_pk, pk_col_type;

    -- Determine chunk table name.
    -- Include source schema in the generated identifier text to avoid
    -- collisions when two schemas have the same relname.
    chunk_table := COALESCE(chunk_table_name,
                            source_table::TEXT || '_' || source_column || '_chunks');

    -- Create chunks table
    -- Note: pk_col_type uses %s (not %I) because format_type() returns
    -- canonical SQL type names (e.g. "character varying(26)") that would
    -- be incorrectly double-quoted by %I. This value is system-controlled.
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I (
            id BIGSERIAL PRIMARY KEY,
            source_id %s NOT NULL,
            chunk_index INT NOT NULL,
            content TEXT NOT NULL,
            token_count INT,
            embedding vector(%s),
            sparse_embedding sparsevec(65536),
            created_at TIMESTAMPTZ DEFAULT NOW(),
            updated_at TIMESTAMPTZ DEFAULT NOW(),
            UNIQUE(source_id, chunk_index)
        )', chunk_table, pk_col_type, embedding_dimension);

    -- Add sparse columns to pre-existing chunk tables (upgrade path).
    -- These are no-ops for freshly created tables (columns exist already).
    EXECUTE format('
        ALTER TABLE %I
        ADD COLUMN IF NOT EXISTS sparse_embedding sparsevec(65536)',
        chunk_table);

    -- Create vector index for similarity search
    EXECUTE format('
        CREATE INDEX IF NOT EXISTS %I ON %I
        USING hnsw (embedding vector_cosine_ops)',
        chunk_table || '_embedding_idx', chunk_table);

    -- Create index on source_id for joins
    EXECUTE format('
        CREATE INDEX IF NOT EXISTS %I ON %I (source_id)',
        chunk_table || '_source_id_idx', chunk_table);

    -- Create HNSW index on sparse_embedding for fast sparse search
    EXECUTE format('
        CREATE INDEX IF NOT EXISTS %I ON %I
        USING hnsw (sparse_embedding sparsevec_ip_ops)
        WHERE sparse_embedding IS NOT NULL',
        chunk_table || '_sparse_idx', chunk_table);

    -- Create BM25 IDF statistics table for this chunk table
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I (
            term        TEXT    PRIMARY KEY,
            doc_freq    INT     NOT NULL DEFAULT 1,
            total_docs  INT     NOT NULL DEFAULT 1,
            idf_weight  FLOAT8  NOT NULL DEFAULT 0.693,
            updated_at  TIMESTAMPTZ DEFAULT now()
        )', chunk_table || '_idf_stats');

    -- Register in vectorizers table for hybrid_search() lookups.
    -- Use EXECUTE...USING to avoid PL/pgSQL variable/column ambiguity.
    EXECUTE
        'INSERT INTO pgedge_vectorizer.vectorizers
             (source_table, source_column, chunk_table)
         VALUES ($1, $2, $3)
         ON CONFLICT (source_table, source_column)
         DO UPDATE SET chunk_table = EXCLUDED.chunk_table'
    USING source_table::TEXT, source_column, chunk_table;

    -- Create trigger to chunk and queue on insert/update
    trigger_name := source_table::TEXT || '_' || source_column || '_vectorization_trigger';

    EXECUTE format('
        CREATE OR REPLACE TRIGGER %I
        AFTER INSERT OR UPDATE ON %s
        FOR EACH ROW
        EXECUTE FUNCTION pgedge_vectorizer.vectorization_trigger(%L, %L, %L, %L, %L, %L, %L)',
        trigger_name, source_table,
        source_column, chunk_table, actual_strategy,
        actual_chunk_size, actual_chunk_overlap, source_pk, pk_col_type);

    RAISE NOTICE 'Vectorization enabled: % -> %', source_table, chunk_table;
    RAISE NOTICE 'Strategy: %, chunk_size: %, overlap: %',
        actual_strategy, actual_chunk_size, actual_chunk_overlap;

    -- Process existing rows
    DECLARE
        row_record RECORD;
        doc_content TEXT;
        chunks TEXT[];
        chunk_text TEXT;
        i INT;
        chunk_id BIGINT;
        needs_embedding BOOLEAN;
        needs_sparse BOOLEAN;
        rows_processed INT := 0;
    BEGIN
        RAISE NOTICE 'Processing existing rows...';

        FOR row_record IN EXECUTE format('SELECT %I as pk_val, %I as content FROM %s WHERE %I IS NOT NULL AND %I != ''''',
            source_pk, source_column, source_table, source_column, source_column)
        LOOP
            doc_content := row_record.content;

            -- Chunk the document
            chunks := pgedge_vectorizer.chunk_text(doc_content, actual_strategy, actual_chunk_size, actual_chunk_overlap);

            -- Insert chunks and queue for embedding
            FOR i IN 1..array_length(chunks, 1) LOOP
                chunk_text := chunks[i];

                -- Insert or update chunk (only clear embedding if content changed)
                EXECUTE format('
                    INSERT INTO %I (source_id, chunk_index, content, token_count)
                    VALUES ($1, $2, $3, $4)
                    ON CONFLICT (source_id, chunk_index)
                    DO UPDATE SET content = EXCLUDED.content,
                                  token_count = EXCLUDED.token_count,
                                  embedding = CASE
                                      WHEN %I.content = EXCLUDED.content THEN %I.embedding
                                      ELSE NULL
                                  END,
                                  sparse_embedding = CASE
                                      WHEN %I.content = EXCLUDED.content THEN %I.sparse_embedding
                                      ELSE NULL
                                  END,
                                  updated_at = NOW()
                    RETURNING id,
                              (embedding IS NULL) AS needs_embedding,
                              (sparse_embedding IS NULL) AS needs_sparse',
                    chunk_table, chunk_table, chunk_table, chunk_table, chunk_table)
                USING row_record.pk_val, i, chunk_text,
                      pgedge_vectorizer.tiktoken_count_tokens(chunk_text)  -- uses tiktoken when use_tiktoken=on
                INTO chunk_id, needs_embedding, needs_sparse;

                -- Queue if dense or sparse work is needed.
                IF needs_embedding OR needs_sparse THEN
                    INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content, metadata)
                    VALUES (
                        chunk_id,
                        chunk_table,
                        chunk_text,
                        CASE
                            WHEN NOT needs_embedding AND needs_sparse
                                THEN jsonb_build_object('sparse_only', true)
                            ELSE NULL
                        END
                    );
                END IF;
            END LOOP;

            -- Remove queue entries for stale high-index chunks before deleting them.
            -- Only targets 'pending'/'failed'; 'processing' items are left for the
            -- worker to handle gracefully via its SPI_processed == 0 check.
            -- pk_col_type uses %s: value from format_type() is system-controlled
            EXECUTE format(
                'DELETE FROM pgedge_vectorizer.queue
                 WHERE chunk_table = %L
                   AND chunk_id IN (
                       SELECT id FROM %I WHERE source_id = $1::%s AND chunk_index > $2
                   )
                   AND status IN (''pending'', ''failed'')',
                chunk_table, chunk_table, pk_col_type)
                USING row_record.pk_val, COALESCE(array_length(chunks, 1), 0);

            -- Remove any stale chunks beyond the new chunk count
            -- pk_col_type uses %s: value from format_type() is system-controlled
            EXECUTE format('DELETE FROM %I WHERE source_id = $1::%s AND chunk_index > $2',
                chunk_table, pk_col_type)
                USING row_record.pk_val, COALESCE(array_length(chunks, 1), 0);

            rows_processed := rows_processed + 1;
        END LOOP;

        RAISE NOTICE 'Processed % existing rows', rows_processed;
    END;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.enable_vectorization IS
'Enable automatic chunking and vectorization for a table column';

-- Disable vectorization for a table column
CREATE FUNCTION pgedge_vectorizer.disable_vectorization(
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

        -- Look up the authoritative chunk table name from the registry so that
        -- custom chunk_table_name values (passed to enable_vectorization) are
        -- honored; fall back to the default convention only when not registered.
        -- Use EXECUTE...USING to avoid variable/column name ambiguity for
        -- source_table and source_column (same pattern as the DELETE below).
        EXECUTE
            'SELECT v.chunk_table FROM pgedge_vectorizer.vectorizers v
              WHERE v.source_table = $1 AND v.source_column = $2'
        INTO chunk_table
        USING source_table::TEXT, source_column;

        IF chunk_table IS NULL THEN
            chunk_table := source_table::TEXT || '_' || source_column || '_chunks';
        END IF;

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

        -- Collect chunk table names before deleting registry entries.
        -- Use EXECUTE...USING to avoid PL/pgSQL variable/column
        -- name ambiguity for source_table.
        EXECUTE
            'SELECT ARRAY(
                SELECT v.chunk_table
                FROM pgedge_vectorizer.vectorizers v
                WHERE v.source_table = $1
            )'
        INTO chunk_tables_to_drop
        USING source_table::TEXT;

        -- Remove orphaned queue items for exact chunk tables from registry.
        DELETE FROM pgedge_vectorizer.queue q
        WHERE q.chunk_table = ANY(COALESCE(chunk_tables_to_drop, '{}'))
        AND q.status IN ('pending', 'processing');

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

-- BM25 IDF stats decrement helper
-- Called by vectorization_trigger before deleting old chunks on UPDATE so that
-- the doc_freq counts for the old document's terms are removed before the
-- worker re-increments them for the new chunks.  This prevents permanent
-- overcount of IDF stats when documents are updated.
CREATE OR REPLACE FUNCTION pgedge_vectorizer.bm25_decrement_idf_stats(
    p_chunk_table TEXT,
    p_terms       TEXT[],
    p_deleted_chunks_count INT DEFAULT 1
) RETURNS VOID AS $$
DECLARE
    new_total INT;
BEGIN
    IF p_terms IS NULL OR array_length(p_terms, 1) IS NULL THEN
        RETURN;
    END IF;

    IF p_deleted_chunks_count IS NULL OR p_deleted_chunks_count <= 0 THEN
        RETURN;
    END IF;

    -- Count chunks BEFORE the deletion so new_total reflects the post-delete
    -- corpus size after deleting the current document's chunks.
    EXECUTE format('SELECT GREATEST(count(*)::int - $1, 0) FROM %I', p_chunk_table)
    INTO new_total
    USING p_deleted_chunks_count;

    EXECUTE format(
        'UPDATE %I SET'
        '    doc_freq   = GREATEST(doc_freq - $2, 0),'
        '    total_docs = $1,'
        '    idf_weight = CASE'
        '                     WHEN GREATEST(doc_freq - $2, 0) <= 0 THEN 0.0'
        '                     ELSE ln(1.0 + ($1::float8 - GREATEST(doc_freq - $2, 0) + 0.5)'
        '                                  / (GREATEST(doc_freq - $2, 0) + 0.5))'
        '                 END,'
        '    updated_at = now()'
        ' WHERE term = ANY($3)',
        p_chunk_table || '_idf_stats')
    USING new_total, p_deleted_chunks_count, p_terms;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.bm25_decrement_idf_stats IS
'Decrement doc_freq in the _idf_stats table for a set of terms before their source chunks are deleted';

-- Trigger function for vectorization
CREATE FUNCTION pgedge_vectorizer.vectorization_trigger()
RETURNS TRIGGER AS $$
DECLARE
    content_col TEXT;
    chunk_table TEXT;
    strategy TEXT;
    chunk_sz INT;
    overlap INT;
    pk_col TEXT;
    pk_type TEXT;
    doc_content TEXT;
    chunks TEXT[];
    chunk_text TEXT;
    i INT;
    chunk_id BIGINT;
    source_id_val TEXT;
    deleted_chunks_count INT := 0;
BEGIN
    -- Extract trigger arguments
    content_col := TG_ARGV[0];
    chunk_table := TG_ARGV[1];
    strategy := TG_ARGV[2];
    chunk_sz := TG_ARGV[3]::INT;
    overlap := TG_ARGV[4]::INT;
    pk_col := COALESCE(TG_ARGV[5], 'id');
    pk_type := COALESCE(TG_ARGV[6], 'bigint');

    -- Get source document ID
    EXECUTE format('SELECT ($1).%I', pk_col) USING NEW INTO source_id_val;

    -- Get document content
    EXECUTE format('SELECT $1.%I', content_col) USING NEW INTO doc_content;

    -- Trim whitespace for empty check
    IF doc_content IS NOT NULL THEN
        doc_content := trim(doc_content);
    END IF;

    -- Skip if content unchanged (on UPDATE)
    IF TG_OP = 'UPDATE' THEN
        DECLARE
            old_content TEXT;
        BEGIN
            EXECUTE format('SELECT $1.%I', content_col) USING OLD INTO old_content;
            IF old_content IS NOT NULL THEN
                old_content := trim(old_content);
            END IF;
            IF doc_content = old_content OR (doc_content IS NULL AND old_content IS NULL) THEN
                RETURN NEW;
            END IF;
        END;
    END IF;

    -- On UPDATE, decrement IDF stats for the old document's terms before
    -- deleting the old chunks.  This prevents doc_freq from drifting upward
    -- when the worker later re-increments stats for the new chunks.
    IF TG_OP = 'UPDATE' THEN
        DECLARE
            old_terms TEXT[];
            old_content_for_idf TEXT;
        BEGIN
            EXECUTE format('SELECT $1.%I', content_col) USING OLD INTO old_content_for_idf;
            IF old_content_for_idf IS NOT NULL THEN
                old_content_for_idf := trim(old_content_for_idf);
            END IF;
            IF old_content_for_idf IS NOT NULL AND old_content_for_idf <> '' THEN
                old_terms := pgedge_vectorizer.bm25_tokenize(old_content_for_idf);
                EXECUTE format(
                    'SELECT count(*)::int FROM %I WHERE source_id = $1::%s',
                    chunk_table, pk_type
                )
                INTO deleted_chunks_count
                USING source_id_val;

                PERFORM pgedge_vectorizer.bm25_decrement_idf_stats(
                    chunk_table, old_terms, deleted_chunks_count);
            END IF;
        END;
    END IF;

    -- Delete queue entries for this document's chunks before deleting the chunks.
    -- Prevents orphaned queue entries that waste embedding API calls on deleted chunks.
    -- Only targets 'pending'/'failed'; 'processing' items are left for the
    -- worker to handle gracefully via its SPI_processed == 0 check.
    EXECUTE format(
        'DELETE FROM pgedge_vectorizer.queue
         WHERE chunk_table = %L
           AND chunk_id IN (SELECT id FROM %I WHERE source_id = $1::%s)
           AND status IN (''pending'', ''failed'')',
        chunk_table, chunk_table, pk_type)
        USING source_id_val;

    -- Delete existing chunks for this document
    -- pk_type uses %s: value from format_type() is system-controlled (see enable_vectorization)
    EXECUTE format('DELETE FROM %I WHERE source_id = $1::%s', chunk_table, pk_type)
        USING source_id_val;

    -- Skip if content is NULL or empty (after deleting old chunks)
    IF doc_content IS NULL OR doc_content = '' THEN
        RETURN NEW;
    END IF;

    -- Chunk the document
    chunks := pgedge_vectorizer.chunk_text(doc_content, strategy, chunk_sz, overlap);

    -- Insert chunks and queue for embedding
    FOR i IN 1..array_length(chunks, 1) LOOP
        chunk_text := chunks[i];

        -- Insert chunk
        EXECUTE format('
            INSERT INTO %I (source_id, chunk_index, content, token_count)
            VALUES ($1::%s, $2, $3, $4)
            RETURNING id', chunk_table, pk_type)
        USING source_id_val, i, chunk_text,
              pgedge_vectorizer.count_tokens(chunk_text)  -- UTF-8 aware token approximation
        INTO chunk_id;

        -- Queue for embedding
        INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content)
        VALUES (chunk_id, chunk_table, chunk_text);
    END LOOP;

    -- Notify workers (they will pick up work via polling and SKIP LOCKED)
    PERFORM pg_notify('pgedge_vectorizer_queue', source_id_val::TEXT);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.vectorization_trigger IS
'Trigger function that chunks text and queues for vectorization';

---------------------------------------------------------------------------
-- Views for monitoring
---------------------------------------------------------------------------

-- Queue status summary
CREATE VIEW pgedge_vectorizer.queue_status AS
SELECT
    chunk_table,
    status,
    COUNT(*) as count,
    MIN(created_at) as oldest,
    MAX(created_at) as newest,
    AVG(EXTRACT(EPOCH FROM (COALESCE(processed_at, NOW()) - created_at))) as avg_processing_time_secs
FROM pgedge_vectorizer.queue
GROUP BY chunk_table, status
ORDER BY chunk_table, status;

COMMENT ON VIEW pgedge_vectorizer.queue_status IS
'Summary of queue items by table and status';

-- Failed items view
CREATE VIEW pgedge_vectorizer.failed_items AS
SELECT
    id,
    chunk_table,
    chunk_id,
    attempts,
    max_attempts,
    error_message,
    created_at,
    next_retry_at,
    LEFT(content, 100) as content_preview
FROM pgedge_vectorizer.queue
WHERE status = 'failed'
ORDER BY created_at DESC;

COMMENT ON VIEW pgedge_vectorizer.failed_items IS
'Failed queue items with error details';

-- Pending items count
CREATE VIEW pgedge_vectorizer.pending_count AS
SELECT
    COUNT(*) as pending_items,
    COUNT(DISTINCT chunk_table) as affected_tables
FROM pgedge_vectorizer.queue
WHERE status = 'pending';

COMMENT ON VIEW pgedge_vectorizer.pending_count IS
'Count of pending items waiting for processing';

---------------------------------------------------------------------------
-- Utility functions
---------------------------------------------------------------------------

-- Retry failed items
CREATE FUNCTION pgedge_vectorizer.retry_failed(
    max_age_hours INT DEFAULT 24
) RETURNS INT AS $$
DECLARE
    rows_affected INT;
BEGIN
    UPDATE pgedge_vectorizer.queue
    SET status = 'pending',
        attempts = 0,
        error_message = NULL,
        next_retry_at = NULL
    WHERE status = 'failed'
      AND attempts < max_attempts
      AND created_at > NOW() - (max_age_hours || ' hours')::INTERVAL;

    GET DIAGNOSTICS rows_affected = ROW_COUNT;
    RETURN rows_affected;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.retry_failed IS
'Reset failed items to pending for retry';

-- Clear completed items
CREATE FUNCTION pgedge_vectorizer.clear_completed(
    older_than_hours INT DEFAULT 24
) RETURNS INT AS $$
DECLARE
    rows_affected INT;
BEGIN
    DELETE FROM pgedge_vectorizer.queue
    WHERE status = 'completed'
      AND processed_at < NOW() - (older_than_hours || ' hours')::INTERVAL;

    GET DIAGNOSTICS rows_affected = ROW_COUNT;
    RETURN rows_affected;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.clear_completed IS
'Remove old completed items from the queue';

-- Reprocess chunks that don't have embeddings
CREATE FUNCTION pgedge_vectorizer.reprocess_chunks(
    chunk_table_name TEXT
) RETURNS INT AS $$
DECLARE
    rows_affected INT := 0;
    chunk_record RECORD;
    hybrid_enabled BOOLEAN;
BEGIN
    hybrid_enabled := COALESCE(
        current_setting('pgedge_vectorizer.enable_hybrid', true),
        'false'
    )::BOOLEAN;

    -- Queue chunks that need dense embeddings, and when hybrid is enabled,
    -- also queue chunks missing sparse embeddings.
    FOR chunk_record IN EXECUTE format(
        'SELECT id, content, (embedding IS NULL) AS needs_embedding, '
        '       (sparse_embedding IS NULL) AS needs_sparse '
        'FROM %I '
        'WHERE embedding IS NULL '
        '   OR (sparse_embedding IS NULL AND %L::boolean)',
        chunk_table_name,
        hybrid_enabled
    )
    LOOP
        -- Check if already queued
        PERFORM 1 FROM pgedge_vectorizer.queue
        WHERE chunk_id = chunk_record.id
          AND chunk_table = chunk_table_name
          AND status IN ('pending', 'processing');

        -- Only queue if not already queued
        IF NOT FOUND THEN
            INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content, metadata)
            VALUES (
                chunk_record.id,
                chunk_table_name,
                chunk_record.content,
                CASE
                    WHEN NOT chunk_record.needs_embedding AND chunk_record.needs_sparse
                        THEN jsonb_build_object('sparse_only', true)
                    ELSE NULL
                END
            );

            rows_affected := rows_affected + 1;
        END IF;
    END LOOP;

    RAISE NOTICE 'Queued % chunks from % for processing', rows_affected, chunk_table_name;
    RETURN rows_affected;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.reprocess_chunks IS
'Queue existing chunks without embeddings for processing';

-- Recreate all chunks from scratch
CREATE FUNCTION pgedge_vectorizer.recreate_chunks(
    source_table_name REGCLASS,
    source_column_name NAME
) RETURNS INT AS $$
DECLARE
    chunk_table_name TEXT;
    rows_affected INT := 0;
    trigger_name TEXT;
    trigger_exists BOOLEAN;
BEGIN
    -- Prefer authoritative mapping from vectorizers registry.
    SELECT v.chunk_table
    INTO chunk_table_name
    FROM pgedge_vectorizer.vectorizers v
    WHERE v.source_table = source_table_name::TEXT
      AND v.source_column = source_column_name;

    -- Fallback to legacy default naming if no registry row exists.
    IF chunk_table_name IS NULL THEN
        chunk_table_name := source_table_name::TEXT || '_' || source_column_name || '_chunks';
    END IF;

    -- Verify chunk table exists
    IF to_regclass(chunk_table_name) IS NULL THEN
        RAISE EXCEPTION 'Chunk table % does not exist. Use enable_vectorization() first.', chunk_table_name;
    END IF;

    -- Verify trigger exists
    trigger_name := source_table_name::TEXT || '_' || source_column_name || '_vectorization_trigger';
    SELECT EXISTS (
        SELECT 1 FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.oid = source_table_name
        AND t.tgname = trigger_name
    ) INTO trigger_exists;

    IF NOT trigger_exists THEN
        RAISE EXCEPTION 'Vectorization trigger % does not exist. Use enable_vectorization() first.', trigger_name;
    END IF;

    RAISE NOTICE 'Recreating chunks for %.% -> %', source_table_name, source_column_name, chunk_table_name;

    -- Delete all existing chunks and reset IDF stats.
    -- Truncating _idf_stats is safe here because recreate_chunks rebuilds
    -- all chunks from scratch; the worker will repopulate IDF stats as it
    -- processes the newly queued chunks.
    EXECUTE format('DELETE FROM %I', chunk_table_name);
    EXECUTE format('TRUNCATE TABLE %I', chunk_table_name || '_idf_stats');
    GET DIAGNOSTICS rows_affected = ROW_COUNT;
    RAISE NOTICE 'Deleted % existing chunks', rows_affected;

    -- Delete all queue items for this chunk table (with retry logic)
    BEGIN
        -- Try to delete with a lock timeout
        SET LOCAL lock_timeout = '5s';
        DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = chunk_table_name;
        RAISE NOTICE 'Cleared queue for %', chunk_table_name;
    EXCEPTION WHEN lock_not_available OR deadlock_detected THEN
        -- If we can't get the lock, just mark them for cleanup
        RAISE WARNING 'Could not clear queue due to concurrent access, continuing anyway';
    END;

    -- Manually process each row to bypass trigger's unchanged-content optimization
    DECLARE
        row_record RECORD;
        doc_content TEXT;
        chunks TEXT[];
        chunk_text TEXT;
        i INT;
        chunk_id BIGINT;
        rows_processed INT := 0;
        actual_strategy TEXT;
        actual_chunk_size INT;
        actual_chunk_overlap INT;
        pk_col TEXT;
        pk_type TEXT;
    BEGIN
        -- Get chunking configuration from trigger arguments
        -- In PostgreSQL 17+, tgargs is bytea and needs to be decoded
        DECLARE
            tgargs_array TEXT[];
        BEGIN
            SELECT string_to_array(encode(t.tgargs, 'escape'), E'\\000')
            INTO tgargs_array
            FROM pg_trigger t
            JOIN pg_class c ON t.tgrelid = c.oid
            WHERE c.oid = source_table_name
            AND t.tgname = trigger_name;

            -- Arguments: 1=content_col, 2=chunk_table, 3=strategy, 4=size, 5=overlap, 6=pk_col, 7=pk_type
            actual_strategy := tgargs_array[3];
            actual_chunk_size := tgargs_array[4]::INT;
            actual_chunk_overlap := tgargs_array[5]::INT;
            pk_col := COALESCE(tgargs_array[6], 'id');
            pk_type := COALESCE(tgargs_array[7], 'bigint');
        END;

        RAISE NOTICE 'Re-chunking with strategy=%, size=%, overlap=%',
            actual_strategy, actual_chunk_size, actual_chunk_overlap;

        FOR row_record IN EXECUTE format(
            'SELECT %I as pk_val, %I as content FROM %s WHERE %I IS NOT NULL AND %I != ''''',
            pk_col, source_column_name, source_table_name, source_column_name, source_column_name
        )
        LOOP
            doc_content := row_record.content;

            -- Chunk the document
            chunks := pgedge_vectorizer.chunk_text(doc_content, actual_strategy, actual_chunk_size, actual_chunk_overlap);

            -- Insert chunks and queue for embedding
            FOR i IN 1..array_length(chunks, 1) LOOP
                chunk_text := chunks[i];

                -- Insert chunk
                -- pk_type uses %s: value from format_type() is system-controlled (see enable_vectorization)
                EXECUTE format('
                    INSERT INTO %I (source_id, chunk_index, content, token_count)
                    VALUES ($1::%s, $2, $3, $4)
                    RETURNING id', chunk_table_name, pk_type)
                USING row_record.pk_val, i, chunk_text,
                      pgedge_vectorizer.tiktoken_count_tokens(chunk_text)  -- uses tiktoken when use_tiktoken=on
                INTO chunk_id;

                -- Queue for embedding
                INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content)
                VALUES (chunk_id, chunk_table_name, chunk_text);
            END LOOP;

            rows_processed := rows_processed + 1;
        END LOOP;

        RAISE NOTICE 'Processed % rows', rows_processed;
        RETURN rows_processed;
    END;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.recreate_chunks IS
'Delete all chunks and recreate from source table (complete rebuild)';

---------------------------------------------------------------------------
-- refresh_token_counts() — recompute stored token_count for existing chunks
---------------------------------------------------------------------------
CREATE FUNCTION pgedge_vectorizer.refresh_token_counts(
    p_chunk_table REGCLASS
) RETURNS BIGINT AS $$
DECLARE
    rows_updated BIGINT;
BEGIN
    EXECUTE format(
        'UPDATE %s SET token_count = pgedge_vectorizer.tiktoken_count_tokens(content)',
        p_chunk_table
    );
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE 'refresh_token_counts: updated % rows in %',
        rows_updated, p_chunk_table::TEXT;
    RETURN rows_updated;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.refresh_token_counts IS
'Recompute token_count for every row in the given chunk table using the current '
'tiktoken_count_tokens() setting. Useful after enabling use_tiktoken = on to '
'back-fill accurate counts without a full recreate_chunks() rebuild. The '
'vectorization_trigger() always uses count_tokens() for performance; call this '
'function to align pre-existing rows.';

-- Get configuration summary
CREATE FUNCTION pgedge_vectorizer.show_config()
RETURNS TABLE (
    setting TEXT,
    value TEXT
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        name::TEXT as setting,
        current_setting(name)::TEXT as value
    FROM pg_settings
    WHERE name LIKE 'pgedge_vectorizer.%'
    ORDER BY name;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.show_config IS
'Show all pgedge_vectorizer configuration settings';

---------------------------------------------------------------------------
-- Grants (for non-superuser usage - optional)
---------------------------------------------------------------------------

-- Grant usage on schema to public (optional - comment out if not desired)
-- GRANT USAGE ON SCHEMA pgedge_vectorizer TO PUBLIC;
-- GRANT SELECT ON ALL TABLES IN SCHEMA pgedge_vectorizer TO PUBLIC;
-- GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA pgedge_vectorizer TO PUBLIC;
-- hybrid.sql
-- Hybrid BM25 + dense vector search using Reciprocal Rank Fusion (RRF).
--
-- Requires: pgedge_vectorizer.enable_hybrid = true in postgresql.conf
-- and pgvector >= 0.7.0 for sparsevec support.

---------------------------------------------------------------------------
-- hybrid_search() — main user-facing function
---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgedge_vectorizer.hybrid_search(
    p_source_table   REGCLASS,
    p_query          TEXT,
    p_limit          INT     DEFAULT 10,
    p_alpha          FLOAT8  DEFAULT 0.7,
    p_rrf_k          INT     DEFAULT 60,
    p_source_column  NAME    DEFAULT NULL
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
    IF COALESCE(current_setting('pgedge_vectorizer.enable_hybrid', true), 'false')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION
            'Hybrid search is disabled. Set pgedge_vectorizer.enable_hybrid = true and allow workers to populate sparse_embedding.';
    END IF;

    -- Look up the chunk table from the vectorizers registry.
    -- When p_source_column is provided, use the exact mapping.
    -- When NULL, raise an exception if the table has more than one
    -- vectorized column to avoid silently returning results from the
    -- wrong chunk table.
    IF p_source_column IS NOT NULL THEN
        SELECT vz.chunk_table INTO v_chunk_table
        FROM pgedge_vectorizer.vectorizers vz
        WHERE vz.source_table = p_source_table::TEXT
          AND vz.source_column = p_source_column;
    ELSE
        SELECT vz.chunk_table INTO v_chunk_table
        FROM pgedge_vectorizer.vectorizers vz
        WHERE vz.source_table = p_source_table::TEXT
        LIMIT 1;

        IF v_chunk_table IS NOT NULL AND
           (SELECT count(*) FROM pgedge_vectorizer.vectorizers
            WHERE source_table = p_source_table::TEXT) > 1
        THEN
            RAISE EXCEPTION
                'Table % has multiple vectorized columns. '
                'Pass p_source_column to disambiguate.',
                p_source_table;
        END IF;
    END IF;

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
        WITH dense_candidates AS (
            SELECT
                id,
                source_id::text AS source_id,
                content AS chunk,
                embedding <=> %L::vector AS dist
            FROM %I
            WHERE embedding IS NOT NULL
            ORDER BY dist
            LIMIT %s * 3
        ),
        dense AS (
            SELECT
                id,
                source_id,
                chunk,
                ROW_NUMBER() OVER (ORDER BY dist) AS rnk
            FROM dense_candidates
        ),
        sparse_candidates AS (
            SELECT
                id,
                source_id::text AS source_id,
                content AS chunk,
                sparse_embedding <#> %L::sparsevec AS dist
            FROM %I
            WHERE sparse_embedding IS NOT NULL
            ORDER BY dist ASC
            LIMIT %s * 3
        ),
        sparse AS (
            SELECT
                id,
                source_id,
                chunk,
                ROW_NUMBER() OVER (ORDER BY dist ASC) AS rnk
            FROM sparse_candidates
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

---------------------------------------------------------------------------
-- hybrid_search_simple() — convenience wrapper
---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pgedge_vectorizer.hybrid_search_simple(
    p_source_table  REGCLASS,
    p_query         TEXT,
    p_limit         INT  DEFAULT 10,
    p_source_column NAME DEFAULT NULL
)
RETURNS TABLE (
    source_id  TEXT,
    chunk      TEXT,
    rrf_score  FLOAT8
)
LANGUAGE sql AS $$
    SELECT source_id, chunk, rrf_score
    FROM pgedge_vectorizer.hybrid_search(
             p_source_table, p_query, p_limit,
             p_source_column => p_source_column);
$$;

COMMENT ON FUNCTION pgedge_vectorizer.hybrid_search_simple IS
'Convenience wrapper for hybrid_search() returning only source_id, chunk, and rrf_score';

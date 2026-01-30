-- pgedge_vectorizer extension
-- Version 1.0
--
-- Asynchronous text chunking and vectorization for PostgreSQL

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION pgedge_vectorizer" to load this file. \quit

---------------------------------------------------------------------------
-- Create schema
---------------------------------------------------------------------------

CREATE SCHEMA IF NOT EXISTS pgedge_vectorizer;

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
LANGUAGE C STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.generate_embedding IS
'Generate an embedding vector from query text using the configured provider';

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
    embedding_dimension INT DEFAULT 1536,
    chunk_table_name TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
    chunk_table TEXT;
    trigger_name TEXT;
    actual_strategy TEXT;
    actual_chunk_size INT;
    actual_chunk_overlap INT;
BEGIN
    -- Use defaults from GUC if not provided
    actual_strategy := COALESCE(chunk_strategy,
        current_setting('pgedge_vectorizer.default_chunk_strategy'));
    actual_chunk_size := COALESCE(chunk_size,
        current_setting('pgedge_vectorizer.default_chunk_size')::INT);
    actual_chunk_overlap := COALESCE(chunk_overlap,
        current_setting('pgedge_vectorizer.default_chunk_overlap')::INT);

    -- Determine chunk table name
    chunk_table := COALESCE(chunk_table_name, source_table::TEXT || '_' || source_column || '_chunks');

    -- Create chunks table
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I (
            id BIGSERIAL PRIMARY KEY,
            source_id BIGINT NOT NULL,
            chunk_index INT NOT NULL,
            content TEXT NOT NULL,
            token_count INT,
            embedding vector(%s),
            created_at TIMESTAMPTZ DEFAULT NOW(),
            updated_at TIMESTAMPTZ DEFAULT NOW(),
            UNIQUE(source_id, chunk_index)
        )', chunk_table, embedding_dimension);

    -- Create vector index for similarity search
    EXECUTE format('
        CREATE INDEX IF NOT EXISTS %I ON %I
        USING hnsw (embedding vector_cosine_ops)',
        chunk_table || '_embedding_idx', chunk_table);

    -- Create index on source_id for joins
    EXECUTE format('
        CREATE INDEX IF NOT EXISTS %I ON %I (source_id)',
        chunk_table || '_source_id_idx', chunk_table);

    -- Create trigger to chunk and queue on insert/update
    trigger_name := source_table::TEXT || '_' || source_column || '_vectorization_trigger';

    EXECUTE format('
        CREATE OR REPLACE TRIGGER %I
        AFTER INSERT OR UPDATE ON %s
        FOR EACH ROW
        EXECUTE FUNCTION pgedge_vectorizer.vectorization_trigger(%L, %L, %L, %L, %L)',
        trigger_name, source_table,
        source_column, chunk_table, actual_strategy,
        actual_chunk_size, actual_chunk_overlap);

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
        rows_processed INT := 0;
    BEGIN
        RAISE NOTICE 'Processing existing rows...';

        FOR row_record IN EXECUTE format('SELECT id, %I as content FROM %s WHERE %I IS NOT NULL AND %I != ''''',
            source_column, source_table, source_column, source_column)
        LOOP
            doc_content := row_record.content;

            -- Chunk the document
            chunks := pgedge_vectorizer.chunk_text(doc_content, actual_strategy, actual_chunk_size, actual_chunk_overlap);

            -- Insert chunks and queue for embedding
            FOR i IN 1..array_length(chunks, 1) LOOP
                chunk_text := chunks[i];

                -- Insert or update chunk
                EXECUTE format('
                    INSERT INTO %I (source_id, chunk_index, content, token_count)
                    VALUES ($1, $2, $3, $4)
                    ON CONFLICT (source_id, chunk_index)
                    DO UPDATE SET content = EXCLUDED.content,
                                  token_count = EXCLUDED.token_count,
                                  embedding = NULL,
                                  updated_at = NOW()
                    RETURNING id', chunk_table)
                USING row_record.id, i, chunk_text,
                      length(chunk_text) / 4  -- Approximate token count
                INTO chunk_id;

                -- Queue for embedding
                INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content)
                VALUES (chunk_id, chunk_table, chunk_text);
            END LOOP;

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
BEGIN
    -- If column specified, drop that specific trigger
    IF source_column IS NOT NULL THEN
        trigger_name := source_table::TEXT || '_' || source_column || '_vectorization_trigger';
        chunk_table := source_table::TEXT || '_' || source_column || '_chunks';

        -- Drop trigger
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', trigger_name, source_table);

        -- Remove orphaned queue items for this chunk table
        DELETE FROM pgedge_vectorizer.queue q
        WHERE q.chunk_table = disable_vectorization.chunk_table
        AND q.status IN ('pending', 'processing');

        -- Optionally drop chunk table
        IF drop_chunk_table THEN
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

        -- Optionally drop all chunk tables
        IF drop_chunk_table THEN
            RAISE NOTICE 'Warning: Specify source_column to drop specific chunk table';
        END IF;
    END IF;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.disable_vectorization IS
'Disable automatic vectorization for a table';

-- Trigger function for vectorization
CREATE FUNCTION pgedge_vectorizer.vectorization_trigger()
RETURNS TRIGGER AS $$
DECLARE
    content_col TEXT;
    chunk_table TEXT;
    strategy TEXT;
    chunk_sz INT;
    overlap INT;
    doc_content TEXT;
    chunks TEXT[];
    chunk_text TEXT;
    i INT;
    chunk_id BIGINT;
    source_id_val BIGINT;
BEGIN
    -- Extract trigger arguments
    content_col := TG_ARGV[0];
    chunk_table := TG_ARGV[1];
    strategy := TG_ARGV[2];
    chunk_sz := TG_ARGV[3]::INT;
    overlap := TG_ARGV[4]::INT;

    -- Get source document ID (assumes 'id' column)
    EXECUTE format('SELECT $1.id') USING NEW INTO source_id_val;

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

    -- Delete existing chunks for this document
    EXECUTE format('DELETE FROM %I WHERE source_id = $1', chunk_table)
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
            VALUES ($1, $2, $3, $4)
            RETURNING id', chunk_table)
        USING source_id_val, i, chunk_text,
              length(chunk_text) / 4  -- Approximate token count
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
    chunk_id_val BIGINT;
BEGIN
    -- Queue all chunks from the specified table that don't have embeddings
    FOR chunk_record IN EXECUTE format(
        'SELECT id, content FROM %I WHERE embedding IS NULL',
        chunk_table_name
    )
    LOOP
        -- Check if already queued
        PERFORM 1 FROM pgedge_vectorizer.queue
        WHERE chunk_id = chunk_record.id
          AND chunk_table = chunk_table_name
          AND status IN ('pending', 'processing');

        -- Only queue if not already queued
        IF NOT FOUND THEN
            INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content)
            VALUES (chunk_record.id, chunk_table_name, chunk_record.content);

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
    -- Determine chunk table name
    chunk_table_name := source_table_name::TEXT || '_' || source_column_name || '_chunks';

    -- Verify chunk table exists
    IF NOT EXISTS (
        SELECT 1 FROM pg_tables
        WHERE schemaname = 'public'
        AND tablename = chunk_table_name
    ) THEN
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

    -- Delete all existing chunks
    EXECUTE format('DELETE FROM %I', chunk_table_name);
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

            -- Arguments are 0-indexed: 0=chunk_table, 1=source_column, 2=strategy, 3=size, 4=overlap
            actual_strategy := tgargs_array[3];
            actual_chunk_size := tgargs_array[4]::INT;
            actual_chunk_overlap := tgargs_array[5]::INT;
        END;

        RAISE NOTICE 'Re-chunking with strategy=%, size=%, overlap=%',
            actual_strategy, actual_chunk_size, actual_chunk_overlap;

        FOR row_record IN EXECUTE format(
            'SELECT id, %I as content FROM %s WHERE %I IS NOT NULL AND %I != ''''',
            source_column_name, source_table_name, source_column_name, source_column_name
        )
        LOOP
            doc_content := row_record.content;

            -- Chunk the document
            chunks := pgedge_vectorizer.chunk_text(doc_content, actual_strategy, actual_chunk_size, actual_chunk_overlap);

            -- Insert chunks and queue for embedding
            FOR i IN 1..array_length(chunks, 1) LOOP
                chunk_text := chunks[i];

                -- Insert chunk
                EXECUTE format('
                    INSERT INTO %I (source_id, chunk_index, content, token_count)
                    VALUES ($1, $2, $3, $4)
                    RETURNING id', chunk_table_name)
                USING row_record.id, i, chunk_text,
                      length(chunk_text) / 4  -- Approximate token count
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

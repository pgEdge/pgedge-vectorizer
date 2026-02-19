/*-------------------------------------------------------------------------
 *
 * pgedge_vectorizer--1.0-beta2--1.0-beta3.sql
 *      Upgrade script from 1.0-beta2 to 1.0-beta3
 *
 * Changes in this release:
 *   - Auto-detect embedding dimension from configured model
 *   - Support any single-column primary key type (UUID, TEXT, etc.)
 *   - Auto-detect PK column name and type from pg_index
 *   - Reject composite primary keys with clear error message
 *   - Support custom primary key column names via source_pk parameter
 *   - Upsert when re-enabling vectorization with existing chunk table
 *   - Only re-queue chunks whose content changed on re-enable
 *   - Clean up orphaned queue items when disabling vectorization
 *   - Fix ambiguous column reference in disable_vectorization
 *   - Mark generate_embedding() as IMMUTABLE for index usage
 *   - Worker-side dimension mismatch validation
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */

-- New function: detect embedding dimension from configured model
CREATE FUNCTION pgedge_vectorizer.detect_embedding_dimension()
RETURNS INT
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_detect_embedding_dimension'
LANGUAGE C STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.detect_embedding_dimension IS
'Detect the embedding dimension of the currently configured provider/model';

-- Mark generate_embedding as IMMUTABLE for HNSW index usage
DROP FUNCTION IF EXISTS pgedge_vectorizer.generate_embedding(text);
CREATE FUNCTION pgedge_vectorizer.generate_embedding(
    query_text TEXT
) RETURNS vector
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_generate_embedding'
LANGUAGE C IMMUTABLE STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.generate_embedding IS
'Generate an embedding vector from query text using the configured provider';

-- Drop old 7-parameter enable_vectorization before creating new 8-parameter version.
-- Without this DROP, PostgreSQL creates a second overload (ambiguous calls).
DROP FUNCTION IF EXISTS pgedge_vectorizer.enable_vectorization(
    regclass, name, text, integer, integer, integer, text
);

-- Replace enable_vectorization with new signature and logic
-- (adds source_pk parameter, auto-detect dimension and PK type, upsert on re-enable)
CREATE OR REPLACE FUNCTION pgedge_vectorizer.enable_vectorization(
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

    -- Determine chunk table name
    chunk_table := COALESCE(chunk_table_name, source_table::TEXT || '_' || source_column || '_chunks');

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
            created_at TIMESTAMPTZ DEFAULT NOW(),
            updated_at TIMESTAMPTZ DEFAULT NOW(),
            UNIQUE(source_id, chunk_index)
        )', chunk_table, pk_col_type, embedding_dimension);

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
                                  updated_at = NOW()
                    RETURNING id,
                              (embedding IS NULL) AS needs_embedding',
                    chunk_table, chunk_table, chunk_table)
                USING row_record.pk_val, i, chunk_text,
                      length(chunk_text) / 4  -- Approximate token count
                INTO chunk_id, needs_embedding;

                -- Only queue for embedding if new or content changed
                IF needs_embedding THEN
                    INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content)
                    VALUES (chunk_id, chunk_table, chunk_text);
                END IF;
            END LOOP;

            -- Remove queue entries for stale high-index chunks before deleting them
            -- pk_col_type uses %s: value from format_type() is system-controlled
            EXECUTE format(
                'DELETE FROM pgedge_vectorizer.queue
                 WHERE chunk_table = %L
                   AND chunk_id IN (
                       SELECT id FROM %I WHERE source_id = $1::%s AND chunk_index > $2
                   )
                   AND status IN (''pending'', ''failed'')',
                chunk_table, chunk_table, pk_col_type)
                USING row_record.pk_val, array_length(chunks, 1);

            -- Remove any stale chunks beyond the new chunk count
            -- pk_col_type uses %s: value from format_type() is system-controlled
            EXECUTE format('DELETE FROM %I WHERE source_id = $1::%s AND chunk_index > $2',
                chunk_table, pk_col_type)
                USING row_record.pk_val, array_length(chunks, 1);

            rows_processed := rows_processed + 1;
        END LOOP;

        RAISE NOTICE 'Processed % existing rows', rows_processed;
    END;
END;
$$ LANGUAGE plpgsql;

-- Replace disable_vectorization with queue cleanup fix
CREATE OR REPLACE FUNCTION pgedge_vectorizer.disable_vectorization(
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
        EXECUTE format('DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = %L AND status IN (''pending'', ''processing'')', chunk_table);

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

-- Replace vectorization_trigger with UUID-safe PK support
-- Uses TEXT intermediate variable and explicit casting for any PK type
CREATE OR REPLACE FUNCTION pgedge_vectorizer.vectorization_trigger()
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

    -- Delete queue entries for this document's chunks before deleting the chunks.
    -- Prevents orphaned queue entries that waste embedding API calls on deleted chunks.
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

-- Replace recreate_chunks with robust version
CREATE OR REPLACE FUNCTION pgedge_vectorizer.recreate_chunks(
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

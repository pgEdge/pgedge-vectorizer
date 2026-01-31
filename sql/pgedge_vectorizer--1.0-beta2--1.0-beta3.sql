/*-------------------------------------------------------------------------
 *
 * pgedge_vectorizer--1.0-beta2--1.0-beta3.sql
 *      Upgrade script from 1.0-beta2 to 1.0-beta3
 *
 * Changes in this release:
 *   - Auto-detect embedding dimension from configured model
 *   - Support custom primary key column names
 *   - Upsert when re-enabling vectorization with existing chunk table
 *   - Only re-queue chunks whose content changed on re-enable
 *   - Clean up orphaned queue items when disabling vectorization
 *   - Fix ambiguous column reference in disable_vectorization
 *   - Mark generate_embedding() as IMMUTABLE for index usage
 *   - Worker-side dimension mismatch validation
 *
 * Portions copyright (c) 2025 - 2026, pgEdge, Inc.
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

-- Replace enable_vectorization with new signature and logic
-- (adds source_pk parameter, auto-detect dimension, upsert on re-enable)
CREATE OR REPLACE FUNCTION pgedge_vectorizer.enable_vectorization(
    source_table REGCLASS,
    source_column NAME,
    chunk_strategy TEXT DEFAULT NULL,
    chunk_size INT DEFAULT NULL,
    chunk_overlap INT DEFAULT NULL,
    embedding_dimension INT DEFAULT NULL,
    chunk_table_name TEXT DEFAULT NULL,
    source_pk NAME DEFAULT 'id'
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

    -- Auto-detect embedding dimension from configured model if not specified
    IF embedding_dimension IS NULL THEN
        embedding_dimension := pgedge_vectorizer.detect_embedding_dimension();
        RAISE NOTICE 'Auto-detected embedding dimension: %', embedding_dimension;
    END IF;

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
        EXECUTE FUNCTION pgedge_vectorizer.vectorization_trigger(%L, %L, %L, %L, %L, %L)',
        trigger_name, source_table,
        source_column, chunk_table, actual_strategy,
        actual_chunk_size, actual_chunk_overlap, source_pk);

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

-- Replace vectorization_trigger with custom PK support
CREATE OR REPLACE FUNCTION pgedge_vectorizer.vectorization_trigger()
RETURNS TRIGGER AS $$
DECLARE
    content_col TEXT;
    chunk_tbl TEXT;
    strategy TEXT;
    chunk_sz INT;
    overlap INT;
    pk_col TEXT;
    doc_content TEXT;
    chunks TEXT[];
    chunk_text TEXT;
    source_id_val BIGINT;
    chunk_id BIGINT;
    i INT;
BEGIN
    content_col := TG_ARGV[0];
    chunk_tbl := TG_ARGV[1];
    strategy := TG_ARGV[2];
    chunk_sz := TG_ARGV[3]::INT;
    overlap := TG_ARGV[4]::INT;
    pk_col := COALESCE(TG_ARGV[5], 'id');

    -- Get source document ID
    EXECUTE format('SELECT ($1).%I', pk_col) USING NEW INTO source_id_val;

    -- Get document content
    EXECUTE format('SELECT $1.%I', content_col) USING NEW INTO doc_content;

    -- Handle NULL or empty content
    IF doc_content IS NULL OR trim(doc_content) = '' THEN
        -- Delete existing chunks for this source
        EXECUTE format('DELETE FROM %I WHERE source_id = $1', chunk_tbl) USING source_id_val;
        -- Clean up any pending queue items for deleted chunks
        EXECUTE format('
            DELETE FROM pgedge_vectorizer.queue
            WHERE chunk_table = %L
            AND chunk_id NOT IN (SELECT id FROM %I)',
            chunk_tbl, chunk_tbl);
        RETURN NEW;
    END IF;

    -- Chunk the document
    chunks := pgedge_vectorizer.chunk_text(doc_content, strategy, chunk_sz, overlap);

    IF chunks IS NULL OR array_length(chunks, 1) IS NULL THEN
        RETURN NEW;
    END IF;

    -- Delete old chunks for this source that exceed new chunk count
    EXECUTE format('DELETE FROM %I WHERE source_id = $1 AND chunk_index > $2', chunk_tbl)
    USING source_id_val, array_length(chunks, 1);

    -- Insert/update chunks
    FOR i IN 1..array_length(chunks, 1) LOOP
        chunk_text := chunks[i];

        -- Skip empty chunks
        IF chunk_text IS NOT NULL AND trim(chunk_text) != '' THEN
            -- Upsert chunk
            EXECUTE format('
                INSERT INTO %I (source_id, chunk_index, content, token_count)
                VALUES ($1, $2, $3, $4)
                ON CONFLICT (source_id, chunk_index)
                DO UPDATE SET
                    content = EXCLUDED.content,
                    token_count = EXCLUDED.token_count,
                    embedding = CASE
                        WHEN %I.content = EXCLUDED.content THEN %I.embedding
                        ELSE NULL
                    END,
                    updated_at = NOW()
                RETURNING id', chunk_tbl, chunk_tbl, chunk_tbl)
            USING source_id_val, i, chunk_text,
                  length(chunk_text) / 4  -- Approximate token count
            INTO chunk_id;

            -- Queue for embedding only if embedding was cleared (content changed or new)
            EXECUTE format('
                INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content)
                SELECT $1, $2, $3
                WHERE NOT EXISTS (
                    SELECT 1 FROM %I WHERE id = $1 AND embedding IS NOT NULL
                )', chunk_tbl)
            USING chunk_id, chunk_tbl, chunk_text;
        END IF;
    END LOOP;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Replace recreate_chunks with custom PK support
CREATE OR REPLACE FUNCTION pgedge_vectorizer.recreate_chunks(
    source_table_name REGCLASS,
    source_column_name NAME
) RETURNS INT AS $$
DECLARE
    chunk_table_name TEXT;
    trigger_name TEXT;
    row_record RECORD;
    doc_content TEXT;
    chunks TEXT[];
    chunk_text TEXT;
    chunk_id BIGINT;
    i INT;
    total_processed INT := 0;
    total_queued INT := 0;
    -- Variables for getting trigger args
    tgargs_array TEXT[];
    actual_strategy TEXT;
    actual_chunk_size INT;
    actual_chunk_overlap INT;
    pk_col TEXT;
BEGIN
    -- Determine chunk table and trigger names
    chunk_table_name := source_table_name::TEXT || '_' || source_column_name || '_chunks';
    trigger_name := source_table_name::TEXT || '_' || source_column_name || '_vectorization_trigger';

    -- Get chunking configuration from trigger arguments
    -- In PostgreSQL 17+, tgargs is bytea and needs to be decoded
    BEGIN
        SELECT string_to_array(
            encode(t.tgargs, 'escape'),
            '\000'
        ) INTO tgargs_array
        FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.oid = source_table_name
        AND t.tgname = trigger_name;

        -- Arguments: 1=content_col, 2=chunk_table, 3=strategy, 4=size, 5=overlap, 6=pk_col
        actual_strategy := tgargs_array[3];
        actual_chunk_size := tgargs_array[4]::INT;
        actual_chunk_overlap := tgargs_array[5]::INT;
        pk_col := COALESCE(tgargs_array[6], 'id');
    END;

    RAISE NOTICE 'Re-chunking with strategy=%, size=%, overlap=%',
        actual_strategy, actual_chunk_size, actual_chunk_overlap;

    FOR row_record IN EXECUTE format(
        'SELECT %I as pk_val, %I as content FROM %s WHERE %I IS NOT NULL AND %I != ''''',
        pk_col, source_column_name, source_table_name, source_column_name, source_column_name
    )
    LOOP
        doc_content := row_record.content;

        -- Delete existing chunks for this source
        EXECUTE format('DELETE FROM %I WHERE source_id = $1', chunk_table_name)
        USING row_record.pk_val;

        -- Chunk the document
        chunks := pgedge_vectorizer.chunk_text(doc_content, actual_strategy, actual_chunk_size, actual_chunk_overlap);

        IF chunks IS NOT NULL AND array_length(chunks, 1) IS NOT NULL THEN
            -- Insert new chunks and queue for embedding
            FOR i IN 1..array_length(chunks, 1) LOOP
                chunk_text := chunks[i];

                EXECUTE format('
                    INSERT INTO %I (source_id, chunk_index, content, token_count)
                    VALUES ($1, $2, $3, $4)
                    RETURNING id', chunk_table_name)
                USING row_record.pk_val, i, chunk_text,
                      length(chunk_text) / 4  -- Approximate token count
                INTO chunk_id;

                INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content)
                VALUES (chunk_id, chunk_table_name, chunk_text);
                total_queued := total_queued + 1;
            END LOOP;
        END IF;

        total_processed := total_processed + 1;
    END LOOP;

    -- Clean up any queue items referencing chunks that no longer exist
    DELETE FROM pgedge_vectorizer.queue
    WHERE chunk_table = chunk_table_name
    AND chunk_id NOT IN (SELECT id FROM pgedge_vectorizer.queue q
                         JOIN (SELECT id FROM unnest(ARRAY[]::bigint[]) AS id) x ON true);

    RAISE NOTICE 'Recreated chunks: % source rows processed, % chunks queued',
        total_processed, total_queued;

    RETURN total_processed;
END;
$$ LANGUAGE plpgsql;

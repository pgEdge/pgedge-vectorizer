-- pgedge_vectorizer extension
-- Version 1.2
--
-- Asynchronous text chunking and vectorization for PostgreSQL

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pgedge_vectorizer UPDATE TO '1.2'" to load this file. \quit

---------------------------------------------------------------------------
-- Approximate token counter, shared with the C chunking code
--
-- The chunking engine in C has always sized chunks with this estimate, but
-- the plpgsql paths that write the token_count column open-coded it as
-- length(chunk_text) / 4, which truncates where the C code rounds up. The two
-- therefore disagreed by a token on most chunks, and since token_count feeds
-- the BM25 document-length normalisation, hybrid search scored chunks written
-- by the trigger slightly differently from those written by the C chunker.
-- Exposing the C function and calling it from plpgsql leaves one definition
-- of the rule.
---------------------------------------------------------------------------

CREATE FUNCTION pgedge_vectorizer.count_tokens(
    content TEXT
) RETURNS INT
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_count_tokens'
LANGUAGE C STABLE STRICT;

COMMENT ON FUNCTION pgedge_vectorizer.count_tokens IS
'Approximate the token count of the given text (UTF-8 characters divided by '
'four, rounded up). This is the same estimate the chunking engine uses, and '
'is what gets stored in the token_count column of a chunk table';

---------------------------------------------------------------------------
-- Redefine the three functions that wrote token_count themselves, so that
-- they call count_tokens() instead. Existing rows keep whatever count they
-- were written with; the values are an approximation either way, and a
-- rewrite of every chunk table is not worth a one-token correction.
---------------------------------------------------------------------------

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

    -- Create BM25 IDF statistics table for this chunk table.
    -- Only doc_freq is stored; the IDF weight is computed on read.
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I (
            term        TEXT    PRIMARY KEY,
            doc_freq    INT     NOT NULL DEFAULT 1,
            updated_at  TIMESTAMPTZ DEFAULT now()
        )', chunk_table || '_idf_stats');

    -- Register in vectorizers table for hybrid_search() lookups.
    -- Use EXECUTE...USING to avoid PL/pgSQL variable/column ambiguity.
    EXECUTE
        'INSERT INTO pgedge_vectorizer.vectorizers
             (source_table, source_column, chunk_table, source_pk, pk_type)
         VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (source_table, source_column)
         DO UPDATE SET chunk_table = EXCLUDED.chunk_table,
                       source_pk   = EXCLUDED.source_pk,
                       pk_type     = EXCLUDED.pk_type'
    USING source_table::TEXT, source_column, chunk_table, source_pk, pk_col_type;

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

    -- Clean up derived data when source rows are deleted.  Statement-level with
    -- a transition table so that bulk deletes do not degenerate into per-row
    -- work.
    EXECUTE format('
        CREATE OR REPLACE TRIGGER %I
        AFTER DELETE ON %s
        REFERENCING OLD TABLE AS old_rows
        FOR EACH STATEMENT
        EXECUTE FUNCTION pgedge_vectorizer.vectorization_delete_trigger(%L, %L, %L, %L)',
        pgedge_vectorizer.cleanup_trigger_name(
            source_table::TEXT, source_column, '_vectorization_delete_trigger'),
        source_table,
        source_column, chunk_table, source_pk, pk_col_type);

    -- Clean up when the whole source table is truncated.
    EXECUTE format('
        CREATE OR REPLACE TRIGGER %I
        AFTER TRUNCATE ON %s
        FOR EACH STATEMENT
        EXECUTE FUNCTION pgedge_vectorizer.vectorization_truncate_trigger(%L)',
        pgedge_vectorizer.cleanup_trigger_name(
            source_table::TEXT, source_column, '_vectorization_truncate_trigger'),
        source_table, chunk_table);

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

        -- pk_val is cast to text here so that row_record.pk_val is always the
        -- same type across every call to this function within a session,
        -- regardless of the source table's actual primary key type. PL/pgSQL
        -- fixes the parameter type of a RECORD field the first time a dynamic
        -- EXECUTE ... USING statement evaluates it, and reusing that same
        -- statement later with a differently-typed record field fails with
        -- "type of parameter N does not match that when preparing the plan"
        -- (issue #39). Casting at the source, rather than at each USING site,
        -- is required: PostgreSQL still binds the RECORD field's own runtime
        -- type before any cast written into the later query text is applied.
        FOR row_record IN EXECUTE format('SELECT %I::text as pk_val, %I as content FROM %s WHERE %I IS NOT NULL AND %I != ''''',
            source_pk, source_column, source_table, source_column, source_column)
        LOOP
            doc_content := row_record.content;

            -- Chunk the document
            chunks := pgedge_vectorizer.chunk_text(doc_content, actual_strategy, actual_chunk_size, actual_chunk_overlap);

            -- Insert chunks and queue for embedding
            FOR i IN 1..array_length(chunks, 1) LOOP
                chunk_text := chunks[i];

                -- Insert or update chunk (only clear embedding if content changed).
                -- pk_col_type uses %s: value from format_type() is system-controlled
                -- (see the comment where the chunk table is created, above).
                -- $1::%s casts pk_val, now always text, back to the source
                -- table's actual primary key type.
                EXECUTE format('
                    INSERT INTO %I (source_id, chunk_index, content, token_count)
                    VALUES ($1::%s, $2, $3, $4)
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
                    chunk_table, pk_col_type, chunk_table, chunk_table, chunk_table, chunk_table)
                USING row_record.pk_val, i, chunk_text,
                      pgedge_vectorizer.count_tokens(chunk_text)
                INTO chunk_id, needs_embedding, needs_sparse;

                -- Queue if dense or sparse work is needed.
                IF needs_embedding OR needs_sparse THEN
                    INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content, metadata, max_attempts)
                    VALUES (
                        chunk_id,
                        chunk_table,
                        chunk_text,
                        CASE
                            WHEN NOT needs_embedding AND needs_sparse
                                THEN jsonb_build_object('sparse_only', true)
                            ELSE NULL
                        END,
                        current_setting('pgedge_vectorizer.max_retries')::INT
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
              pgedge_vectorizer.count_tokens(chunk_text)
        INTO chunk_id;

        -- Queue for embedding
        INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content, max_attempts)
        VALUES (chunk_id, chunk_table, chunk_text,
                current_setting('pgedge_vectorizer.max_retries')::INT);
    END LOOP;

    -- Notify workers (they will pick up work via polling and SKIP LOCKED)
    PERFORM pg_notify('pgedge_vectorizer_queue', source_id_val::TEXT);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.vectorization_trigger IS
'Trigger function that chunks text and queues for vectorization';

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

        -- pk_val is cast to text so that row_record.pk_val is always the same
        -- type across calls in a session, whatever the source table's actual
        -- primary key type. See the identical comment in enable_vectorization()
        -- for why: PL/pgSQL fixes a RECORD field's parameter type the first
        -- time a dynamic EXECUTE ... USING statement evaluates it, and this
        -- statement's own "$1::%s" cast below does not protect it, because
        -- that cast is applied after PostgreSQL has already bound the record
        -- field's raw runtime type (issue #39).
        FOR row_record IN EXECUTE format(
            'SELECT %I::text as pk_val, %I as content FROM %s WHERE %I IS NOT NULL AND %I != ''''',
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
                      pgedge_vectorizer.count_tokens(chunk_text)
                INTO chunk_id;

                -- Queue for embedding
                INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content, max_attempts)
                VALUES (chunk_id, chunk_table_name, chunk_text,
                        current_setting('pgedge_vectorizer.max_retries')::INT);
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
-- Provider and model may now be named per call
--
-- Adding defaulted parameters creates a new function rather than replacing
-- the old one, and the two would then be ambiguous for a caller passing only
-- the arguments they share, so the old forms are dropped first. Neither is
-- STRICT any more: NULL has to reach the C, where it means "fall back to the
-- GUC", and a STRICT function would return NULL before getting there.
---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS pgedge_vectorizer.generate_embedding(TEXT);
DROP FUNCTION IF EXISTS pgedge_vectorizer.detect_embedding_dimension();

CREATE FUNCTION pgedge_vectorizer.generate_embedding(
    query_text TEXT,
    provider   TEXT DEFAULT NULL,
    model      TEXT DEFAULT NULL
) RETURNS vector
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_generate_embedding'
LANGUAGE C STABLE;

COMMENT ON FUNCTION pgedge_vectorizer.generate_embedding IS
'Generate an embedding vector from query text. The provider and model '
'default to pgedge_vectorizer.provider and pgedge_vectorizer.model';

-- Embedding dimension detection function
CREATE FUNCTION pgedge_vectorizer.detect_embedding_dimension(
    provider TEXT DEFAULT NULL,
    model    TEXT DEFAULT NULL
) RETURNS INT
AS 'MODULE_PATHNAME', 'pgedge_vectorizer_detect_embedding_dimension'
LANGUAGE C;

COMMENT ON FUNCTION pgedge_vectorizer.detect_embedding_dimension IS
'Detect the embedding dimension of the given provider and model, defaulting '
'to pgedge_vectorizer.provider and pgedge_vectorizer.model';

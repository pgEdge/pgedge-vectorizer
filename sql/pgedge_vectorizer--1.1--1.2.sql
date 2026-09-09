-- pgedge_vectorizer extension
-- Version 1.2
--
-- Asynchronous text chunking and vectorization for PostgreSQL

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "ALTER EXTENSION pgedge_vectorizer UPDATE TO '1.2'" to load this file. \quit

---------------------------------------------------------------------------
-- Per-vectorizer provider and model
--
-- NULL in either column means "inherit the GUC at the time the work runs",
-- so an existing installation carries on behaving exactly as it did.
---------------------------------------------------------------------------

ALTER TABLE pgedge_vectorizer.vectorizers
    ADD COLUMN IF NOT EXISTS provider TEXT,
    ADD COLUMN IF NOT EXISTS model TEXT;

COMMENT ON COLUMN pgedge_vectorizer.vectorizers.provider IS
'Embedding provider for this vectorizer; NULL inherits pgedge_vectorizer.provider';
COMMENT ON COLUMN pgedge_vectorizer.vectorizers.model IS
'Embedding model for this vectorizer; NULL inherits pgedge_vectorizer.model';

---------------------------------------------------------------------------
-- Provenance columns on the chunk tables that already exist
--
-- enable_vectorization() adds these to a chunk table it finds without them,
-- but nothing re-runs it on upgrade, and the worker writes both columns in
-- the same statement as the embedding: an existing installation would fail
-- every embedding write until someone happened to re-enable the vectorizer.
-- So the upgrade alters what the registry knows about, here and now.
---------------------------------------------------------------------------

DO $$
DECLARE
    v         RECORD;
    chunk_oid OID;
BEGIN
    FOR v IN SELECT r.chunk_table FROM pgedge_vectorizer.vectorizers r LOOP
        -- One identifier with a dot in it for a schema-qualified source, not
        -- a qualified reference.
        chunk_oid := to_regclass(quote_ident(v.chunk_table));

        -- A chunk table dropped from under the registry is not this script's
        -- problem to fix, and must not stop the upgrade.
        CONTINUE WHEN chunk_oid IS NULL;

        EXECUTE format(
            'ALTER TABLE %s
                 ADD COLUMN IF NOT EXISTS embedding_provider TEXT,
                 ADD COLUMN IF NOT EXISTS embedding_model TEXT',
            chunk_oid::REGCLASS);
    END LOOP;
END;
$$;

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

---------------------------------------------------------------------------
-- enable_vectorization() gains provider and model
--
-- The two new parameters are defaulted, which means CREATE OR REPLACE would
-- define a second function rather than replace the eight-argument one,
-- leaving both in place: a call passing eight arguments could then reach the
-- old body, which knows nothing about the registry's new columns, and even
-- COMMENT ON FUNCTION becomes ambiguous. Drop the old signature first.
---------------------------------------------------------------------------

DROP FUNCTION IF EXISTS pgedge_vectorizer.enable_vectorization(
    REGCLASS, NAME, TEXT, INT, INT, INT, TEXT, NAME);

CREATE OR REPLACE FUNCTION pgedge_vectorizer.enable_vectorization(
    source_table REGCLASS,
    source_column NAME,
    chunk_strategy TEXT DEFAULT NULL,
    chunk_size INT DEFAULT NULL,
    chunk_overlap INT DEFAULT NULL,
    embedding_dimension INT DEFAULT NULL,
    chunk_table_name TEXT DEFAULT NULL,
    source_pk NAME DEFAULT NULL,
    provider TEXT DEFAULT NULL,
    model TEXT DEFAULT NULL
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
        -- Probe the model this vectorizer will actually use, which is not
        -- necessarily the one the GUCs name.
        embedding_dimension := pgedge_vectorizer.detect_embedding_dimension(
            enable_vectorization.provider, enable_vectorization.model);
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
            embedding_provider TEXT,
            embedding_model TEXT,
            created_at TIMESTAMPTZ DEFAULT NOW(),
            updated_at TIMESTAMPTZ DEFAULT NOW(),
            UNIQUE(source_id, chunk_index)
        )', chunk_table, pk_col_type, embedding_dimension);

    -- Add sparse and provenance columns to pre-existing chunk tables (upgrade
    -- path). These are no-ops for freshly created tables (columns exist
    -- already).
    EXECUTE format('
        ALTER TABLE %I
        ADD COLUMN IF NOT EXISTS sparse_embedding sparsevec(65536)',
        chunk_table);

    -- Guarded rather than ADD COLUMN IF NOT EXISTS, which would print two
    -- "already exists, skipping" notices on every call for a table that was
    -- just created with them, which is every call but an upgrade.
    IF NOT EXISTS (
        SELECT 1
          FROM pg_attribute a
         WHERE a.attrelid = to_regclass(quote_ident(chunk_table))
           AND a.attname = 'embedding_model'
           AND NOT a.attisdropped
    ) THEN
        EXECUTE format('
            ALTER TABLE %I
            ADD COLUMN embedding_provider TEXT,
            ADD COLUMN embedding_model TEXT',
            chunk_table);
    END IF;

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
             (source_table, source_column, chunk_table, source_pk, pk_type,
              provider, model)
         VALUES ($1, $2, $3, $4, $5, $6, $7)
         ON CONFLICT (source_table, source_column)
         DO UPDATE SET chunk_table = EXCLUDED.chunk_table,
                       source_pk   = EXCLUDED.source_pk,
                       pk_type     = EXCLUDED.pk_type,
                       provider    = EXCLUDED.provider,
                       model       = EXCLUDED.model'
    USING source_table::TEXT, source_column, chunk_table, source_pk, pk_col_type,
          enable_vectorization.provider, enable_vectorization.model;

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

---------------------------------------------------------------------------
-- disable_vectorization(): drop the chunk tables in a defined order
--
-- The array of chunk tables to drop was collected with no ORDER BY, so the
-- notices a multi-column disable emits came out in whatever order the scan
-- happened to return, which changed when the registry gained columns. Order
-- by the column name so that the same disable says the same thing twice.
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

        -- Drop triggers
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s', trigger_name, source_table);
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
                       pgedge_vectorizer.cleanup_trigger_name(
                           source_table::TEXT, source_column, '_vectorization_delete_trigger'),
                       source_table);
        EXECUTE format('DROP TRIGGER IF EXISTS %I ON %s',
                       pgedge_vectorizer.cleanup_trigger_name(
                           source_table::TEXT, source_column, '_vectorization_truncate_trigger'),
                       source_table);

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
        -- Find vectorization triggers by their trigger function rather than by
        -- name pattern.  Cleanup trigger names are shortened when the table and
        -- column are long, so a shortened name need not begin with the source
        -- table text and a LIKE pattern anchored on it would miss them,
        -- silently leaving cleanup triggers behind.
        FOR trigger_rec IN
            SELECT t.tgname
            FROM pg_trigger t
            WHERE t.tgrelid = source_table
              AND NOT t.tgisinternal
              AND t.tgfoid IN (
                  SELECT p.oid
                  FROM pg_proc p
                  JOIN pg_namespace n ON n.oid = p.pronamespace
                  WHERE n.nspname = 'pgedge_vectorizer'
                    AND p.proname IN ('vectorization_trigger',
                                      'vectorization_delete_trigger',
                                      'vectorization_truncate_trigger'))
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
                ORDER BY v.source_column
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

---------------------------------------------------------------------------
-- set_embedding_model(): change a vectorizer's provider and model
--
-- Both columns are written to exactly what was passed, NULL included, so
-- reverting a table to the global default is a call with a NULL model rather
-- than a separate function, and there is no hidden "leave it alone" state.
--
-- Changing the model on a populated vectorizer is refused unless the caller
-- asks for the re-embed, and the refusal keys on the model rather than on the
-- dimension. A dimension change is the loud failure and the worker already
-- catches it before writing anything. The quiet one is a change that keeps the
-- same width: text-embedding-3-small and text-embedding-ada-002 are both 1536,
-- so swapping them would leave the old vectors in place, correctly shaped and
-- meaningless beside the new ones, with nothing reporting a problem.
--
-- The re-embed leaves the chunks themselves alone. Chunking does not depend on
-- the embedding model, since count_tokens() ignores the model it is given, and
-- BM25 is lexical, so the chunk rows, their token counts and their sparse
-- embeddings are all still correct. Only the dense embeddings are wrong, which
-- is why this does not go near recreate_chunks().
---------------------------------------------------------------------------

CREATE FUNCTION pgedge_vectorizer.set_embedding_model(
    source_table        REGCLASS,
    source_column       NAME,
    model               TEXT,
    provider            TEXT DEFAULT NULL,
    embedding_dimension INT DEFAULT NULL,
    force_reembed       BOOLEAN DEFAULT FALSE
) RETURNS BIGINT AS $$
DECLARE
    v_row        RECORD;
    chunk_oid    OID;
    old_provider TEXT;
    old_model    TEXT;
    new_provider TEXT;
    new_model    TEXT;
    chunk_count  BIGINT;
    new_dim      INT;
    current_dim  INT;
    requeued     BIGINT := 0;
BEGIN
    SELECT r.* INTO v_row
      FROM pgedge_vectorizer.vectorizers r
     WHERE r.source_table = set_embedding_model.source_table::TEXT
       AND r.source_column = set_embedding_model.source_column;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no vectorizer registered for %.%',
            set_embedding_model.source_table::TEXT,
            set_embedding_model.source_column;
    END IF;

    -- Compare effective values, not stored ones: moving a table from an
    -- explicit 'openai' to NULL whilst the GUC also says 'openai' changes
    -- nothing, and must not cost a re-embed.
    old_provider := COALESCE(NULLIF(v_row.provider, ''),
                             current_setting('pgedge_vectorizer.provider'));
    old_model    := COALESCE(NULLIF(v_row.model, ''),
                             current_setting('pgedge_vectorizer.model'));
    new_provider := COALESCE(NULLIF(set_embedding_model.provider, ''),
                             current_setting('pgedge_vectorizer.provider'));
    new_model    := COALESCE(NULLIF(set_embedding_model.model, ''),
                             current_setting('pgedge_vectorizer.model'));

    IF old_provider = new_provider AND old_model = new_model THEN
        UPDATE pgedge_vectorizer.vectorizers r
           SET provider = set_embedding_model.provider,
               model    = set_embedding_model.model
         WHERE r.id = v_row.id;

        RAISE NOTICE 'Effective provider and model unchanged (%/%)',
            new_provider, new_model;
        RETURN 0;
    END IF;

    -- The chunk table's name is one identifier, dot included, so it is quoted
    -- rather than parsed as schema.relation.
    chunk_oid := to_regclass(quote_ident(v_row.chunk_table));
    IF chunk_oid IS NULL THEN
        RAISE EXCEPTION 'chunk table % for %.% no longer exists',
            v_row.chunk_table,
            set_embedding_model.source_table::TEXT,
            set_embedding_model.source_column;
    END IF;

    EXECUTE format('SELECT count(*) FROM %s', chunk_oid::REGCLASS)
       INTO chunk_count;

    IF chunk_count > 0 AND NOT force_reembed THEN
        RAISE EXCEPTION
            'changing the embedding model for %.% would leave % chunks '
            'embedded with %/% whilst everything after uses %/%',
            set_embedding_model.source_table::TEXT,
            set_embedding_model.source_column, chunk_count,
            old_provider, old_model, new_provider, new_model
        USING HINT = 'Pass force_reembed => true to clear every embedding '
                     'and requeue the chunks. Vectors from two models are '
                     'not comparable, so leaving the old ones in place '
                     'would quietly degrade search rather than fail.';
    END IF;

    /*
     * The column has to be rewidened whether or not there are chunks. An
     * empty vectorizer left at its old width would accept the change happily
     * and then fail every embedding the worker tried to write, which is the
     * failure this function exists to prevent.
     */
    -- The probe asks about the effective values rather than the raw
    -- arguments: an empty string means inherit everywhere else, and would
    -- otherwise reach the provider as a model name of ''.
    new_dim := COALESCE(
        set_embedding_model.embedding_dimension,
        pgedge_vectorizer.detect_embedding_dimension(new_provider, new_model));

    SELECT a.atttypmod INTO current_dim
      FROM pg_attribute a
     WHERE a.attrelid = chunk_oid
       AND a.attname = 'embedding';

    IF chunk_count > 0 THEN
        -- NULL first: a vector column cannot change width with values in it.
        -- A cleared embedding has no model, so its provenance goes with it.
        EXECUTE format('UPDATE %s SET embedding = NULL, '
                       'embedding_provider = NULL, embedding_model = NULL '
                       'WHERE embedding IS NOT NULL', chunk_oid::REGCLASS);

        -- Anything already queued was queued against the old model.
        DELETE FROM pgedge_vectorizer.queue q
              WHERE q.chunk_table = v_row.chunk_table;
    END IF;

    IF new_dim IS DISTINCT FROM current_dim THEN
        EXECUTE format('ALTER TABLE %s ALTER COLUMN embedding '
                       'TYPE vector(%s)', chunk_oid::REGCLASS, new_dim);
        RAISE NOTICE 'Embedding dimension changed from % to %',
            current_dim, new_dim;
    END IF;

    UPDATE pgedge_vectorizer.vectorizers r
       SET provider = set_embedding_model.provider,
           model    = set_embedding_model.model
     WHERE r.id = v_row.id;

    IF chunk_count > 0 THEN
        EXECUTE format(
            'INSERT INTO pgedge_vectorizer.queue '
            '    (chunk_id, chunk_table, content, max_attempts) '
            'SELECT id, %L, content, %s FROM %s',
            v_row.chunk_table,
            current_setting('pgedge_vectorizer.max_retries')::INT,
            chunk_oid::REGCLASS);

        GET DIAGNOSTICS requeued = ROW_COUNT;

        RAISE NOTICE 'Requeued % chunks for re-embedding with %/%',
            requeued, new_provider, new_model;
    END IF;

    RETURN requeued;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.set_embedding_model IS
'Set the embedding provider and model for one vectorizer, NULL meaning '
'inherit the GUC. Refuses to change a populated vectorizer unless '
'force_reembed is true, in which case every embedding is cleared and every '
'chunk requeued. Returns the number of chunks requeued';

---------------------------------------------------------------------------
-- embedding_model_status(): what each vectorizer's chunks were embedded with
--
-- A vectorizer with NULL provider and model inherits the GUCs, and inheritance
-- resolves when the work runs rather than being copied at creation. Changing
-- pgedge_vectorizer.model therefore re-points every inheriting vectorizer at
-- once, leaving a chunk table holding vectors from the old model beside new
-- ones from the new. Similarity between two models' vectors is noise, so
-- search degrades quietly; where the widths match, as they do between
-- text-embedding-3-small and text-embedding-ada-002, nothing catches it at all.
--
-- set_embedding_model() guards the per-vectorizer path and cannot guard this
-- one: the extension does not own that GUC and cannot intercept every way it
-- changes. So the chunk table records what produced each vector, and this
-- reports where that disagrees with what the vectorizer would use now. It
-- diagnoses rather than prevents, but it catches drift from any cause,
-- including a setting changed months ago by someone since departed.
--
-- Each row costs a scan of one chunk table, so the arguments narrow it.
---------------------------------------------------------------------------

CREATE FUNCTION pgedge_vectorizer.embedding_model_status(
    p_source_table  REGCLASS DEFAULT NULL,
    p_source_column NAME DEFAULT NULL
) RETURNS TABLE (
    source_table         TEXT,
    source_column        NAME,
    chunk_table          TEXT,
    effective_provider   TEXT,
    effective_model      TEXT,
    chunks_embedded      BIGINT,
    chunks_current       BIGINT,
    chunks_other_model   BIGINT,
    chunks_model_unknown BIGINT,
    embedded_models      TEXT[]
) AS $$
DECLARE
    v         RECORD;
    chunk_oid OID;
BEGIN
    FOR v IN
        SELECT r.source_table, r.source_column, r.chunk_table,
               COALESCE(NULLIF(r.provider, ''),
                        current_setting('pgedge_vectorizer.provider'))
                   AS eff_provider,
               COALESCE(NULLIF(r.model, ''),
                        current_setting('pgedge_vectorizer.model'))
                   AS eff_model
          FROM pgedge_vectorizer.vectorizers r
         WHERE (p_source_table IS NULL
                OR to_regclass(r.source_table) = p_source_table)
           AND (p_source_column IS NULL OR r.source_column = p_source_column)
         ORDER BY r.source_table, r.source_column
    LOOP
        source_table       := v.source_table;
        source_column      := v.source_column;
        chunk_table        := v.chunk_table;
        effective_provider := v.eff_provider;
        effective_model    := v.eff_model;

        chunks_embedded      := NULL;
        chunks_current       := NULL;
        chunks_other_model   := NULL;
        chunks_model_unknown := NULL;
        embedded_models      := NULL;

        /*
         * A chunk table that has been dropped, or that the caller cannot
         * read, leaves this row's counts NULL rather than failing the whole
         * result set. The name is one identifier with a dot in it for a
         * schema-qualified source, so it is quoted rather than parsed.
         */
        chunk_oid := to_regclass(quote_ident(v.chunk_table));
        IF chunk_oid IS NOT NULL
           AND has_table_privilege(chunk_oid, 'SELECT') THEN
            /*
             * Every count is over embedded rows only: a chunk with no vector
             * has no model to disagree about, and counting it as drifted
             * would confuse work still to do with work done wrongly.
             *
             * A row with no recorded model is reported apart from a mismatch
             * rather than lumped in with it. It predates these columns, so it
             * may well be current; the report says what is there, and leaves
             * the pessimistic reading to reembed(), which has to act.
             */
            EXECUTE format(
                'SELECT count(*) FILTER (WHERE embedding IS NOT NULL),
                        count(*) FILTER (WHERE embedding IS NOT NULL
                                           AND embedding_provider = %L
                                           AND embedding_model = %L),
                        count(*) FILTER (WHERE embedding IS NOT NULL
                                           AND embedding_model IS NOT NULL
                                           AND (embedding_provider
                                                    IS DISTINCT FROM %L
                                                OR embedding_model
                                                    IS DISTINCT FROM %L)),
                        count(*) FILTER (WHERE embedding IS NOT NULL
                                           AND embedding_model IS NULL),
                        (SELECT array_agg(pair ORDER BY pair)
                           FROM (SELECT DISTINCT
                                        embedding_provider || ''/'' ||
                                        embedding_model AS pair
                                   FROM %s
                                  WHERE embedding IS NOT NULL
                                    AND embedding_model IS NOT NULL) d)
                   FROM %s',
                v.eff_provider, v.eff_model, v.eff_provider, v.eff_model,
                chunk_oid::REGCLASS, chunk_oid::REGCLASS)
              INTO chunks_embedded, chunks_current, chunks_other_model,
                   chunks_model_unknown, embedded_models;
        END IF;

        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.embedding_model_status IS
'Report, per vectorizer, how many embedded chunks were produced by the '
'provider and model it would use now, how many by something else, and how '
'many predate the columns that record it. Scans the chunk tables';

---------------------------------------------------------------------------
-- reembed(): redo the embeddings that are not known to be current
--
-- The report above leaves a user with a number and nothing to do about it.
-- set_embedding_model(..., force_reembed => true) is not the answer, because
-- an inheriting vectorizer's effective model already is the new one, so that
-- function sees no change and takes its no-op branch.
--
-- No confirmation flag. Unlike set_embedding_model(), whose re-embed is a
-- surprising consequence of a settings change, this function does what its
-- name says; it raises a notice with the count, because the cost lands on a
-- metered provider.
---------------------------------------------------------------------------

CREATE FUNCTION pgedge_vectorizer.reembed(
    source_table        REGCLASS,
    source_column       NAME,
    embedding_dimension INT DEFAULT NULL
) RETURNS BIGINT AS $$
DECLARE
    v_row        RECORD;
    chunk_oid    OID;
    eff_provider TEXT;
    eff_model    TEXT;
    new_dim      INT;
    current_dim  INT;
    width_change BOOLEAN;
    requeued     BIGINT := 0;
BEGIN
    SELECT r.* INTO v_row
      FROM pgedge_vectorizer.vectorizers r
     WHERE r.source_table = reembed.source_table::TEXT
       AND r.source_column = reembed.source_column;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'no vectorizer registered for %.%',
            reembed.source_table::TEXT, reembed.source_column;
    END IF;

    eff_provider := COALESCE(NULLIF(v_row.provider, ''),
                             current_setting('pgedge_vectorizer.provider'));
    eff_model    := COALESCE(NULLIF(v_row.model, ''),
                             current_setting('pgedge_vectorizer.model'));

    chunk_oid := to_regclass(quote_ident(v_row.chunk_table));
    IF chunk_oid IS NULL THEN
        RAISE EXCEPTION 'chunk table % for %.% no longer exists',
            v_row.chunk_table,
            reembed.source_table::TEXT, reembed.source_column;
    END IF;

    new_dim := COALESCE(
        reembed.embedding_dimension,
        pgedge_vectorizer.detect_embedding_dimension(eff_provider, eff_model));

    SELECT a.atttypmod INTO current_dim
      FROM pg_attribute a
     WHERE a.attrelid = chunk_oid
       AND a.attname = 'embedding';

    width_change := new_dim IS DISTINCT FROM current_dim;

    IF width_change THEN
        /*
         * A column cannot hold two widths, so a change of width takes every
         * row with it whether or not it had drifted. Clearing has to come
         * first: a vector column cannot be altered with values in it.
         */
        EXECUTE format('UPDATE %s SET embedding = NULL, '
                       'embedding_provider = NULL, embedding_model = NULL '
                       'WHERE embedding IS NOT NULL', chunk_oid::REGCLASS);

        EXECUTE format('ALTER TABLE %s ALTER COLUMN embedding '
                       'TYPE vector(%s)', chunk_oid::REGCLASS, new_dim);

        RAISE NOTICE 'Embedding dimension changed from % to %, so every chunk '
                     'is being re-embedded', current_dim, new_dim;
    ELSE
        /*
         * Same width, so rows already produced by this provider and model are
         * left exactly as they are. Everything else goes, including rows with
         * nothing recorded: those predate the columns and cannot be shown to
         * be current, and the safe reading of a row that cannot be proved
         * current is that it needs doing again. On an installation freshly
         * upgraded to 1.2 that is every row, which the documentation says.
         */
        EXECUTE format(
            'UPDATE %s SET embedding = NULL, '
            '              embedding_provider = NULL, embedding_model = NULL '
            ' WHERE embedding IS NOT NULL '
            '   AND (embedding_model IS NULL '
            '        OR embedding_provider IS DISTINCT FROM %L '
            '        OR embedding_model IS DISTINCT FROM %L)',
            chunk_oid::REGCLASS, eff_provider, eff_model);
    END IF;

    -- Anything already queued was queued before this decision was made.
    DELETE FROM pgedge_vectorizer.queue q
          WHERE q.chunk_table = v_row.chunk_table;

    /*
     * Whatever now has no embedding needs one, which after the clearing above
     * is exactly the set chosen, plus any chunk that was never embedded in
     * the first place and would have been picked up by reprocess_chunks()
     * anyway.
     */
    EXECUTE format(
        'INSERT INTO pgedge_vectorizer.queue '
        '    (chunk_id, chunk_table, content, max_attempts) '
        'SELECT id, %L, content, %s FROM %s WHERE embedding IS NULL',
        v_row.chunk_table,
        current_setting('pgedge_vectorizer.max_retries')::INT,
        chunk_oid::REGCLASS);

    GET DIAGNOSTICS requeued = ROW_COUNT;

    RAISE NOTICE 'Queued % chunks to be embedded with %/%',
        requeued, eff_provider, eff_model;

    RETURN requeued;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION pgedge_vectorizer.reembed IS
'Re-embed a vectorizer''s chunks with the provider and model it would use now, '
'leaving alone any already produced by them. A change of embedding dimension '
'takes every chunk with it. Returns the number queued';

---------------------------------------------------------------------------
-- hybrid_search(): embed the query with the vectorizer's own model
--
-- The query vector was generated from the GUCs, which was right whilst that
-- was the only place a model could come from. Now that a vectorizer can pin
-- its own, a query embedded by one model would be compared against chunks
-- embedded by another: meaningless distances where the widths match, and an
-- outright error where they do not. Not redefined by the 1.1 script, so it is
-- replaced here in full.
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
    v_provider     TEXT;
    v_model        TEXT;
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
        SELECT vz.chunk_table, vz.provider, vz.model
          INTO v_chunk_table, v_provider, v_model
        FROM pgedge_vectorizer.vectorizers vz
        WHERE vz.source_table = p_source_table::TEXT
          AND vz.source_column = p_source_column;
    ELSE
        SELECT vz.chunk_table, vz.provider, vz.model
          INTO v_chunk_table, v_provider, v_model
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

    /*
     * Embed the query with this vectorizer's own provider and model rather
     * than the GUCs. A query embedded by one model and compared against chunks
     * embedded by another gives meaningless distances, and where the widths
     * differ it fails outright. NULL passes straight through and means
     * inherit, so a vectorizer that has pinned nothing behaves as before.
     */
    v_query_dense := pgedge_vectorizer.generate_embedding(p_query,
                                                          v_provider, v_model);

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

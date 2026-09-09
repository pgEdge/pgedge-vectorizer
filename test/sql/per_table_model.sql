-- per_table_model test
--
-- A vectorizer may name its own embedding provider and model, with NULL in
-- either registry column meaning "inherit the GUC". Nothing here reaches a
-- provider: every call that would otherwise probe for a dimension passes one
-- explicitly, and the one provider-resolution case below is rejected on the
-- name before any request is built.

---------------------------------------------------------------------------
-- Provider resolution happens by name, before any request
---------------------------------------------------------------------------

-- A provider that does not exist is rejected as such, rather than failing
-- later as a connection error.
DO $$
BEGIN
    PERFORM pgedge_vectorizer.detect_embedding_dimension('nosuchprovider');
    RAISE EXCEPTION 'expected an error, got none';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '%', SQLERRM;
END;
$$;

-- The same for the embedding function, which takes the provider second.
DO $$
BEGIN
    PERFORM pgedge_vectorizer.generate_embedding('some text', 'nosuchprovider');
    RAISE EXCEPTION 'expected an error, got none';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '%', SQLERRM;
END;
$$;

-- Both functions kept their original arity through defaults, so an existing
-- call still resolves. Only the signatures are asserted here; calling either
-- one for real needs a provider.
SELECT p.proname, pg_get_function_arguments(p.oid) AS args
  FROM pg_proc p
 WHERE p.pronamespace = 'pgedge_vectorizer'::regnamespace
   AND p.proname IN ('generate_embedding', 'detect_embedding_dimension')
 ORDER BY p.proname;

-- Neither may be STRICT: NULL has to reach the C, where it means "fall back
-- to the GUC", and a STRICT function would return NULL before getting there.
SELECT p.proname, p.proisstrict
  FROM pg_proc p
 WHERE p.pronamespace = 'pgedge_vectorizer'::regnamespace
   AND p.proname IN ('generate_embedding', 'detect_embedding_dimension')
 ORDER BY p.proname;

---------------------------------------------------------------------------
-- What enable_vectorization() records
---------------------------------------------------------------------------

CREATE TABLE ptm_inherits (id BIGSERIAL PRIMARY KEY, body TEXT);
INSERT INTO ptm_inherits (body) VALUES ('A document that inherits the GUCs.');

-- No override, so both columns stay NULL and the vectorizer inherits.
SELECT pgedge_vectorizer.enable_vectorization(
    'ptm_inherits'::regclass, 'body', 'token_based', 100, 10, 1536);

CREATE TABLE ptm_pinned (id BIGSERIAL PRIMARY KEY, body TEXT);
INSERT INTO ptm_pinned (body) VALUES ('A document with a pinned model.');

-- With an override, both are recorded exactly as passed.
SELECT pgedge_vectorizer.enable_vectorization(
    'ptm_pinned'::regclass, 'body', 'token_based', 100, 10, 1536,
    NULL, NULL, 'ollama', 'nomic-embed-text');

SELECT source_table, source_column, provider, model
  FROM pgedge_vectorizer.vectorizers
 WHERE source_table LIKE 'ptm_%'
 ORDER BY source_table;

-- Named notation reads the same on both functions, and skips the
-- positional parameters nobody wants to spell out.
CREATE TABLE ptm_named (id BIGSERIAL PRIMARY KEY, body TEXT);

SELECT pgedge_vectorizer.enable_vectorization(
    'ptm_named'::regclass, 'body',
    embedding_dimension => 1536,
    model => 'text-embedding-3-large');

SELECT provider, model
  FROM pgedge_vectorizer.vectorizers WHERE source_table = 'ptm_named';

---------------------------------------------------------------------------
-- set_embedding_model()
---------------------------------------------------------------------------

-- A table with no vectorizer is an error, not a silent no-op.
DO $$
BEGIN
    PERFORM pgedge_vectorizer.set_embedding_model(
        'ptm_named'::regclass, 'nosuchcolumn', 'some-model');
    RAISE EXCEPTION 'expected an error, got none';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '%', SQLERRM;
END;
$$;

SET pgedge_vectorizer.provider = 'openai';
SET pgedge_vectorizer.model = 'text-embedding-3-small';

-- ptm_named was pinned to text-embedding-3-large at creation, so this is a
-- real change. It goes through without complaint because the vectorizer has
-- no chunks yet: there is nothing embedded for it to invalidate.
SELECT pgedge_vectorizer.set_embedding_model(
    'ptm_named'::regclass, 'body', 'text-embedding-3-small',
    embedding_dimension => 1536) AS requeued;

SELECT provider, model
  FROM pgedge_vectorizer.vectorizers WHERE source_table = 'ptm_named';

-- An empty vectorizer still has its column rewidened. Skipping that because
-- there was nothing to re-embed would leave the table at its old width and
-- fail every embedding the worker later tried to write, which is exactly the
-- failure this function exists to prevent.
SELECT format_type(a.atttypid, a.atttypmod) AS before_width
  FROM pg_attribute a
 WHERE a.attrelid = 'ptm_named_body_chunks'::regclass
   AND a.attname = 'embedding';

SELECT pgedge_vectorizer.set_embedding_model(
    'ptm_named'::regclass, 'body', 'nomic-embed-text',
    provider => 'ollama', embedding_dimension => 768) AS requeued;

SELECT format_type(a.atttypid, a.atttypmod) AS after_width
  FROM pg_attribute a
 WHERE a.attrelid = 'ptm_named_body_chunks'::regclass
   AND a.attname = 'embedding';

-- Put it back, pinning both this time, so that the reset below starts from a
-- vectorizer that has actually overridden something and can be seen to give
-- both up. The provider named here matches the GUC, so the effective values
-- do not move and nothing is re-embedded.
SELECT pgedge_vectorizer.set_embedding_model(
    'ptm_named'::regclass, 'body', 'text-embedding-3-small',
    provider => 'openai', embedding_dimension => 1536) AS requeued;

SELECT provider, model
  FROM pgedge_vectorizer.vectorizers WHERE source_table = 'ptm_named';

-- Now the genuine no-op. Reverting to the GUC is a NULL model, and whilst the
-- GUC names what was pinned the effective model does not move, so nothing is
-- requeued even though the stored value changes.
SELECT pgedge_vectorizer.set_embedding_model(
    'ptm_named'::regclass, 'body', NULL) AS requeued;

SELECT provider, model
  FROM pgedge_vectorizer.vectorizers WHERE source_table = 'ptm_named';

-- Populate a vectorizer and mark it embedded, as the worker would.
UPDATE ptm_inherits_body_chunks
   SET embedding = array_fill(0.1::real, ARRAY[1536])::vector,
       sparse_embedding = '{1:0.5}/65536'::sparsevec;

SELECT count(*) AS chunks,
       count(embedding) AS embedded,
       count(sparse_embedding) AS sparse,
       count(token_count) AS counted
  FROM ptm_inherits_body_chunks;

-- Now the refusal. The message names both settings and the number of chunks.
DO $$
BEGIN
    PERFORM pgedge_vectorizer.set_embedding_model(
        'ptm_inherits'::regclass, 'body', 'nomic-embed-text',
        provider => 'ollama', embedding_dimension => 768);
    RAISE EXCEPTION 'expected an error, got none';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '%', SQLERRM;
END;
$$;

-- Nothing was touched by the refusal.
SELECT count(embedding) AS still_embedded FROM ptm_inherits_body_chunks;
SELECT provider, model
  FROM pgedge_vectorizer.vectorizers WHERE source_table = 'ptm_inherits';

-- With force_reembed the change goes through: every embedding cleared, the
-- column rewidened, every chunk requeued, and the chunks themselves left
-- exactly as they were.
SELECT pgedge_vectorizer.set_embedding_model(
    'ptm_inherits'::regclass, 'body', 'nomic-embed-text',
    provider => 'ollama', embedding_dimension => 768,
    force_reembed => true) AS requeued;

SELECT count(*) AS chunks,
       count(embedding) AS embedded,
       count(sparse_embedding) AS sparse_kept,
       count(token_count) AS token_counts_kept
  FROM ptm_inherits_body_chunks;

SELECT format_type(a.atttypid, a.atttypmod) AS embedding_type
  FROM pg_attribute a
 WHERE a.attrelid = 'ptm_inherits_body_chunks'::regclass
   AND a.attname = 'embedding';

SELECT count(*) AS queued
  FROM pgedge_vectorizer.queue
 WHERE chunk_table = 'ptm_inherits_body_chunks' AND status = 'pending';

SELECT provider, model
  FROM pgedge_vectorizer.vectorizers WHERE source_table = 'ptm_inherits';

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------

SELECT pgedge_vectorizer.disable_vectorization('ptm_inherits'::regclass,
                                               'body', TRUE);
SELECT pgedge_vectorizer.disable_vectorization('ptm_pinned'::regclass,
                                               'body', TRUE);
SELECT pgedge_vectorizer.disable_vectorization('ptm_named'::regclass,
                                               'body', TRUE);
DROP TABLE ptm_inherits;
DROP TABLE ptm_pinned;
DROP TABLE ptm_named;
DELETE FROM pgedge_vectorizer.queue;
RESET pgedge_vectorizer.provider;
RESET pgedge_vectorizer.model;

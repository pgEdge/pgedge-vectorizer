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

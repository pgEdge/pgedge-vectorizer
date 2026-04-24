-- tiktoken.sql
-- Regression tests for tiktoken integration (accurate token counting).
-- All assertions are deterministic regardless of plpython3u availability.

---------------------------------------------------------------------------
-- Test 1: GUC pgedge_vectorizer.use_tiktoken is registered
---------------------------------------------------------------------------
SELECT name
FROM pg_settings
WHERE name = 'pgedge_vectorizer.use_tiktoken';

---------------------------------------------------------------------------
-- Test 2: count_tokens() C function is registered
---------------------------------------------------------------------------
SELECT proname
FROM pg_proc
WHERE proname = 'count_tokens'
  AND pronamespace = (
      SELECT oid FROM pg_namespace WHERE nspname = 'pgedge_vectorizer'
  );

---------------------------------------------------------------------------
-- Test 3: count_tokens() returns correct approximation values
---------------------------------------------------------------------------

-- 'hello world' = 11 chars, (11+3)/4 = 3
SELECT pgedge_vectorizer.count_tokens('hello world', NULL) AS tokens;

-- empty string returns 0
SELECT pgedge_vectorizer.count_tokens('', NULL) AS tokens;

-- 'test' = 4 chars, (4+3)/4 = 1
SELECT pgedge_vectorizer.count_tokens('test', NULL) AS tokens;

-- NULL input returns NULL
SELECT pgedge_vectorizer.count_tokens(NULL, NULL) IS NULL AS is_null;

---------------------------------------------------------------------------
-- Test 4: tiktoken_count_tokens() PL/pgSQL wrapper is registered
---------------------------------------------------------------------------
SELECT proname
FROM pg_proc
WHERE proname = 'tiktoken_count_tokens'
  AND pronamespace = (
      SELECT oid FROM pg_namespace WHERE nspname = 'pgedge_vectorizer'
  );

---------------------------------------------------------------------------
-- Test 5: tiktoken_count_tokens() with use_tiktoken=off uses approximation
---------------------------------------------------------------------------
SET pgedge_vectorizer.use_tiktoken = off;

-- (11+3)/4 = 3
SELECT pgedge_vectorizer.tiktoken_count_tokens('hello world', 'cl100k_base') AS tokens;

-- empty string returns 0
SELECT pgedge_vectorizer.tiktoken_count_tokens('', 'cl100k_base') AS tokens;

-- NULL input returns 0
SELECT pgedge_vectorizer.tiktoken_count_tokens(NULL, 'cl100k_base') AS tokens;

RESET pgedge_vectorizer.use_tiktoken;

---------------------------------------------------------------------------
-- Test 6: Integration - chunk table token_count is populated
---------------------------------------------------------------------------
CREATE TABLE tiktoken_test_docs (
    id      BIGSERIAL PRIMARY KEY,
    content TEXT
);

INSERT INTO tiktoken_test_docs (content)
VALUES ('This is a test document for token count verification.');

SELECT pgedge_vectorizer.enable_vectorization(
    'tiktoken_test_docs'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- token_count column exists and holds a positive integer
SELECT token_count > 0 AS token_count_positive
FROM tiktoken_test_docs_content_chunks
LIMIT 1;

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------
SELECT pgedge_vectorizer.disable_vectorization(
    'tiktoken_test_docs'::regclass, 'content', true
);
DROP TABLE tiktoken_test_docs;

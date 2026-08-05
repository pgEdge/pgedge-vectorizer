-- count_tokens.sql
-- Regression tests for count_tokens() and refresh_token_counts().

---------------------------------------------------------------------------
-- Test 1: count_tokens() is registered
---------------------------------------------------------------------------
SELECT proname
FROM pg_proc
WHERE proname = 'count_tokens'
  AND pronamespace = (
      SELECT oid FROM pg_namespace WHERE nspname = 'pgedge_vectorizer'
  );

---------------------------------------------------------------------------
-- Test 2: count_tokens() approximation values
---------------------------------------------------------------------------

-- 'hello world' = 11 chars, (11+3)/4 = 3
SELECT pgedge_vectorizer.count_tokens('hello world') AS tokens;

-- empty string returns 0
SELECT pgedge_vectorizer.count_tokens('') AS tokens;

-- 'test' = 4 chars, (4+3)/4 = 1
SELECT pgedge_vectorizer.count_tokens('test') AS tokens;

-- NULL returns NULL (STRICT function)
SELECT pgedge_vectorizer.count_tokens(NULL) IS NULL AS is_null;

-- '你好世界' = 4 UTF-8 characters, not 12 bytes; (4+3)/4 = 1
SELECT pgedge_vectorizer.count_tokens('你好世界') AS tokens;

---------------------------------------------------------------------------
-- Test 3: refresh_token_counts() is registered
---------------------------------------------------------------------------
SELECT proname
FROM pg_proc
WHERE proname = 'refresh_token_counts'
  AND pronamespace = (
      SELECT oid FROM pg_namespace WHERE nspname = 'pgedge_vectorizer'
  );

---------------------------------------------------------------------------
-- Test 4: refresh_token_counts() updates rows and returns the count
---------------------------------------------------------------------------
CREATE TABLE count_tokens_refresh_test (
    id      BIGSERIAL PRIMARY KEY,
    content TEXT
);

INSERT INTO count_tokens_refresh_test (content)
VALUES ('Refresh test document one.'),
       ('Refresh test document two.');

SELECT pgedge_vectorizer.enable_vectorization(
    'count_tokens_refresh_test'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- Force token_count to 0 to simulate stale values
UPDATE count_tokens_refresh_test_content_chunks SET token_count = 0;

SELECT COUNT(*) AS zeroed
FROM count_tokens_refresh_test_content_chunks
WHERE token_count = 0;

-- refresh_token_counts() should update all rows and return the exact count
SELECT pgedge_vectorizer.refresh_token_counts(
    'count_tokens_refresh_test_content_chunks'::regclass
) = (
    SELECT COUNT(*) FROM count_tokens_refresh_test_content_chunks
) AS refresh_returned_count;

-- All token_counts should now be positive
SELECT COALESCE(BOOL_AND(token_count > 0), false) AS all_refreshed
FROM count_tokens_refresh_test_content_chunks;

-- Cleanup
SELECT pgedge_vectorizer.disable_vectorization(
    'count_tokens_refresh_test'::regclass, 'content', true
);
DROP TABLE count_tokens_refresh_test;

---------------------------------------------------------------------------
-- Test 5: refresh_token_counts() works with a schema-qualified table
---------------------------------------------------------------------------
CREATE SCHEMA count_tokens_ns_test;

CREATE TABLE count_tokens_ns_test.ns_chunks (
    id          BIGSERIAL PRIMARY KEY,
    source_id   BIGINT    NOT NULL DEFAULT 1,
    content     TEXT      NOT NULL,
    token_count INT
);

INSERT INTO count_tokens_ns_test.ns_chunks (content)
VALUES ('Schema-qualified refresh test.'),
       ('Another row for schema test.');

UPDATE count_tokens_ns_test.ns_chunks SET token_count = 0;

SELECT COUNT(*) AS zeroed
FROM count_tokens_ns_test.ns_chunks
WHERE token_count = 0;

SELECT pgedge_vectorizer.refresh_token_counts(
    'count_tokens_ns_test.ns_chunks'::regclass
) = (
    SELECT COUNT(*) FROM count_tokens_ns_test.ns_chunks
) AS refresh_returned_count;

SELECT COALESCE(BOOL_AND(token_count > 0), false) AS all_refreshed
FROM count_tokens_ns_test.ns_chunks;

-- Cleanup
DROP TABLE count_tokens_ns_test.ns_chunks;
DROP SCHEMA count_tokens_ns_test;

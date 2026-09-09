-- count_tokens test
--
-- count_tokens() exposes the estimate the C chunking code has always used, so
-- that the plpgsql paths which write the token_count column can call it rather
-- than open-coding the same rule and rounding it the other way. The point of
-- the tests below is therefore as much the agreement between the two as the
-- values themselves.

---------------------------------------------------------------------------
-- The estimate itself: UTF-8 characters divided by four, rounded up
---------------------------------------------------------------------------

-- 11 characters, so 3 tokens.
SELECT pgedge_vectorizer.count_tokens('hello world') AS eleven_chars;

-- Exactly 4 characters is exactly 1 token; anything shorter still rounds up
-- to 1, which is the difference from the truncating arithmetic this replaces.
SELECT pgedge_vectorizer.count_tokens('test') AS four_chars,
       pgedge_vectorizer.count_tokens('abc')  AS three_chars,
       pgedge_vectorizer.count_tokens('a')    AS one_char;

-- Empty text is the one case that is genuinely zero.
SELECT pgedge_vectorizer.count_tokens('') AS empty;

-- STRICT, so NULL in, NULL out.
SELECT pgedge_vectorizer.count_tokens(NULL) IS NULL AS null_is_null;

-- Characters, not bytes: four Han characters are twelve bytes but one token.
SELECT pgedge_vectorizer.count_tokens('你好世界') AS four_han_chars,
       octet_length('你好世界') AS bytes;

-- Declared STABLE rather than IMMUTABLE: the estimate is defined in terms of
-- pgedge_vectorizer.model, which will matter once the counter is model-aware,
-- and an index or cached plan built on an IMMUTABLE promise would then be
-- wrong. Pin the volatility so that cannot be relaxed by accident.
SELECT provolatile
  FROM pg_proc
 WHERE proname = 'count_tokens'
   AND pronamespace = 'pgedge_vectorizer'::regnamespace;

---------------------------------------------------------------------------
-- Agreement with what the chunking paths store
---------------------------------------------------------------------------

CREATE TABLE count_tokens_docs (
    id      BIGSERIAL PRIMARY KEY,
    content TEXT
);

-- Chunks written by enable_vectorization() back-filling an existing table.
INSERT INTO count_tokens_docs (content)
VALUES ('abc'),
       ('Short document.'),
       (repeat('The quick brown fox jumps over the lazy dog. ', 20));

SELECT pgedge_vectorizer.enable_vectorization(
    'count_tokens_docs'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

SELECT count(*) AS mismatched_on_backfill
  FROM count_tokens_docs_content_chunks
 WHERE token_count IS DISTINCT FROM pgedge_vectorizer.count_tokens(content);

-- The three-character row is the regression: length('abc') / 4 stored 0, which
-- the BM25 scoring path then had to clamp back up to 1.
SELECT token_count AS short_row_token_count
  FROM count_tokens_docs_content_chunks c
  JOIN count_tokens_docs d ON d.id = c.source_id
 WHERE d.content = 'abc';

-- Chunks written by the insert trigger.
INSERT INTO count_tokens_docs (content)
VALUES ('xy'),
       ('A document added after vectorization was enabled.');

SELECT count(*) AS mismatched_on_insert
  FROM count_tokens_docs_content_chunks
 WHERE token_count IS DISTINCT FROM pgedge_vectorizer.count_tokens(content);

-- Chunks written by recreate_chunks().
SELECT pgedge_vectorizer.recreate_chunks('count_tokens_docs'::regclass, 'content');

SELECT count(*) AS mismatched_on_recreate
  FROM count_tokens_docs_content_chunks
 WHERE token_count IS DISTINCT FROM pgedge_vectorizer.count_tokens(content);

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------

SELECT pgedge_vectorizer.disable_vectorization('count_tokens_docs'::regclass,
                                               'content', TRUE);
DROP TABLE count_tokens_docs;
DELETE FROM pgedge_vectorizer.queue;

-- Cross-session primary-key-type test (issue #39)
--
-- enable_vectorization() and recreate_chunks() both loop over source rows with
-- FOR row_record IN EXECUTE ... LOOP, where row_record is declared RECORD and
-- its pk_val field is later used as a dynamic EXECUTE ... USING parameter.
-- PL/pgSQL fixes a RECORD field's parameter type the first time that callsite
-- is evaluated in a session, and reusing the same callsite with a different
-- underlying type raises "type of parameter N (T2) does not match that when
-- preparing the plan (T1)". This can only be exercised with two calls sharing
-- one session, which is why it lives in its own test file rather than being
-- split across several, unlike the non-default-key coverage added for #24.

-- A bigint primary key first, to seed the callsite's cached parameter type.
CREATE TABLE pk_docs_bigint (id BIGSERIAL PRIMARY KEY, body TEXT);
INSERT INTO pk_docs_bigint (body) VALUES (repeat('alpha beta gamma ', 20));
SELECT pgedge_vectorizer.enable_vectorization('pk_docs_bigint', 'body',
                                              embedding_dimension => 3);
SELECT count(*) > 0 AS bigint_pk_has_chunks FROM pk_docs_bigint_body_chunks;

-- A text primary key second, in the same session. This is what fails on
-- unmodified main: it aborts partway through "Processing existing rows...",
-- after the chunk table, indexes and trigger already exist.
CREATE TABLE pk_docs_text (doc_key TEXT PRIMARY KEY, body TEXT);
INSERT INTO pk_docs_text VALUES ('k1', repeat('delta epsilon zeta ', 20));
SELECT pgedge_vectorizer.enable_vectorization('pk_docs_text', 'body',
                                              source_pk => 'doc_key',
                                              embedding_dimension => 3);
SELECT count(*) > 0 AS text_pk_has_chunks FROM pk_docs_text_body_chunks;

-- recreate_chunks() has the identical bug through the same mechanism, and its
-- existing "$1::%s" cast at the INSERT does not protect it: the cache trips on
-- the raw type PostgreSQL binds for the parameter, before any cast in the SQL
-- text is applied. Exercise it back-to-back across the two PK types too.
SELECT pgedge_vectorizer.recreate_chunks('pk_docs_bigint', 'body');
SELECT count(*) > 0 AS bigint_pk_chunks_after_recreate FROM pk_docs_bigint_body_chunks;

SELECT pgedge_vectorizer.recreate_chunks('pk_docs_text', 'body');
SELECT count(*) > 0 AS text_pk_chunks_after_recreate FROM pk_docs_text_body_chunks;

-- The fix casts the RECORD field to text unconditionally, so it must not
-- depend on which order the types are seen in. Repeat with a fresh pair of
-- tables in the opposite order: text first this time, to seed the callsite's
-- cached parameter type with text instead of bigint, then bigint second.
CREATE TABLE pk_docs_text_first (doc_key TEXT PRIMARY KEY, body TEXT);
INSERT INTO pk_docs_text_first VALUES ('k1', repeat('eta theta iota ', 20));
SELECT pgedge_vectorizer.enable_vectorization('pk_docs_text_first', 'body',
                                              source_pk => 'doc_key',
                                              embedding_dimension => 3);
SELECT count(*) > 0 AS text_first_has_chunks FROM pk_docs_text_first_body_chunks;

CREATE TABLE pk_docs_bigint_second (id BIGSERIAL PRIMARY KEY, body TEXT);
INSERT INTO pk_docs_bigint_second (body) VALUES (repeat('kappa lambda mu ', 20));
SELECT pgedge_vectorizer.enable_vectorization('pk_docs_bigint_second', 'body',
                                              embedding_dimension => 3);
SELECT count(*) > 0 AS bigint_second_has_chunks FROM pk_docs_bigint_second_body_chunks;

SELECT pgedge_vectorizer.recreate_chunks('pk_docs_text_first', 'body');
SELECT count(*) > 0 AS text_first_chunks_after_recreate FROM pk_docs_text_first_body_chunks;

SELECT pgedge_vectorizer.recreate_chunks('pk_docs_bigint_second', 'body');
SELECT count(*) > 0 AS bigint_second_chunks_after_recreate FROM pk_docs_bigint_second_body_chunks;

-- Clean up
SELECT pgedge_vectorizer.disable_vectorization('pk_docs_bigint', 'body', true);
SELECT pgedge_vectorizer.disable_vectorization('pk_docs_text', 'body', true);
SELECT pgedge_vectorizer.disable_vectorization('pk_docs_text_first', 'body', true);
SELECT pgedge_vectorizer.disable_vectorization('pk_docs_bigint_second', 'body', true);
DROP TABLE pk_docs_bigint;
DROP TABLE pk_docs_text;
DROP TABLE pk_docs_text_first;
DROP TABLE pk_docs_bigint_second;

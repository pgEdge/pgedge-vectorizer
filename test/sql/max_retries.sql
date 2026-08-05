-- pgedge_vectorizer.max_retries wiring test (issue #26)
--
-- The GUC was declared and documented but never read anywhere: every queue
-- row got max_attempts from the column's hardcoded DEFAULT 3, regardless of
-- the configured value. Every INSERT INTO pgedge_vectorizer.queue site now
-- uses current_setting('pgedge_vectorizer.max_retries') explicitly.
--
-- max_retries is PGC_SIGHUP, so it is changed here with ALTER SYSTEM plus a
-- reload rather than a plain SET, and reset back to the default at the end
-- since ALTER SYSTEM is cluster-wide state that must not leak into later
-- test files. pg_reload_conf() only asks the postmaster to signal every
-- backend; a PGC_SIGHUP value only actually updates in an existing backend
-- at the next top-level-statement boundary in PostgresMain's command loop,
-- never mid-statement, so polling from inside a single PL/pgSQL block (even
-- with pg_sleep() between checks) can never observe the change no matter how
-- long it waits. \c forces psql to reconnect, and a brand new backend reads
-- the current authoritative configuration at startup with no such lag.

ALTER SYSTEM SET pgedge_vectorizer.max_retries = 7;
SELECT pg_reload_conf();
\c
SHOW pgedge_vectorizer.max_retries;

CREATE TABLE mr_docs (id BIGSERIAL PRIMARY KEY, body TEXT);
INSERT INTO mr_docs (body) VALUES (repeat('alpha beta gamma ', 20));

-- enable_vectorization()'s "processing existing rows" path
SELECT pgedge_vectorizer.enable_vectorization('mr_docs', 'body',
                                              embedding_dimension => 3);
SELECT DISTINCT max_attempts FROM pgedge_vectorizer.queue
 WHERE chunk_table = 'mr_docs_body_chunks';

-- vectorization_trigger()'s per-row INSERT/UPDATE path
INSERT INTO mr_docs (body) VALUES (repeat('delta epsilon zeta ', 20));
SELECT max_attempts FROM pgedge_vectorizer.queue
 WHERE chunk_table = 'mr_docs_body_chunks'
 ORDER BY id DESC LIMIT 1;

-- recreate_chunks()'s path
SELECT pgedge_vectorizer.recreate_chunks('mr_docs', 'body');
SELECT DISTINCT max_attempts FROM pgedge_vectorizer.queue
 WHERE chunk_table = 'mr_docs_body_chunks';

-- Clean up, and restore the cluster-wide GUC to its default so later test
-- files are unaffected.
SELECT pgedge_vectorizer.disable_vectorization('mr_docs', 'body', true);
DROP TABLE mr_docs;
ALTER SYSTEM RESET pgedge_vectorizer.max_retries;
SELECT pg_reload_conf();

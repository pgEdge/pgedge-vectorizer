-- DELETE and TRUNCATE cleanup test
--
-- Verifies that removing source rows removes their derived chunks, queue
-- entries and BM25 statistics, rather than leaving them orphaned (issue #24).
--
-- Uses embedding_dimension => 3 and asserts only on row counts and trigger
-- existence, never on embedding values, so no provider credentials are needed.

CREATE TABLE dt_docs (id BIGSERIAL PRIMARY KEY, body TEXT);
INSERT INTO dt_docs (body) VALUES
    (repeat('alpha beta gamma ', 20)),
    (repeat('delta epsilon zeta ', 20)),
    (repeat('eta theta iota ', 20));

SELECT pgedge_vectorizer.enable_vectorization('dt_docs', 'body',
                                              embedding_dimension => 3);

-- All three triggers should now exist
SELECT tgname FROM pg_trigger
 WHERE tgrelid = 'dt_docs'::regclass AND NOT tgisinternal
 ORDER BY tgname;

-- Deleting one row removes only that row's chunks
SELECT count(*) > 0 AS has_chunks_for_row1
  FROM dt_docs_body_chunks WHERE source_id = 1;

DELETE FROM dt_docs WHERE id = 1;

SELECT count(*) AS chunks_for_deleted_row
  FROM dt_docs_body_chunks WHERE source_id = 1;
SELECT count(*) > 0 AS other_rows_untouched
  FROM dt_docs_body_chunks WHERE source_id = 2;

-- No queue entry should reference a chunk that no longer exists
SELECT count(*) AS orphaned_queue_entries
  FROM pgedge_vectorizer.queue q
 WHERE q.chunk_table = 'dt_docs_body_chunks'
   AND NOT EXISTS (SELECT 1 FROM dt_docs_body_chunks c WHERE c.id = q.chunk_id);

-- Seed BM25 statistics the way the worker would, so that the assertions below
-- are actually exercised: the worker does not run during these tests, so
-- _idf_stats would otherwise be empty and they would be vacuous.  Row 2's body
-- supplies delta/epsilon/zeta and row 3's supplies eta/theta/iota.
INSERT INTO dt_docs_body_chunks_idf_stats (term, doc_freq)
VALUES ('delta', 1), ('epsilon', 1), ('zeta', 1),
       ('eta', 1), ('theta', 1), ('iota', 1);

-- A delete must touch only the terms of the document it removed.  Stamping
-- every row first makes a table-wide rewrite visible: the corpus resync this
-- replaced updated every row unconditionally, so terms belonging to documents
-- that were not deleted had their updated_at bumped along with the rest.
UPDATE dt_docs_body_chunks_idf_stats SET updated_at = 'epoch';

DELETE FROM dt_docs WHERE id = 2;

-- Terms belonging only to the surviving document must be untouched
SELECT count(*) AS untouched_terms
  FROM dt_docs_body_chunks_idf_stats
 WHERE term IN ('eta', 'theta', 'iota')
   AND updated_at = 'epoch';

-- while the deleted document's own terms must still have been decremented
SELECT count(*) AS touched_terms
  FROM dt_docs_body_chunks_idf_stats
 WHERE term IN ('delta', 'epsilon', 'zeta')
   AND updated_at <> 'epoch';

-- Bulk delete in a single statement, which is the case the statement-level
-- trigger exists to handle without degenerating into per-row work
DELETE FROM dt_docs;
SELECT count(*) AS chunks_after_bulk_delete FROM dt_docs_body_chunks;

-- TRUNCATE also cleans up
INSERT INTO dt_docs (body) VALUES (repeat('kappa lambda mu ', 20));
SELECT count(*) > 0 AS chunks_before_truncate FROM dt_docs_body_chunks;
TRUNCATE dt_docs;
SELECT count(*) AS chunks_after_truncate FROM dt_docs_body_chunks;
SELECT count(*) AS idf_after_truncate FROM dt_docs_body_chunks_idf_stats;
SELECT count(*) AS queue_after_truncate
  FROM pgedge_vectorizer.queue WHERE chunk_table = 'dt_docs_body_chunks';

-- refresh_triggers() restores triggers dropped by hand, and is idempotent
DROP TRIGGER dt_docs_body_vectorization_delete_trigger ON dt_docs;
DROP TRIGGER dt_docs_body_vectorization_truncate_trigger ON dt_docs;
SELECT count(*) AS triggers_after_manual_drop FROM pg_trigger
 WHERE tgrelid = 'dt_docs'::regclass AND NOT tgisinternal;
-- refresh_triggers() counts every registered vectorizer, including any left by
-- earlier test files, so assert only that it did something.
SELECT pgedge_vectorizer.refresh_triggers() >= 1 AS refreshed;
SELECT count(*) AS triggers_after_refresh FROM pg_trigger
 WHERE tgrelid = 'dt_docs'::regclass AND NOT tgisinternal;
SELECT pgedge_vectorizer.refresh_triggers() >= 1 AS refreshed_again;

-- disable_vectorization() must remove every trigger it created
SELECT pgedge_vectorizer.disable_vectorization('dt_docs', 'body', true);
SELECT count(*) AS triggers_after_disable FROM pg_trigger
 WHERE tgrelid = 'dt_docs'::regclass AND NOT tgisinternal;

-- Clean up
DROP TABLE dt_docs;

-- Long identifiers must not collide, and teardown must still find the triggers.
--
-- Cleanup trigger names are shortened to fit the 63-byte identifier limit, so a
-- digest of the table and column keeps them unique: without it, two columns on
-- a long-named table would shorten to the same name and the second
-- CREATE OR REPLACE TRIGGER would silently replace the first. A shortened name
-- also no longer begins with the source table text, so whole-table teardown
-- looks triggers up by trigger function rather than by name pattern.
CREATE TABLE dt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (id BIGSERIAL PRIMARY KEY, a TEXT, b TEXT);
INSERT INTO dt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (a, b)
VALUES (repeat('alpha beta ', 5), repeat('gamma delta ', 5));

SELECT pgedge_vectorizer.enable_vectorization('dt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'a',
                                              embedding_dimension => 3);
SELECT pgedge_vectorizer.enable_vectorization('dt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'b',
                                              embedding_dimension => 3);

-- Six triggers, all distinct: three per column with no collisions
SELECT count(*) AS long_name_trigger_count FROM pg_trigger
 WHERE tgrelid = 'dt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::regclass AND NOT tgisinternal;
SELECT count(DISTINCT tgname) AS long_name_distinct_names FROM pg_trigger
 WHERE tgrelid = 'dt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::regclass AND NOT tgisinternal;

-- Deleting must still clean up both columns' chunks
DELETE FROM dt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;
SELECT count(*) AS long_name_chunks_a FROM dt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_a_chunks;
SELECT count(*) AS long_name_chunks_b FROM dt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_b_chunks;

-- Whole-table teardown must remove all six despite the shortened names
SELECT pgedge_vectorizer.disable_vectorization('dt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
SELECT count(*) AS long_name_triggers_after_disable FROM pg_trigger
 WHERE tgrelid = 'dt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'::regclass AND NOT tgisinternal;

DROP TABLE dt_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa;

-- The 63 limit is bytes, not characters.  Budgeting in characters lets a
-- multibyte name overflow, and the server then truncates it -- cutting off the
-- digest, which is the collision the digest exists to prevent.  The ::name
-- casts apply that truncation, so these compare the names as actually stored.
--
-- Three-byte characters are what push the digest past the limit, so this
-- assumes a UTF-8 database.
SELECT octet_length(pgedge_vectorizer.cleanup_trigger_name(
           repeat('日', 40), repeat('本', 40),
           '_vectorization_delete_trigger')) <= 63 AS multibyte_name_fits,
       pgedge_vectorizer.cleanup_trigger_name(
           repeat('日', 40), repeat('本', 40), '_vectorization_delete_trigger')::name
       <> pgedge_vectorizer.cleanup_trigger_name(
           repeat('日', 40), repeat('本', 40), '_vectorization_truncate_trigger')::name
           AS delete_and_truncate_distinct,
       pgedge_vectorizer.cleanup_trigger_name(
           repeat('日', 40), 'a', '_vectorization_delete_trigger')::name
       <> pgedge_vectorizer.cleanup_trigger_name(
           repeat('日', 40), 'b', '_vectorization_delete_trigger')::name
           AS two_columns_distinct;

-- ASCII names must be unaffected by the byte-based budget.
SELECT pgedge_vectorizer.cleanup_trigger_name(
           'dt_docs', 'body', '_vectorization_delete_trigger')
           AS ascii_name_unchanged;

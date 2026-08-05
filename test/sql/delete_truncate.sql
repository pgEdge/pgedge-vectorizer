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
SELECT pgedge_vectorizer.refresh_triggers() AS refreshed;
SELECT count(*) AS triggers_after_refresh FROM pg_trigger
 WHERE tgrelid = 'dt_docs'::regclass AND NOT tgisinternal;
SELECT pgedge_vectorizer.refresh_triggers() AS refreshed_again;

-- disable_vectorization() must remove every trigger it created
SELECT pgedge_vectorizer.disable_vectorization('dt_docs', 'body', true);
SELECT count(*) AS triggers_after_disable FROM pg_trigger
 WHERE tgrelid = 'dt_docs'::regclass AND NOT tgisinternal;

-- Clean up
DROP TABLE dt_docs;

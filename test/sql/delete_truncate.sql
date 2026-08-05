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

-- Seed BM25 statistics the way the worker would, so that the corpus accounting
-- below is actually exercised: the worker does not run during these tests, so
-- _idf_stats would otherwise be empty and the assertion vacuous.
INSERT INTO dt_docs_body_chunks_idf_stats (term, doc_freq, total_docs, idf_weight)
VALUES ('delta', 1, 2, 0.9), ('eta', 1, 2, 0.9);

-- Bulk delete in a single statement, which is the case the statement-level
-- trigger exists to handle without degenerating into per-row work
DELETE FROM dt_docs;
SELECT count(*) AS chunks_after_bulk_delete FROM dt_docs_body_chunks;

-- The corpus total must agree with the surviving chunk count. Decrementing per
-- document while the chunks are all still present sets total_docs from the same
-- unchanged count every time, so without a final resync only the last
-- document's value would survive and it would disagree with doc_freq.
SELECT count(*) AS idf_rows_with_wrong_total
  FROM dt_docs_body_chunks_idf_stats
 WHERE total_docs <> (SELECT count(*) FROM dt_docs_body_chunks);

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

-- vectorizer_status test
--
-- The view reports how far the embeddings are behind the source. Nothing in a
-- regression run generates a real embedding, since that needs a provider, so
-- the chunk rows are marked embedded by hand below to walk coverage from none
-- through partial to complete. Timestamps and ages are deliberately not
-- selected: they are wall-clock values and would differ on every run.

CREATE TABLE vstatus_docs (
    id      BIGSERIAL PRIMARY KEY,
    body    TEXT
);

INSERT INTO vstatus_docs (body)
VALUES ('The first document, which is long enough to be worth embedding.'),
       ('The second document, on an unrelated subject entirely.'),
       ('The third.');

SELECT pgedge_vectorizer.enable_vectorization(
    'vstatus_docs'::regclass,
    'body',
    'token_based',
    100,
    10,
    1536
);

---------------------------------------------------------------------------
-- Nothing embedded yet: the whole chunk table is outstanding, and every
-- chunk is sitting in the queue
---------------------------------------------------------------------------

SELECT source_table, source_column, chunk_table,
       source_rows, source_rows_covered, source_coverage,
       chunks_total, chunks_embedded, chunk_coverage,
       queue_pending, queue_processing, queue_failed
  FROM pgedge_vectorizer.vectorizer_status;

-- An age is reported for the oldest pending item, and there is no processed
-- timestamp yet. The values themselves are wall-clock, so only their
-- presence is asserted.
SELECT oldest_pending_age IS NOT NULL AS has_pending_age,
       last_processed_at IS NULL      AS nothing_processed_yet
  FROM pgedge_vectorizer.vectorizer_status;

---------------------------------------------------------------------------
-- Two chunks embedded: partial coverage, and the queue drains to match
---------------------------------------------------------------------------

UPDATE vstatus_docs_body_chunks
   SET embedding = array_fill(0.1::real, ARRAY[1536])::vector
 WHERE source_id IN (SELECT id FROM vstatus_docs ORDER BY id LIMIT 2);

UPDATE pgedge_vectorizer.queue
   SET status = 'completed', processed_at = NOW()
 WHERE chunk_table = 'vstatus_docs_body_chunks'
   AND chunk_id IN (SELECT id FROM vstatus_docs_body_chunks
                     WHERE embedding IS NOT NULL);

SELECT source_rows, source_rows_covered, source_coverage,
       chunks_total, chunks_embedded, chunk_coverage,
       queue_pending, queue_failed
  FROM pgedge_vectorizer.vectorizer_status;

SELECT last_processed_at IS NOT NULL AS has_processed_timestamp
  FROM pgedge_vectorizer.vectorizer_status;

---------------------------------------------------------------------------
-- A failed item is counted apart from the pending backlog
---------------------------------------------------------------------------

UPDATE pgedge_vectorizer.queue
   SET status = 'failed', error_message = 'synthetic failure'
 WHERE chunk_table = 'vstatus_docs_body_chunks'
   AND status = 'pending';

SELECT queue_pending, queue_processing, queue_failed,
       oldest_pending_age IS NULL AS no_pending_age
  FROM pgedge_vectorizer.vectorizer_status;

---------------------------------------------------------------------------
-- Everything embedded: coverage reaches 1 on both measures
---------------------------------------------------------------------------

UPDATE vstatus_docs_body_chunks
   SET embedding = array_fill(0.1::real, ARRAY[1536])::vector
 WHERE embedding IS NULL;

SELECT source_coverage, chunk_coverage
  FROM pgedge_vectorizer.vectorizer_status;

---------------------------------------------------------------------------
-- Narrowing to one vectorizer
---------------------------------------------------------------------------

CREATE TABLE vstatus_other (
    id   BIGSERIAL PRIMARY KEY,
    body TEXT
);

INSERT INTO vstatus_other (body) VALUES ('An unrelated vectorized table.');

SELECT pgedge_vectorizer.enable_vectorization(
    'vstatus_other'::regclass,
    'body',
    'token_based',
    100,
    10,
    1536
);

-- The view covers both.
SELECT source_table, source_column FROM pgedge_vectorizer.vectorizer_status;

-- The function narrows to one source table, and to one column of it.
SELECT source_table, chunks_total
  FROM pgedge_vectorizer.vectorizer_status('vstatus_docs'::regclass);

SELECT source_table, chunks_total
  FROM pgedge_vectorizer.vectorizer_status('vstatus_docs'::regclass, 'body');

-- A column that is not vectorized returns nothing rather than erroring.
SELECT count(*) AS rows_for_unknown_column
  FROM pgedge_vectorizer.vectorizer_status('vstatus_docs'::regclass, 'title');

---------------------------------------------------------------------------
-- Coverage above 1 is left visible: it means the chunk table holds rows for
-- source rows that have gone, which is worth seeing rather than clamping
---------------------------------------------------------------------------

ALTER TABLE vstatus_docs DISABLE TRIGGER USER;
DELETE FROM vstatus_docs WHERE body = 'The third.';
ALTER TABLE vstatus_docs ENABLE TRIGGER USER;

SELECT source_rows, source_rows_covered, source_coverage > 1 AS over_covered
  FROM pgedge_vectorizer.vectorizer_status('vstatus_docs'::regclass);

---------------------------------------------------------------------------
-- A chunk table dropped from under the registry leaves the counts NULL
-- rather than failing the whole result set
---------------------------------------------------------------------------

DROP TABLE vstatus_docs_body_chunks;

SELECT source_table,
       chunks_total IS NULL     AS chunk_counts_null,
       source_rows IS NOT NULL  AS source_count_still_reported,
       queue_failed
  FROM pgedge_vectorizer.vectorizer_status('vstatus_docs'::regclass);

---------------------------------------------------------------------------
-- A schema-qualified source table
--
-- The chunk table's name is generated as source_table || column || '_chunks'
-- and created with %I, so here it is a single identifier with a dot in it,
-- 'vstatus_schema.qualified_body_chunks', rather than a relation in a schema.
-- Looking that up without quoting finds nothing, and the chunk counts come
-- back NULL whilst the queue counts still work.
---------------------------------------------------------------------------

CREATE SCHEMA vstatus_schema;

CREATE TABLE vstatus_schema.qualified (
    id   BIGSERIAL PRIMARY KEY,
    body TEXT
);

INSERT INTO vstatus_schema.qualified (body)
VALUES ('A document in a table that is not on the search path.');

SELECT pgedge_vectorizer.enable_vectorization(
    'vstatus_schema.qualified'::regclass,
    'body',
    'token_based',
    100,
    10,
    1536
);

SELECT chunk_table, source_rows, chunks_total, queue_pending
  FROM pgedge_vectorizer.vectorizer_status(
           'vstatus_schema.qualified'::regclass);

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------

SELECT pgedge_vectorizer.disable_vectorization('vstatus_docs'::regclass,
                                               'body', TRUE);
SELECT pgedge_vectorizer.disable_vectorization('vstatus_other'::regclass,
                                               'body', TRUE);
SELECT pgedge_vectorizer.disable_vectorization(
           'vstatus_schema.qualified'::regclass, 'body', TRUE);
DROP TABLE vstatus_docs;
DROP TABLE vstatus_other;
DROP SCHEMA vstatus_schema CASCADE;
DELETE FROM pgedge_vectorizer.queue;

-- Maintenance functions test
-- This test verifies reprocess_chunks() and recreate_chunks() functions

-- Create a test table
CREATE TABLE maint_test (
    id BIGSERIAL PRIMARY KEY,
    content TEXT
);

-- Insert test data
INSERT INTO maint_test (content)
VALUES ('Initial content for maintenance testing');

-- Enable vectorization
SELECT pgedge_vectorizer.enable_vectorization(
    'maint_test'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- Verify chunks were created
SELECT COUNT(*) > 0 AS initial_chunks FROM maint_test_content_chunks;

-- Clear embeddings to simulate unprocessed chunks
UPDATE maint_test_content_chunks SET embedding = NULL;

-- Test reprocess_chunks
SELECT pgedge_vectorizer.reprocess_chunks('maint_test_content_chunks') > 0 AS reprocess_queued;

-- Verify queue entries were created
SELECT COUNT(*) > 0 AS queue_entries
FROM pgedge_vectorizer.queue
WHERE chunk_table = 'maint_test_content_chunks'
  AND status = 'pending';

-- Clean queue for next test
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'maint_test_content_chunks';

-- Add more data
INSERT INTO maint_test (content)
VALUES ('Additional content for recreate testing');

-- Test recreate_chunks
SELECT pgedge_vectorizer.recreate_chunks('maint_test'::regclass, 'content') >= 2 AS recreate_count;

-- Verify chunks exist for both rows
SELECT COUNT(*) >= 2 AS chunks_after_recreate FROM maint_test_content_chunks;

-- Verify queue entries were created for all chunks
SELECT COUNT(*) >= 2 AS queue_after_recreate
FROM pgedge_vectorizer.queue
WHERE chunk_table = 'maint_test_content_chunks';

-- Clean up
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'maint_test_content_chunks';
SELECT pgedge_vectorizer.disable_vectorization('maint_test'::regclass, 'content', true);
DROP TABLE maint_test;

---------------------------------------------------------------------------
-- recreate_chunks() on a schema-qualified source table
--
-- The chunk table's name is generated as source_table || column || '_chunks'
-- and created with %I, so here it is the single identifier
-- 'maint_schema.qualified_body_chunks' rather than a relation in a schema.
-- Looking that up unquoted finds nothing and raises as though the table had
-- never been created.
---------------------------------------------------------------------------

CREATE SCHEMA maint_schema;

CREATE TABLE maint_schema.qualified (
    id   SERIAL PRIMARY KEY,
    body TEXT
);

SELECT pgedge_vectorizer.enable_vectorization(
    'maint_schema.qualified'::regclass, 'body', 'token_based', 100, 10, 1536);

INSERT INTO maint_schema.qualified (body)
VALUES ('A document in a table that is not on the search path.');

SELECT pgedge_vectorizer.recreate_chunks(
           'maint_schema.qualified'::regclass, 'body') > 0 AS qualified_recreated;

SELECT pgedge_vectorizer.disable_vectorization(
           'maint_schema.qualified'::regclass, 'body', true);
DROP SCHEMA maint_schema CASCADE;
DELETE FROM pgedge_vectorizer.queue
 WHERE chunk_table = 'maint_schema.qualified_body_chunks';

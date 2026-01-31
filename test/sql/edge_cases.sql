-- Edge cases test
-- This test verifies handling of edge cases

-- Create a test table
CREATE TABLE edge_test (
    id BIGSERIAL PRIMARY KEY,
    content TEXT
);

-- Enable vectorization
SELECT pgedge_vectorizer.enable_vectorization(
    'edge_test'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- Test 1: Empty string (should not create chunks)
INSERT INTO edge_test (content) VALUES ('');
SELECT COUNT(*) AS chunks_for_empty FROM edge_test_content_chunks WHERE source_id = 1;

-- Test 2: NULL value (should not create chunks)
INSERT INTO edge_test (content) VALUES (NULL);
SELECT COUNT(*) AS chunks_for_null FROM edge_test_content_chunks WHERE source_id = 2;

-- Test 3: Whitespace only (should not create chunks)
INSERT INTO edge_test (content) VALUES ('   ');
SELECT COUNT(*) AS chunks_for_whitespace FROM edge_test_content_chunks WHERE source_id = 3;

-- Test 4: Single word (should create 1 chunk)
INSERT INTO edge_test (content) VALUES ('Word');
SELECT COUNT(*) AS chunks_for_word FROM edge_test_content_chunks WHERE source_id = 4;

-- Test 5: Very long text (should create multiple chunks)
INSERT INTO edge_test (content)
VALUES (repeat('This is a test sentence that will be repeated to create a very long document. ', 100));
SELECT COUNT(*) > 1 AS multiple_chunks FROM edge_test_content_chunks WHERE source_id = 5;

-- Test 6: Update to empty (should delete chunks)
UPDATE edge_test SET content = '' WHERE id = 4;
SELECT COUNT(*) AS chunks_after_empty_update FROM edge_test_content_chunks WHERE source_id = 4;

-- Test 7: Update NULL to content (should create chunks)
UPDATE edge_test SET content = 'New content' WHERE id = 2;
SELECT COUNT(*) > 0 AS chunks_after_null_update FROM edge_test_content_chunks WHERE source_id = 2;

-- Clean up
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'edge_test_content_chunks';
SELECT pgedge_vectorizer.disable_vectorization('edge_test'::regclass, 'content', true);
DROP TABLE edge_test;

-- Test 8: Custom primary key column name
CREATE TABLE custom_pk_test (
    doc_id BIGSERIAL PRIMARY KEY,
    body TEXT
);

SELECT pgedge_vectorizer.enable_vectorization(
    'custom_pk_test'::regclass,
    'body',
    'token_based',
    100,
    10,
    1536,
    NULL,
    'doc_id'
);

-- Insert a document using the custom PK
INSERT INTO custom_pk_test (body)
VALUES ('This document uses a custom primary key column.');

-- Verify chunks were created with correct source_id
SELECT COUNT(*) > 0 AS chunks_created FROM custom_pk_test_body_chunks WHERE source_id = 1;

-- Verify queue entries exist
SELECT COUNT(*) > 0 AS queue_entries FROM pgedge_vectorizer.queue
WHERE chunk_table = 'custom_pk_test_body_chunks';

-- Update the document (should recreate chunks)
UPDATE custom_pk_test SET body = 'Updated body text.' WHERE doc_id = 1;

-- Clean up
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'custom_pk_test_body_chunks';
SELECT pgedge_vectorizer.disable_vectorization('custom_pk_test'::regclass, 'body', true);
DROP TABLE custom_pk_test;

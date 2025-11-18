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

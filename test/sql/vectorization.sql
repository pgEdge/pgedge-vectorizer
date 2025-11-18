-- Vectorization test
-- This test verifies enable/disable vectorization functionality

-- Create a test table
CREATE TABLE test_docs (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    content TEXT
);

-- Enable vectorization
SELECT pgedge_vectorizer.enable_vectorization(
    'test_docs'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- Verify chunk table was created
SELECT tablename FROM pg_tables
WHERE tablename = 'test_docs_content_chunks';

-- Verify trigger was created
SELECT tgname FROM pg_trigger
WHERE tgname LIKE '%test_docs%vectorization%';

-- Insert a test document
INSERT INTO test_docs (title, content)
VALUES ('Test Document', 'This is a test document with some content for testing the vectorization functionality.');

-- Verify chunks were created
SELECT COUNT(*) > 0 AS chunks_created FROM test_docs_content_chunks;

-- Verify queue entries were created
SELECT COUNT(*) > 0 AS queue_entries_created
FROM pgedge_vectorizer.queue
WHERE chunk_table = 'test_docs_content_chunks';

-- Test update (should recreate chunks)
UPDATE test_docs SET content = 'Updated content for the test document.' WHERE id = 1;

-- Disable vectorization
SELECT pgedge_vectorizer.disable_vectorization('test_docs'::regclass, 'content', false);

-- Verify trigger was dropped
SELECT COUNT(*) AS trigger_count FROM pg_trigger
WHERE tgname LIKE '%test_docs%vectorization%';

-- Clean up
DROP TABLE test_docs_content_chunks;
DROP TABLE test_docs;

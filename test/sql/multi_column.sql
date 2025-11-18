-- Multi-column vectorization test
-- This test verifies that multiple columns can be vectorized on the same table

-- Create a test table with multiple text columns
CREATE TABLE multi_test (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    description TEXT,
    body TEXT
);

-- Enable vectorization on first column
SELECT pgedge_vectorizer.enable_vectorization(
    'multi_test'::regclass,
    'title',
    'token_based',
    100,
    10,
    1536
);

-- Verify first chunk table was created
SELECT tablename FROM pg_tables
WHERE tablename = 'multi_test_title_chunks';

-- Verify first trigger was created
SELECT tgname FROM pg_trigger
WHERE tgname = 'multi_test_title_vectorization_trigger';

-- Enable vectorization on second column
SELECT pgedge_vectorizer.enable_vectorization(
    'multi_test'::regclass,
    'description',
    'token_based',
    200,
    20,
    1536
);

-- Verify second chunk table was created
SELECT tablename FROM pg_tables
WHERE tablename = 'multi_test_description_chunks';

-- Verify second trigger was created
SELECT tgname FROM pg_trigger
WHERE tgname = 'multi_test_description_vectorization_trigger';

-- Verify both triggers exist
SELECT COUNT(*) AS trigger_count FROM pg_trigger
WHERE tgname LIKE 'multi_test%vectorization%';

-- Insert test data
INSERT INTO multi_test (title, description, body)
VALUES ('Test Title', 'Test Description', 'Test Body');

-- Verify chunks were created for both columns
SELECT COUNT(*) > 0 AS title_chunks_exist FROM multi_test_title_chunks;
SELECT COUNT(*) > 0 AS description_chunks_exist FROM multi_test_description_chunks;

-- Disable one column
SELECT pgedge_vectorizer.disable_vectorization('multi_test'::regclass, 'title', true);

-- Verify only one trigger remains
SELECT COUNT(*) AS remaining_triggers FROM pg_trigger
WHERE tgname LIKE 'multi_test%vectorization%';

-- Clean up
SELECT pgedge_vectorizer.disable_vectorization('multi_test'::regclass, 'description', true);
DROP TABLE multi_test;

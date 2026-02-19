-- Stale embeddings test
-- Verifies that old queue entries and stale chunks are properly cleaned up
-- when source content is updated or vectorization is re-enabled.

---------------------------------------------------------------------------
-- Setup
---------------------------------------------------------------------------
CREATE TABLE stale_test (
    id BIGSERIAL PRIMARY KEY,
    content TEXT
);

SELECT pgedge_vectorizer.enable_vectorization(
    'stale_test'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

---------------------------------------------------------------------------
-- Test 1: UPDATE cleans up orphaned queue entries
---------------------------------------------------------------------------

-- Insert a document
INSERT INTO stale_test (content)
VALUES ('First version of this document content for testing.');

-- Verify initial chunks and queue entries exist
SELECT COUNT(*) AS initial_chunks FROM stale_test_content_chunks WHERE source_id = 1;

SELECT COUNT(*) > 0 AS initial_queue_entries
FROM pgedge_vectorizer.queue
WHERE chunk_table = 'stale_test_content_chunks'
  AND status = 'pending';

-- Save old chunk IDs before the UPDATE deletes them
CREATE TEMP TABLE old_chunk_ids AS
SELECT id FROM stale_test_content_chunks WHERE source_id = 1;

-- Update the document (should delete old chunks + their queue entries, insert new)
UPDATE stale_test SET content = 'Completely different second version of content.' WHERE id = 1;

-- Old queue entries should be gone (no orphans)
SELECT COUNT(*) AS orphaned_queue_entries
FROM pgedge_vectorizer.queue q
JOIN old_chunk_ids o ON q.chunk_id = o.id
WHERE q.chunk_table = 'stale_test_content_chunks'
  AND q.status IN ('pending', 'failed');

-- New queue entries should exist for the replacement chunks
SELECT COUNT(*) > 0 AS new_queue_entries
FROM pgedge_vectorizer.queue
WHERE chunk_table = 'stale_test_content_chunks'
  AND status = 'pending'
  AND chunk_id NOT IN (SELECT id FROM old_chunk_ids);

DROP TABLE old_chunk_ids;

---------------------------------------------------------------------------
-- Test 2: UPDATE to empty content cleans up queue entries
---------------------------------------------------------------------------

INSERT INTO stale_test (id, content) VALUES (2, 'Some content to be cleared out.');

SELECT COUNT(*) > 0 AS chunks_before_clear
FROM stale_test_content_chunks WHERE source_id = 2;

-- Save chunk IDs before the UPDATE deletes them
CREATE TEMP TABLE old_chunk_ids_2 AS
SELECT id FROM stale_test_content_chunks WHERE source_id = 2;

-- Update to empty (should delete chunks AND their queue entries)
UPDATE stale_test SET content = '' WHERE id = 2;

SELECT COUNT(*) AS chunks_after_clear
FROM stale_test_content_chunks WHERE source_id = 2;

-- Verify queue entries for old chunks were cleaned up
SELECT COUNT(*) AS queue_after_clear
FROM pgedge_vectorizer.queue q
JOIN old_chunk_ids_2 o ON q.chunk_id = o.id
WHERE q.chunk_table = 'stale_test_content_chunks'
  AND q.status IN ('pending', 'failed');

DROP TABLE old_chunk_ids_2;

---------------------------------------------------------------------------
-- Test 3: Re-enable vectorization cleans stale high-index chunks
---------------------------------------------------------------------------

-- Clear queue from prior tests
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'stale_test_content_chunks';

-- Disable vectorization (keep chunk table)
SELECT pgedge_vectorizer.disable_vectorization('stale_test'::regclass, 'content', false);

-- Insert a long document that will produce multiple chunks with small chunk_size
DELETE FROM stale_test;
INSERT INTO stale_test (id, content) VALUES (10,
    'Alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron ' ||
    'pi rho sigma tau upsilon phi chi psi omega. ' ||
    'More words here to ensure this document produces several chunks when using a very small chunk size. ' ||
    'We need enough content that the chunker will split this into at least three or four separate pieces. ' ||
    'Adding yet more filler text to be absolutely certain we get multiple chunks from this single document.'
);

-- Re-enable with a very small chunk_size to force many chunks
SELECT pgedge_vectorizer.enable_vectorization(
    'stale_test'::regclass,
    'content',
    'token_based',
    10,
    2,
    1536
);

-- Verify multiple chunks were created
SELECT COUNT(*) > 1 AS multiple_chunks FROM stale_test_content_chunks WHERE source_id = 10;

-- Record the chunk count
SELECT COUNT(*) AS chunk_count_before FROM stale_test_content_chunks WHERE source_id = 10;

-- Disable again (keep chunk table), clear queue
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'stale_test_content_chunks';
SELECT pgedge_vectorizer.disable_vectorization('stale_test'::regclass, 'content', false);

-- Shorten the document drastically
UPDATE stale_test SET content = 'Short.' WHERE id = 10;

-- Re-enable with same small chunk_size (should produce fewer chunks)
SELECT pgedge_vectorizer.enable_vectorization(
    'stale_test'::regclass,
    'content',
    'token_based',
    10,
    2,
    1536
);

-- Chunk count should have decreased (no stale high-index chunks)
SELECT COUNT(*) AS chunk_count_after FROM stale_test_content_chunks WHERE source_id = 10;

-- No orphaned queue entries for stale chunks
SELECT COUNT(*) AS stale_queue_entries
FROM pgedge_vectorizer.queue
WHERE chunk_table = 'stale_test_content_chunks'
  AND chunk_id NOT IN (SELECT id FROM stale_test_content_chunks)
  AND status IN ('pending', 'failed');

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'stale_test_content_chunks';
SELECT pgedge_vectorizer.disable_vectorization('stale_test'::regclass, 'content', true);
DROP TABLE stale_test;

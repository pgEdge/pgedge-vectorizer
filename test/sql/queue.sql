-- Queue test
-- This test verifies queue table functionality

-- Verify queue is initially empty
SELECT COUNT(*) AS initial_queue_count FROM pgedge_vectorizer.queue;

-- Test queue views exist and are accessible
SELECT COUNT(*) >= 0 AS queue_status_exists
FROM pgedge_vectorizer.queue_status;

SELECT COUNT(*) >= 0 AS pending_count_exists
FROM pgedge_vectorizer.pending_count;

SELECT COUNT(*) >= 0 AS failed_items_exists
FROM pgedge_vectorizer.failed_items;

-- Test utility functions
SELECT pgedge_vectorizer.retry_failed() >= 0 AS retry_works;

SELECT pgedge_vectorizer.clear_completed() >= 0 AS clear_works;

-- A rate limit is deferred rather than charged as an attempt, so the deferrals
-- have a column of their own. retry_failed() has to clear it along with the
-- attempts, or an item retired for being throttled all day would be retired
-- again by its first request.
INSERT INTO pgedge_vectorizer.queue
       (chunk_id, chunk_table, content, status, attempts, max_attempts,
        rate_limit_deferrals, error_message)
VALUES (1, 'rl_chunks', 'throttled', 'failed', 0, 10, 100,
        'Voyage AI API returned HTTP 429');

SELECT rate_limit_deferrals FROM pgedge_vectorizer.failed_items
 WHERE chunk_table = 'rl_chunks';

SELECT pgedge_vectorizer.retry_failed() > 0 AS throttled_item_revived;

SELECT status, attempts, rate_limit_deferrals
  FROM pgedge_vectorizer.queue WHERE chunk_table = 'rl_chunks';

DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'rl_chunks';

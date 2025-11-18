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

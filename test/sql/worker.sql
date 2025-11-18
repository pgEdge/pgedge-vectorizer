-- Worker test
-- This test verifies worker-related views and functions

-- Check that background workers are configured
SHOW pgedge_vectorizer.num_workers;

-- Verify worker settings
SHOW pgedge_vectorizer.batch_size;
SHOW pgedge_vectorizer.max_retries;
SHOW pgedge_vectorizer.worker_poll_interval;

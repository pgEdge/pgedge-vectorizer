-- Worker test
-- This test verifies worker-related views and functions

-- Check that background workers are configured
SHOW pgedge_vectorizer.num_workers;

-- Verify worker settings
SHOW pgedge_vectorizer.batch_size;
SHOW pgedge_vectorizer.max_retries;
SHOW pgedge_vectorizer.worker_poll_interval;

-- Service quantum bounds how long a worker holds its slot when there are more
-- configured databases than num_workers allows to run concurrently
SHOW pgedge_vectorizer.worker_service_quantum;

-- num_workers is a runtime-changeable concurrency cap rather than a fixed pool
-- size, so it no longer requires a restart
SELECT context FROM pg_settings WHERE name = 'pgedge_vectorizer.num_workers';

-- Setup test
-- This test verifies basic extension installation

-- Load extensions
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION pgedge_vectorizer;

-- Verify schema created
SELECT nspname FROM pg_namespace WHERE nspname = 'pgedge_vectorizer';

-- Verify queue table created
SELECT tablename FROM pg_tables
WHERE schemaname = 'pgedge_vectorizer' AND tablename = 'queue';

-- Check configuration
SELECT setting, value
FROM pgedge_vectorizer.show_config()
WHERE setting IN (
    'pgedge_vectorizer.provider',
    'pgedge_vectorizer.default_chunk_size',
    'pgedge_vectorizer.default_chunk_overlap'
)
ORDER BY setting;

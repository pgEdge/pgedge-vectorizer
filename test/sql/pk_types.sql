-- Primary key types test
-- This test verifies that vectorization works with various primary key types

-- ============================================================================
-- Test 1: UUID primary key
-- ============================================================================
CREATE TABLE test_uuid_pk (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    content TEXT
);

-- Enable vectorization
SELECT pgedge_vectorizer.enable_vectorization(
    'test_uuid_pk'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- Verify source_id column type matches UUID
SELECT data_type
FROM information_schema.columns
WHERE table_name = 'test_uuid_pk_content_chunks'
AND column_name = 'source_id';

-- Insert a test document
INSERT INTO test_uuid_pk (content)
VALUES ('This document has a UUID primary key.');

-- Verify chunks were created
SELECT COUNT(*) > 0 AS chunks_created FROM test_uuid_pk_content_chunks;

-- Test UPDATE
UPDATE test_uuid_pk SET content = 'Updated UUID document content.';

-- Verify chunks still exist after update
SELECT COUNT(*) > 0 AS chunks_after_update FROM test_uuid_pk_content_chunks;

-- Clean up
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'test_uuid_pk_content_chunks';
SELECT pgedge_vectorizer.disable_vectorization('test_uuid_pk'::regclass, 'content', true);
DROP TABLE test_uuid_pk;

-- ============================================================================
-- Test 2: INTEGER (SERIAL) primary key
-- ============================================================================
CREATE TABLE test_serial_pk (
    id SERIAL PRIMARY KEY,
    content TEXT
);

-- Enable vectorization
SELECT pgedge_vectorizer.enable_vectorization(
    'test_serial_pk'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- Verify source_id column type matches integer
SELECT data_type
FROM information_schema.columns
WHERE table_name = 'test_serial_pk_content_chunks'
AND column_name = 'source_id';

-- Insert a test document
INSERT INTO test_serial_pk (content)
VALUES ('This document has an integer primary key.');

-- Verify chunks were created
SELECT COUNT(*) > 0 AS chunks_created FROM test_serial_pk_content_chunks;

-- Clean up
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'test_serial_pk_content_chunks';
SELECT pgedge_vectorizer.disable_vectorization('test_serial_pk'::regclass, 'content', true);
DROP TABLE test_serial_pk;

-- ============================================================================
-- Test 3: BIGINT primary key (regression test)
-- ============================================================================
CREATE TABLE test_bigint_pk (
    id BIGSERIAL PRIMARY KEY,
    content TEXT
);

-- Enable vectorization
SELECT pgedge_vectorizer.enable_vectorization(
    'test_bigint_pk'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- Verify source_id column type matches bigint
SELECT data_type
FROM information_schema.columns
WHERE table_name = 'test_bigint_pk_content_chunks'
AND column_name = 'source_id';

-- Insert a test document
INSERT INTO test_bigint_pk (content)
VALUES ('This document has a bigint primary key.');

-- Verify chunks were created
SELECT COUNT(*) > 0 AS chunks_created FROM test_bigint_pk_content_chunks;

-- Clean up
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'test_bigint_pk_content_chunks';
SELECT pgedge_vectorizer.disable_vectorization('test_bigint_pk'::regclass, 'content', true);
DROP TABLE test_bigint_pk;

-- ============================================================================
-- Test 4: TEXT primary key (slug-style)
-- ============================================================================
CREATE TABLE test_text_pk (
    slug TEXT PRIMARY KEY,
    content TEXT
);

-- Enable vectorization
SELECT pgedge_vectorizer.enable_vectorization(
    'test_text_pk'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- Verify source_id column type matches text
SELECT data_type
FROM information_schema.columns
WHERE table_name = 'test_text_pk_content_chunks'
AND column_name = 'source_id';

-- Insert a test document with a slug value
INSERT INTO test_text_pk (slug, content)
VALUES ('my-great-article', 'This document uses a text slug as primary key.');

-- Verify chunks were created
SELECT COUNT(*) > 0 AS chunks_created FROM test_text_pk_content_chunks;

-- Verify the actual source_id value stored
SELECT source_id FROM test_text_pk_content_chunks LIMIT 1;

-- Clean up
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'test_text_pk_content_chunks';
SELECT pgedge_vectorizer.disable_vectorization('test_text_pk'::regclass, 'content', true);
DROP TABLE test_text_pk;

-- ============================================================================
-- Test 5: VARCHAR(26) primary key (ULID-style)
-- ============================================================================
CREATE TABLE test_varchar_pk (
    id VARCHAR(26) PRIMARY KEY,
    content TEXT
);

-- Enable vectorization
SELECT pgedge_vectorizer.enable_vectorization(
    'test_varchar_pk'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- Verify source_id column type matches character varying
SELECT data_type
FROM information_schema.columns
WHERE table_name = 'test_varchar_pk_content_chunks'
AND column_name = 'source_id';

-- Insert a test document with a ULID-style value
INSERT INTO test_varchar_pk (id, content)
VALUES ('01HZXK5V3RQJF8N2GYTP4M', 'This document uses a VARCHAR ULID-style primary key.');

-- Verify chunks were created
SELECT COUNT(*) > 0 AS chunks_created FROM test_varchar_pk_content_chunks;

-- Clean up
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'test_varchar_pk_content_chunks';
SELECT pgedge_vectorizer.disable_vectorization('test_varchar_pk'::regclass, 'content', true);
DROP TABLE test_varchar_pk;

-- ============================================================================
-- Test 6: BIGINT primary key named record_num (auto-detection)
-- ============================================================================
CREATE TABLE test_autodetect_pk (
    record_num BIGSERIAL PRIMARY KEY,
    content TEXT
);

-- Enable vectorization WITHOUT passing source_pk
-- Auto-detection should find 'record_num' from pg_index
SELECT pgedge_vectorizer.enable_vectorization(
    'test_autodetect_pk'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- Verify source_id column type matches bigint
SELECT data_type
FROM information_schema.columns
WHERE table_name = 'test_autodetect_pk_content_chunks'
AND column_name = 'source_id';

-- Insert a test document
INSERT INTO test_autodetect_pk (content)
VALUES ('This document uses an auto-detected primary key.');

-- Verify chunks were created
SELECT COUNT(*) > 0 AS chunks_created FROM test_autodetect_pk_content_chunks;

-- Clean up
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'test_autodetect_pk_content_chunks';
SELECT pgedge_vectorizer.disable_vectorization('test_autodetect_pk'::regclass, 'content', true);
DROP TABLE test_autodetect_pk;

-- ============================================================================
-- Test 7: Composite primary key (error case)
-- ============================================================================
CREATE TABLE test_composite_pk (
    tenant_id INT NOT NULL,
    item_id INT NOT NULL,
    content TEXT,
    PRIMARY KEY (tenant_id, item_id)
);

-- This should raise an error because composite PKs are not supported
SELECT pgedge_vectorizer.enable_vectorization(
    'test_composite_pk'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- Clean up (no vectorization to disable, just drop the table)
DROP TABLE test_composite_pk;

-- ============================================================================
-- Test 7a: Composite primary key with explicit source_pk (should succeed)
-- ============================================================================
CREATE TABLE test_composite_override (
    tenant_id INT NOT NULL,
    item_id INT NOT NULL,
    content TEXT,
    PRIMARY KEY (tenant_id, item_id)
);

-- This should succeed because we specify which column to use
-- Note: source_pk must be globally unique to avoid UNIQUE(source_id, chunk_index) conflicts
SELECT pgedge_vectorizer.enable_vectorization(
    'test_composite_override'::regclass, 'content', 'token_based', 100, 10, 1536, NULL, 'item_id'
);

-- Verify source_id column type matches integer
SELECT data_type
FROM information_schema.columns
WHERE table_name = 'test_composite_override_content_chunks'
AND column_name = 'source_id';

-- Insert a test document with unique item_id
INSERT INTO test_composite_override (tenant_id, item_id, content)
VALUES (1, 42, 'Document in a composite PK table with explicit source_pk.');

-- Verify chunks were created
SELECT COUNT(*) > 0 AS chunks_created FROM test_composite_override_content_chunks;

-- Insert a second row with the SAME item_id but different tenant_id.
-- This demonstrates the uniqueness conflict: source_pk must be globally
-- unique, not just unique within the composite key.
INSERT INTO test_composite_override (tenant_id, item_id, content)
VALUES (2, 42, 'Different tenant, same item_id — will conflict on chunk table.');

-- Verify the conflict: the second insert's trigger overwrites the first
-- row's chunks because they share the same source_id (42)
SELECT COUNT(*) AS chunk_count FROM test_composite_override_content_chunks WHERE source_id = 42;

-- Clean up
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'test_composite_override_content_chunks';
SELECT pgedge_vectorizer.disable_vectorization('test_composite_override'::regclass, 'content', true);
DROP TABLE test_composite_override;

-- ============================================================================
-- Test 7b: No primary key (error case)
-- ============================================================================
CREATE TABLE test_no_pk (
    item_id INT NOT NULL,
    content TEXT
);

-- This should raise an error because the table has no primary key
SELECT pgedge_vectorizer.enable_vectorization(
    'test_no_pk'::regclass,
    'content',
    'token_based',
    100,
    10,
    1536
);

-- Clean up
DROP TABLE test_no_pk;

-- ============================================================================
-- Test 8: Explicit source_pk override
-- ============================================================================
CREATE TABLE test_override_pk (
    id BIGSERIAL PRIMARY KEY,
    external_id UUID NOT NULL DEFAULT gen_random_uuid(),
    content TEXT
);

-- Enable vectorization with explicit source_pk override using positional args
-- Pass NULL for chunk_table_name, 'external_id' for source_pk
SELECT pgedge_vectorizer.enable_vectorization(
    'test_override_pk'::regclass, 'content', 'token_based', 100, 10, 1536, NULL, 'external_id'
);

-- Verify source_id column type matches uuid (from external_id, not bigint from id)
SELECT data_type
FROM information_schema.columns
WHERE table_name = 'test_override_pk_content_chunks'
AND column_name = 'source_id';

-- Insert a test document
INSERT INTO test_override_pk (content)
VALUES ('This document uses an overridden primary key column.');

-- Verify chunks were created
SELECT COUNT(*) > 0 AS chunks_created FROM test_override_pk_content_chunks;

-- Clean up
DELETE FROM pgedge_vectorizer.queue WHERE chunk_table = 'test_override_pk_content_chunks';
SELECT pgedge_vectorizer.disable_vectorization('test_override_pk'::regclass, 'content', true);
DROP TABLE test_override_pk;

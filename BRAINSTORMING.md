# PostgreSQL Async Embedding Extension Design

IMPORTANT: This document is the transcipt of a brainstorming session. It should
NOT be taken as a design document, but may be the source of implementation
ideas.

## Overview

A general-purpose PostgreSQL extension that provides:
- Asynchronous embedding generation using background workers
- Support for multiple embedding providers (OpenAI, Anthropic, Ollama)
- Automatic document chunking with multiple strategies
- Complete document-to-vector pipeline within PostgreSQL

## Project Context

- **Implementation**: C extension with background workers
- **Target Audience**: General PostgreSQL users building AI applications
- **Key Features**: Provider abstraction, automatic chunking, async processing, batching support

---

## Core Architecture

### Database Schema

#### Queue Table
```sql
CREATE TABLE pg_embedding.queue (
    id BIGSERIAL PRIMARY KEY,
    target_table regclass NOT NULL,  -- Which table to update
    target_id bigint NOT NULL,       -- Which row (assumes bigint PK)
    target_column name NOT NULL,     -- Which column to update
    content text NOT NULL,           -- Text to embed
    provider text,                   -- Override default provider
    model text,                      -- Override default model
    status text DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    attempts int DEFAULT 0,
    max_attempts int DEFAULT 3,
    error_message text,
    embedding_dim int,               -- Dimension of resulting embedding
    created_at timestamptz DEFAULT NOW(),
    processing_started_at timestamptz,
    processed_at timestamptz,
    next_retry_at timestamptz,
    metadata jsonb                   -- User-defined metadata
);

CREATE INDEX ON pg_embedding.queue(status, next_retry_at) 
    WHERE status IN ('pending', 'failed');

CREATE INDEX ON pg_embedding.queue(target_table, target_id);
```

#### Document and Chunks Tables
```sql
-- Parent documents
CREATE TABLE documents (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,  -- Original full text
    source_url TEXT,
    metadata JSONB,
    chunk_strategy TEXT DEFAULT 'token_based',
    chunk_size INT DEFAULT 400,
    chunk_overlap INT DEFAULT 50,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Child chunks (auto-generated)
CREATE TABLE document_chunks (
    id BIGSERIAL PRIMARY KEY,
    document_id BIGINT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    chunk_index INT NOT NULL,
    content TEXT NOT NULL,
    token_count INT,
    start_char INT,
    end_char INT,
    embedding vector(1536),
    UNIQUE(document_id, chunk_index)
);

CREATE INDEX ON document_chunks USING hnsw (embedding vector_cosine_ops);
CREATE INDEX ON document_chunks(document_id);
```

### Background Worker Implementation

```c
#include "postgres.h"
#include "fmgr.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "utils/guc.h"
#include "access/xact.h"
#include "executor/spi.h"
#include "utils/snapmgr.h"

PG_MODULE_MAGIC;

void _PG_init(void);
void embedding_worker_main(Datum main_arg);

static volatile sig_atomic_t got_sigterm = false;
static volatile sig_atomic_t got_sighup = false;

static void
embedding_worker_sigterm(SIGNAL_ARGS)
{
    int save_errno = errno;
    got_sigterm = true;
    SetLatch(MyLatch);
    errno = save_errno;
}

static void
embedding_worker_sighup(SIGNAL_ARGS)
{
    int save_errno = errno;
    got_sighup = true;
    SetLatch(MyLatch);
    errno = save_errno;
}

void
embedding_worker_main(Datum main_arg)
{
    char *query;
    int ret;
    
    /* Setup signal handlers */
    pqsignal(SIGTERM, embedding_worker_sigterm);
    pqsignal(SIGHUP, embedding_worker_sighup);
    BackgroundWorkerUnblockSignals();

    /* Connect to database */
    BackgroundWorkerInitializeConnection("your_db", NULL, 0);

    /* Main loop */
    while (!got_sigterm)
    {
        int rc;
        
        /* Start transaction */
        SetCurrentStatementStartTimestamp();
        StartTransactionCommand();
        SPI_connect();
        PushActiveSnapshot(GetTransactionSnapshot());

        /* Fetch pending tasks with batch support */
        query = "SELECT id, chunk_id, content FROM embedding_queue "
                "WHERE status = 'pending' "
                "ORDER BY created_at LIMIT 10 FOR UPDATE SKIP LOCKED";
        
        ret = SPI_execute(query, false, 10);
        
        if (ret == SPI_OK_SELECT && SPI_processed > 0)
        {
            for (int i = 0; i < SPI_processed; i++)
            {
                /* Extract values */
                int64 queue_id = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[i],
                                                             SPI_tuptable->tupdesc, 1, NULL));
                int64 chunk_id = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[i],
                                                             SPI_tuptable->tupdesc, 2, NULL));
                char *content = SPI_getvalue(SPI_tuptable->vals[i],
                                            SPI_tuptable->tupdesc, 3);
                
                /* Mark as processing */
                SPI_execute_with_args("UPDATE embedding_queue SET status = 'processing' WHERE id = $1",
                                     1, (Oid[]){INT8OID}, (Datum[]){Int64GetDatum(queue_id)},
                                     NULL, false, 0);
                
                /* Generate embedding - call your API/model here */
                float *embedding = generate_embedding(content);
                
                if (embedding != NULL)
                {
                    /* Update chunks table with embedding */
                    /* Update chunks SET embedding = embedding_value WHERE id = chunk_id */
                    
                    /* Mark as completed */
                    SPI_execute_with_args("UPDATE embedding_queue SET status = 'completed', "
                                         "processed_at = NOW() WHERE id = $1",
                                         1, (Oid[]){INT8OID}, (Datum[]){Int64GetDatum(queue_id)},
                                         NULL, false, 0);
                }
                else
                {
                    /* Mark as failed with exponential backoff */
                    SPI_execute_with_args("UPDATE embedding_queue SET status = 'failed', "
                                         "attempts = attempts + 1 WHERE id = $1",
                                         1, (Oid[]){INT8OID}, (Datum[]){Int64GetDatum(queue_id)},
                                         NULL, false, 0);
                }
            }
        }

        SPI_finish();
        PopActiveSnapshot();
        CommitTransactionCommand();

        /* Wait for new work or timeout */
        rc = WaitLatch(MyLatch,
                      WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
                      1000L,  // 1 second timeout
                      PG_WAIT_EXTENSION);
        
        ResetLatch(MyLatch);

        if (rc & WL_POSTMASTER_DEATH)
            proc_exit(1);
    }

    proc_exit(0);
}
```

---

## Provider Abstraction Layer

### Provider Interface

```c
// embedding_provider.h
typedef struct EmbeddingProvider {
    const char *name;
    float* (*generate)(const char *text, int *dim, char **error);
    float** (*generate_batch)(const char **texts, int count, int *dim, char **error);
    void (*init)(void);
    void (*cleanup)(void);
} EmbeddingProvider;

// Provider registry
static EmbeddingProvider providers[] = {
    {
        .name = "openai",
        .generate = openai_generate_embedding,
        .generate_batch = openai_generate_batch,
        .init = openai_init,
        .cleanup = openai_cleanup
    },
    {
        .name = "anthropic", 
        .generate = anthropic_generate_embedding,
        .generate_batch = anthropic_generate_batch,
        .init = anthropic_init,
        .cleanup = anthropic_cleanup
    },
    {
        .name = "ollama",
        .generate = ollama_generate_embedding,
        .generate_batch = ollama_generate_batch,
        .init = ollama_init,
        .cleanup = ollama_cleanup
    }
};
```

### Provider Implementations

#### OpenAI
```c
static float*
openai_generate_embedding(const char *text, int *dim, char **error)
{
    CURL *curl = curl_easy_init();
    struct curl_slist *headers = NULL;
    char auth_header[512];
    
    snprintf(auth_header, sizeof(auth_header), 
             "Authorization: Bearer %s", embedding_api_key);
    headers = curl_slist_append(headers, "Content-Type: application/json");
    headers = curl_slist_append(headers, auth_header);
    
    // Build JSON request
    char *json_request;
    json_request = psprintf("{\"input\":\"%s\",\"model\":\"%s\"}", 
                           escape_json(text), embedding_model);
    
    // Execute request, parse response
    // Return float array and set dim
}
```

#### Ollama
```c
static float*
ollama_generate_embedding(const char *text, int *dim, char **error)
{
    // POST to http://localhost:11434/api/embeddings
    // No auth needed for local Ollama
    // Synchronous, low latency
}
```

---

## Chunking System

### Chunking Strategies

```c
typedef enum {
    CHUNK_STRATEGY_TOKEN,      // Fixed token count
    CHUNK_STRATEGY_SEMANTIC,   // Semantic boundaries (paragraphs, sentences)
    CHUNK_STRATEGY_MARKDOWN,   // Respect markdown structure
    CHUNK_STRATEGY_SENTENCE,   // Sentence-based
    CHUNK_STRATEGY_RECURSIVE   // Recursive character splitting
} ChunkStrategy;

typedef struct ChunkConfig {
    ChunkStrategy strategy;
    int chunk_size;        // Target size in tokens
    int overlap;           // Overlap in tokens
    char *separators;      // For semantic chunking
} ChunkConfig;
```

### Token-Based Chunking

```c
static ArrayType*
chunk_by_tokens(const char *content, ChunkConfig *config)
{
    // Tokenize using tiktoken or similar
    int *tokens;
    int num_tokens = tokenize(content, &tokens);
    
    List *chunks = NIL;
    int start = 0;
    
    while (start < num_tokens) {
        int end = start + config->chunk_size;
        if (end > num_tokens)
            end = num_tokens;
        
        // Decode tokens back to text
        char *chunk_text = detokenize(tokens + start, end - start);
        chunks = lappend(chunks, cstring_to_text(chunk_text));
        
        // Move forward with overlap
        start += config->chunk_size - config->overlap;
    }
    
    // Convert list to PostgreSQL array
    return list_to_text_array(chunks);
}
```

### Markdown-Aware Chunking

```c
static ArrayType*
chunk_by_markdown(const char *content, ChunkConfig *config)
{
    /*
     * Strategy:
     * 1. Split by headings (##, ###, etc.)
     * 2. Keep hierarchical context (include parent heading)
     * 3. If section too large, split further by paragraphs
     * 4. Respect code blocks and lists
     */
    
    List *sections = split_markdown_sections(content);
    List *chunks = NIL;
    
    ListCell *lc;
    foreach(lc, sections) {
        MarkdownSection *section = (MarkdownSection *) lfirst(lc);
        
        int section_tokens = count_tokens(section->content);
        
        if (section_tokens <= config->chunk_size) {
            // Section fits in one chunk
            char *chunk_with_context = build_chunk_with_context(section);
            chunks = lappend(chunks, cstring_to_text(chunk_with_context));
        } else {
            // Section too large, split into paragraphs
            List *sub_chunks = split_large_section(section, config);
            chunks = list_concat(chunks, sub_chunks);
        }
    }
    
    return list_to_text_array(chunks);
}

static char*
build_chunk_with_context(MarkdownSection *section)
{
    StringInfoData buf;
    initStringInfo(&buf);
    
    // Add heading hierarchy for context
    if (section->parent_heading)
        appendStringInfo(&buf, "# %s\n\n", section->parent_heading);
    
    if (section->heading)
        appendStringInfo(&buf, "%s %s\n\n", 
                        section->heading_level, section->heading);
    
    appendStringInfoString(&buf, section->content);
    
    return buf.data;
}
```

### Semantic Chunking

```c
static ArrayType*
chunk_by_semantics(const char *content, ChunkConfig *config)
{
    /*
     * Strategy:
     * 1. Split by natural boundaries (double newlines, sentences)
     * 2. Group semantically related paragraphs
     * 3. Respect target chunk size
     */
    
    List *paragraphs = split_by_paragraphs(content);
    List *chunks = NIL;
    StringInfoData current_chunk;
    int current_tokens = 0;
    
    initStringInfo(&current_chunk);
    
    ListCell *lc;
    foreach(lc, paragraphs) {
        char *para = (char *) lfirst(lc);
        int para_tokens = count_tokens(para);
        
        if (current_tokens + para_tokens <= config->chunk_size) {
            // Add to current chunk
            if (current_chunk.len > 0)
                appendStringInfoString(&current_chunk, "\n\n");
            appendStringInfoString(&current_chunk, para);
            current_tokens += para_tokens;
        } else {
            // Save current chunk and start new one
            if (current_chunk.len > 0) {
                chunks = lappend(chunks, cstring_to_text(current_chunk.data));
                resetStringInfo(&current_chunk);
            }
            
            // Handle paragraph larger than chunk size
            if (para_tokens > config->chunk_size) {
                List *sub_chunks = split_paragraph(para, config);
                chunks = list_concat(chunks, sub_chunks);
            } else {
                appendStringInfoString(&current_chunk, para);
                current_tokens = para_tokens;
            }
        }
    }
    
    // Don't forget last chunk
    if (current_chunk.len > 0)
        chunks = lappend(chunks, cstring_to_text(current_chunk.data));
    
    return list_to_text_array(chunks);
}
```

### Trigger Function for Automatic Chunking

```sql
CREATE OR REPLACE FUNCTION pg_embedding.chunk_and_queue()
RETURNS TRIGGER AS $$
DECLARE
    content_col text;
    chunk_table text;
    strategy text;
    chunk_sz int;
    overlap int;
    doc_content text;
    chunks text[];
    chunk_text text;
    i int;
    chunk_id bigint;
BEGIN
    -- Extract arguments passed from CREATE TRIGGER
    content_col := TG_ARGV[0];
    chunk_table := TG_ARGV[1];
    strategy := TG_ARGV[2];
    chunk_sz := TG_ARGV[3]::int;
    overlap := TG_ARGV[4]::int;
    
    -- Get document content
    EXECUTE format('SELECT $1.%I', content_col) 
        USING NEW INTO doc_content;
    
    -- Skip if content unchanged
    IF TG_OP = 'UPDATE' THEN
        DECLARE
            old_content text;
        BEGIN
            EXECUTE format('SELECT $1.%I', content_col) 
                USING OLD INTO old_content;
            IF doc_content = old_content THEN
                RETURN NEW;
            END IF;
        END;
    END IF;
    
    -- Delete existing chunks for this document
    EXECUTE format('DELETE FROM %I WHERE document_id = $1', chunk_table)
        USING NEW.id;
    
    -- Chunk the document (call C function)
    chunks := pg_embedding.chunk_text(doc_content, strategy, chunk_sz, overlap);
    
    -- Insert chunks and queue for embedding
    FOR i IN 1..array_length(chunks, 1) LOOP
        chunk_text := chunks[i];
        
        -- Insert chunk
        EXECUTE format('
            INSERT INTO %I (document_id, chunk_index, content, token_count)
            VALUES ($1, $2, $3, $4)
            RETURNING id', chunk_table)
        USING NEW.id, i, chunk_text, pg_embedding.count_tokens(chunk_text)
        INTO chunk_id;
        
        -- Queue for embedding
        INSERT INTO pg_embedding.queue (
            target_table, target_id, target_column, content
        ) VALUES (
            chunk_table::regclass, chunk_id, 'embedding', chunk_text
        );
    END LOOP;
    
    -- Notify workers
    PERFORM pg_notify('embedding_queue', NEW.id::text);
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

---

## Configuration (GUC Parameters)

```c
// Core settings
static char *embedding_provider = "openai";
static char *embedding_api_key = NULL;
static char *embedding_api_url = NULL;
static char *embedding_model = "text-embedding-3-small";
static int num_workers = 2;
static int batch_size = 10;
static int max_retries = 3;
static int worker_poll_interval = 1000; // ms

// Chunking settings
static bool auto_chunk_enabled = true;
static char *default_chunk_strategy = "token_based";
static int default_chunk_size = 400;
static int default_chunk_overlap = 50;

void
_PG_init(void)
{
    DefineCustomStringVariable("pg_embedding.provider",
                              "Embedding provider (openai, anthropic, ollama)",
                              NULL, &embedding_provider, "openai",
                              PGC_SIGHUP, 0, NULL, NULL, NULL);
    
    DefineCustomStringVariable("pg_embedding.api_key",
                              "API key for embedding provider",
                              NULL, &embedding_api_key, NULL,
                              PGC_SIGHUP, 0, NULL, NULL, NULL);
    
    DefineCustomStringVariable("pg_embedding.api_url",
                              "API URL (for Ollama or custom endpoints)",
                              NULL, &embedding_api_url, "http://localhost:11434",
                              PGC_SIGHUP, 0, NULL, NULL, NULL);
    
    DefineCustomStringVariable("pg_embedding.model",
                              "Model name to use",
                              NULL, &embedding_model, "text-embedding-3-small",
                              PGC_SIGHUP, 0, NULL, NULL, NULL);
    
    DefineCustomIntVariable("pg_embedding.num_workers",
                           "Number of background workers",
                           NULL, &num_workers, 2, 1, 32,
                           PGC_POSTMASTER, 0, NULL, NULL, NULL);
    
    DefineCustomIntVariable("pg_embedding.batch_size",
                           "Number of texts to embed in one API call",
                           NULL, &batch_size, 10, 1, 100,
                           PGC_SIGHUP, 0, NULL, NULL, NULL);
    
    DefineCustomBoolVariable("pg_embedding.auto_chunk",
                            "Enable automatic chunking",
                            NULL, &auto_chunk_enabled, true,
                            PGC_SIGHUP, 0, NULL, NULL, NULL);
    
    DefineCustomStringVariable("pg_embedding.default_chunk_strategy",
                              "Default chunking strategy",
                              NULL, &default_chunk_strategy, "token_based",
                              PGC_SIGHUP, 0, NULL, NULL, NULL);
    
    DefineCustomIntVariable("pg_embedding.default_chunk_size",
                           "Default chunk size in tokens",
                           NULL, &default_chunk_size, 400, 50, 2000,
                           PGC_SIGHUP, 0, NULL, NULL, NULL);
    
    DefineCustomIntVariable("pg_embedding.default_chunk_overlap",
                           "Default chunk overlap in tokens",
                           NULL, &default_chunk_overlap, 50, 0, 500,
                           PGC_SIGHUP, 0, NULL, NULL, NULL);
    
    // Register workers based on num_workers GUC
    if (process_shared_preload_libraries_in_progress)
    {
        for (int i = 0; i < num_workers; i++)
        {
            BackgroundWorker worker;
            memset(&worker, 0, sizeof(BackgroundWorker));
            worker.bgw_flags = BGWORKER_SHMEM_ACCESS |
                              BGWORKER_BACKEND_DATABASE_CONNECTION;
            worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
            worker.bgw_restart_time = 10; // Restart after 10s if crashes
            sprintf(worker.bgw_library_name, "pg_embedding");
            sprintf(worker.bgw_function_name, "embedding_worker_main");
            snprintf(worker.bgw_name, BGW_MAXLEN, "pg_embedding worker %d", i);
            worker.bgw_main_arg = Int32GetDatum(i);
            worker.bgw_notify_pid = 0;
            
            RegisterBackgroundWorker(&worker);
        }
    }
}
```

---

## SQL API

### Enable Document Chunking

```sql
CREATE FUNCTION pg_embedding.enable_document_chunking(
    document_table regclass,
    content_column name,
    chunk_strategy text DEFAULT 'token_based',
    chunk_size int DEFAULT 400,
    chunk_overlap int DEFAULT 50,
    chunk_table_name text DEFAULT NULL
) RETURNS void AS $$
DECLARE
    chunk_table text;
    trigger_name text;
BEGIN
    -- Create chunks table
    chunk_table := COALESCE(chunk_table_name, document_table::text || '_chunks');
    
    EXECUTE format('
        CREATE TABLE IF NOT EXISTS %I (
            id BIGSERIAL PRIMARY KEY,
            document_id BIGINT NOT NULL,
            chunk_index INT NOT NULL,
            content TEXT NOT NULL,
            token_count INT,
            start_char INT,
            end_char INT,
            embedding vector(%s),
            metadata JSONB,
            UNIQUE(document_id, chunk_index)
        )', chunk_table, get_embedding_dimension());
    
    EXECUTE format('
        CREATE INDEX IF NOT EXISTS %I ON %I 
        USING hnsw (embedding vector_cosine_ops)',
        chunk_table || '_embedding_idx', chunk_table);
    
    -- Create trigger to chunk on insert/update
    trigger_name := format('%s_chunking_trigger', document_table);
    
    EXECUTE format('
        CREATE TRIGGER %I
        AFTER INSERT OR UPDATE ON %s
        FOR EACH ROW
        EXECUTE FUNCTION pg_embedding.chunk_and_queue(%L, %L, %L, %L, %L)',
        trigger_name, document_table, 
        content_column, chunk_table, chunk_strategy, chunk_size, chunk_overlap);
    
    RAISE NOTICE 'Document chunking enabled: % -> %', document_table, chunk_table;
END;
$$ LANGUAGE plpgsql;
```

### Additional Utility Functions

```sql
-- Disable async embeddings
CREATE FUNCTION pg_embedding.disable_async(
    target_table regclass
) RETURNS void AS $$
-- Drop trigger and optionally clean up queue
$$ LANGUAGE plpgsql;

-- Manual queue entry
CREATE FUNCTION pg_embedding.queue_text(
    content text,
    callback_function regproc DEFAULT NULL
) RETURNS bigint AS $$
-- Queue arbitrary text for embedding
-- Returns queue ID
$$ LANGUAGE plpgsql;

-- Check queue status
CREATE VIEW pg_embedding.queue_status AS
SELECT 
    target_table,
    status,
    COUNT(*) as count,
    MIN(created_at) as oldest,
    MAX(created_at) as newest
FROM pg_embedding.queue
GROUP BY target_table, status;

-- Test provider setup
CREATE FUNCTION pg_embedding.test_provider()
RETURNS jsonb AS $$
DECLARE
    result jsonb;
BEGIN
    -- Generate a test embedding synchronously
    -- Return provider info, model, dimensions, latency
    RETURN jsonb_build_object(
        'provider', current_setting('pg_embedding.provider'),
        'model', current_setting('pg_embedding.model'),
        'dimensions', 1536,
        'latency_ms', 145,
        'status', 'ok'
    );
END;
$$ LANGUAGE plpgsql;
```

---

## Usage Examples

### Example 1: Simple Document Table with Auto-Chunking

```sql
-- Create documents table
CREATE TABLE articles (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,
    url TEXT
);

-- Enable chunking + embedding
SELECT pg_embedding.enable_document_chunking(
    'articles'::regclass,
    'content',
    chunk_strategy := 'markdown',
    chunk_size := 400,
    chunk_overlap := 50
);

-- Insert document - chunks automatically created and embedded
INSERT INTO articles (title, content, url)
VALUES (
    'PostgreSQL Internals',
    '# Introduction\n\nPostgreSQL is...\n\n## Architecture\n\n...',
    'https://example.com/pg-internals'
);

-- Query happens automatically on articles_chunks table
SELECT 
    a.title,
    c.content,
    c.embedding <=> '[0.1, 0.2, ...]'::vector AS distance
FROM articles a
JOIN articles_chunks c ON a.id = c.document_id
ORDER BY distance
LIMIT 5;
```

### Example 2: Configuration for Different Providers

#### OpenAI Setup
```sql
ALTER SYSTEM SET pg_embedding.provider = 'openai';
ALTER SYSTEM SET pg_embedding.api_key = 'sk-...';
ALTER SYSTEM SET pg_embedding.model = 'text-embedding-3-small';
ALTER SYSTEM SET pg_embedding.num_workers = 4;
SELECT pg_reload_conf();
```

#### Local Ollama Setup
```sql
ALTER SYSTEM SET pg_embedding.provider = 'ollama';
ALTER SYSTEM SET pg_embedding.api_url = 'http://localhost:11434';
ALTER SYSTEM SET pg_embedding.model = 'nomic-embed-text';
ALTER SYSTEM SET pg_embedding.num_workers = 8; -- Can handle more with local model
SELECT pg_reload_conf();
```

### Example 3: Wikipedia Articles with Semantic Chunking

```sql
CREATE TABLE wikipedia_articles (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,
    url TEXT,
    last_modified TIMESTAMPTZ
);

SELECT pg_embedding.enable_document_chunking(
    'wikipedia_articles'::regclass,
    'content',
    chunk_strategy := 'semantic',
    chunk_size := 500,
    chunk_overlap := 75
);

-- Per-document override
INSERT INTO wikipedia_articles (title, content)
VALUES ('Long Technical Article', '...');

-- Can also manually chunk with different settings
SELECT pg_embedding.rechunk_document(
    'wikipedia_articles'::regclass,
    123,  -- article ID
    chunk_strategy := 'markdown',
    chunk_size := 300
);
```

### Example 4: Hierarchical Chunking for Research Papers

```sql
CREATE TABLE research_papers (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    content TEXT
);

-- Section-level chunks
CREATE TABLE paper_sections (
    id BIGSERIAL PRIMARY KEY,
    paper_id BIGINT REFERENCES research_papers(id),
    section_name TEXT,
    content TEXT,
    embedding vector(1536)
);

-- Paragraph-level chunks
CREATE TABLE paper_chunks (
    id BIGSERIAL PRIMARY KEY,
    paper_id BIGINT REFERENCES research_papers(id),
    section_id BIGINT REFERENCES paper_sections(id),
    content TEXT,
    embedding vector(1536)
);

-- Two-tier chunking
SELECT pg_embedding.enable_hierarchical_chunking(
    'research_papers'::regclass,
    'content',
    levels := ARRAY[
        ROW('section', 'markdown', 2000, 0)::chunk_level,
        ROW('chunk', 'semantic', 400, 50)::chunk_level
    ]
);
```

---

## Monitoring and Observability

### Stats Table

```sql
CREATE TABLE pg_embedding.stats (
    worker_id int,
    embeddings_generated bigint DEFAULT 0,
    embeddings_failed bigint DEFAULT 0,
    total_latency_ms bigint DEFAULT 0,
    last_activity timestamptz,
    PRIMARY KEY (worker_id)
);

-- Function to get real-time stats
CREATE FUNCTION pg_embedding.get_stats()
RETURNS TABLE (
    worker_id int,
    embeddings_per_min float,
    avg_latency_ms float,
    success_rate float,
    queue_depth bigint
) AS $$
-- Calculate rates and percentages
$$ LANGUAGE sql;
```

### Chunking Stats View

```sql
CREATE VIEW pg_embedding.chunking_stats AS
SELECT 
    schemaname || '.' || tablename as table_name,
    pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) as chunks_size,
    (SELECT COUNT(*) FROM pg_class WHERE relname = tablename) as num_documents,
    (SELECT COUNT(*) FROM pg_class WHERE relname = tablename || '_chunks') /
    NULLIF((SELECT COUNT(*) FROM pg_class WHERE relname = tablename), 0) as avg_chunks_per_doc
FROM pg_tables
WHERE tablename LIKE '%_chunks';
```

---

## Implementation Considerations

### Recommended Chunk Sizes

- **Small chunks (100-200 tokens)**: Better for precise fact retrieval
- **Medium chunks (200-500 tokens)**: Sweet spot for most applications
- **Large chunks (500-1000+ tokens)**: Better semantic context

**Recommended starting point**: 400 tokens with 50-token overlap

### Document Format Conversion

**Converting to Markdown is recommended** for:
- Clean, consistent format for embeddings
- Preserves semantic structure
- Removes visual noise
- LLMs understand Markdown natively
- Easier to chunk meaningfully

**Storage recommendation**: Store both original and markdown versions

```sql
CREATE TABLE documents (
    id BIGSERIAL PRIMARY KEY,
    original_content BYTEA,      -- Original file
    original_format TEXT,         -- 'pdf', 'html', 'rst', etc.
    markdown_content TEXT,        -- Normalized version for chunking
    -- chunk from markdown_content
);
```

### Batching for API Efficiency

```c
void
process_batch(int worker_id)
{
    // Fetch batch (e.g., 50 chunks)
    SPI_execute("SELECT array_agg(id), array_agg(content) "
                "FROM embedding_queue "
                "WHERE status = 'pending' "
                "LIMIT 50 FOR UPDATE SKIP LOCKED",
                false, 50);
    
    // Generate embeddings in batch (provider-specific)
    float **embeddings = provider->generate_batch(texts, batch_size, &dim, &error);
    
    // Update all chunks with their embeddings
}
```

### Error Handling & Retry Logic

- Exponential backoff for failed embeddings
- Max retry attempts (configurable)
- `FOR UPDATE SKIP LOCKED` to prevent duplicate processing
- Track error messages for debugging

### Tokenization Options

**Option A: Embed tiktoken** (recommended for production)
- Fast, accurate BPE tokenization
- Large binary size (~10MB for vocab)

**Option B: Simple approximation**
```c
// Quick: ~4 chars per token (English)
static int approximate_token_count(const char *text) {
    return strlen(text) / 4;
}
```

**Option C: Call out to Python**
- More flexible but slower

---

## Extension Naming Suggestions

- `pg_embed_async`
- `pg_vector_async`
- `pg_embedding_worker`
- `async_embedding`

---

## Benefits

1. **Complete Pipeline**: Document → Chunks → Embeddings all in PostgreSQL
2. **Provider Flexibility**: Easy to switch between OpenAI, Anthropic, Ollama
3. **Async Processing**: Non-blocking embedding generation
4. **Automatic Chunking**: Multiple strategies (token, semantic, markdown, sentence)
5. **Batching Support**: Efficient API usage
6. **Monitoring**: Built-in stats and observability
7. **General Purpose**: Works with any table structure

---

## Open Questions

1. **Dimension flexibility**: Auto-detect embedding dimensions vs. require pre-created columns?
2. **Primary key assumption**: Support composite keys or other types beyond bigint?
3. **Transaction handling**: Handle rollbacks for eventual consistency?
4. **Cost tracking**: Track API costs per embedding for metered plans?
5. **Chunk updatability**: Should chunks be updatable independently or always regenerated from parent?
6. **Deletion strategy**: Cascade delete chunks or soft-delete for audit trail?
7. **Versioning**: Keep old chunks on document update or always replace?

---

## Next Steps

1. Implement core background worker with basic queue processing
2. Add provider abstraction layer with OpenAI support
3. Implement token-based chunking in C
4. Add SQL convenience functions
5. Implement batching support
6. Add monitoring and stats
7. Extend to additional providers (Anthropic, Ollama)
8. Implement advanced chunking strategies (markdown, semantic)
9. Add comprehensive documentation and examples
10. Performance testing and optimization

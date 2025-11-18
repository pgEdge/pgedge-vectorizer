# pgEdge Vectorizer

Asynchronous text chunking and vector embedding generation for PostgreSQL.

## Overview

pgEdge Vectorizer is a PostgreSQL extension that automatically chunks text content and generates vector embeddings using background workers. It provides a seamless integration between your PostgreSQL database and embedding providers like OpenAI, making it easy to build AI-powered search and retrieval applications.

## Features

- **Automatic Chunking**: Intelligently splits text into optimal-sized chunks
- **Async Processing**: Background workers handle embedding generation without blocking
- **Provider Abstraction**: Easy switching between OpenAI, Anthropic, and Ollama
- **Batching**: Efficient batch processing for better API usage
- **Retry Logic**: Automatic retry with exponential backoff
- **Monitoring**: Built-in views for queue and worker monitoring
- **Flexible Configuration**: Extensive GUC parameters for customization

## Quick Start

### Installation

```bash
# Install dependencies
sudo apt-get install postgresql-server-dev-all libcurl4-openssl-dev

# Install pgvector
# See: https://github.com/pgvector/pgvector

# Build and install
cd pgedge-vectorizer
make
sudo make install
```

### Configuration

Add to `postgresql.conf`:

```ini
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.provider = 'openai'
pgedge_vectorizer.api_key_file = '~/.pgedge-vectorizer-llm-api-key'
pgedge_vectorizer.model = 'text-embedding-3-small'
pgedge_vectorizer.databases = 'mydb'  # Comma-separated list of databases to monitor
```

Create API key file:

```bash
echo "your-api-key" > ~/.pgedge-vectorizer-llm-api-key
chmod 600 ~/.pgedge-vectorizer-llm-api-key
```

Restart PostgreSQL and create extension:

```sql
CREATE EXTENSION vector;
CREATE EXTENSION pgedge_vectorizer;
```

### Basic Usage

```sql
-- Create a table
CREATE TABLE documents (
    id BIGSERIAL PRIMARY KEY,
    content TEXT
);

-- Enable vectorization
SELECT pgedge_vectorizer.enable_vectorization(
    'documents',
    'content'
);

-- Insert data - automatically chunked and vectorized
INSERT INTO documents (content)
VALUES ('Your text content here...');

-- Query similar content
SELECT
    d.id,
    c.content,
    c.embedding <=> '[...]'::vector AS distance
FROM documents d
JOIN documents_content_chunks c ON d.id = c.source_id
ORDER BY distance
LIMIT 5;
```

## Configuration

### Provider Settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| `pgedge_vectorizer.provider` | `openai` | Embedding provider |
| `pgedge_vectorizer.api_key_file` | `~/.pgedge-vectorizer-llm-api-key` | API key file path |
| `pgedge_vectorizer.api_url` | `https://api.openai.com/v1` | API endpoint |
| `pgedge_vectorizer.model` | `text-embedding-3-small` | Model name |

### Worker Settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| `pgedge_vectorizer.num_workers` | `2` | Number of workers (requires restart) |
| `pgedge_vectorizer.databases` | (empty) | Comma-separated list of databases to monitor |
| `pgedge_vectorizer.batch_size` | `10` | Batch size for embeddings |
| `pgedge_vectorizer.max_retries` | `3` | Max retry attempts |
| `pgedge_vectorizer.worker_poll_interval` | `1000` | Poll interval in ms |

### Chunking Settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| `pgedge_vectorizer.auto_chunk` | `true` | Enable auto-chunking |
| `pgedge_vectorizer.default_chunk_strategy` | `token_based` | Chunking strategy |
| `pgedge_vectorizer.default_chunk_size` | `400` | Chunk size in tokens |
| `pgedge_vectorizer.default_chunk_overlap` | `50` | Overlap in tokens |
| `pgedge_vectorizer.strip_non_ascii` | `true` | Strip non-ASCII characters (emoji, box-drawing, etc.) |

## API Reference

### Functions

#### enable_vectorization()

Enable automatic vectorization for a table column.

```sql
SELECT pgedge_vectorizer.enable_vectorization(
    source_table REGCLASS,
    source_column NAME,
    chunk_strategy TEXT DEFAULT NULL,
    chunk_size INT DEFAULT NULL,
    chunk_overlap INT DEFAULT NULL,
    embedding_dimension INT DEFAULT 1536,
    chunk_table_name TEXT DEFAULT NULL
);
```

**Parameters:**

- `source_table`: Table to vectorize
- `source_column`: Column containing text
- `chunk_strategy`: Chunking method (token_based, semantic, markdown)
- `chunk_size`: Target chunk size in tokens
- `chunk_overlap`: Overlap between chunks in tokens
- `embedding_dimension`: Vector dimension (default 1536 for OpenAI)
- `chunk_table_name`: Custom chunk table name (default: `{table}_{column}_chunks`)

**Behavior:**

- Creates chunk table, indexes, and trigger automatically
- **Automatically processes all existing rows** with non-empty content
- Future INSERT/UPDATE operations will be automatically vectorized
- Multiple columns can be vectorized independently on the same table

**Content Handling:**

- **Whitespace trimming**: Leading and trailing whitespace is automatically trimmed before processing
- **Empty content**: NULL, empty strings, or whitespace-only content will not create chunks
- **Updates to empty**: When content is updated to NULL or empty, existing chunks are deleted
- **Unchanged content**: UPDATE operations with identical content are skipped for efficiency
- **Multiple columns**: Each column gets its own chunk table (`{table}_{column}_chunks`) and trigger

#### disable_vectorization()

Disable vectorization for a table column.

```sql
SELECT pgedge_vectorizer.disable_vectorization(
    source_table REGCLASS,
    source_column NAME DEFAULT NULL,
    drop_chunk_table BOOLEAN DEFAULT FALSE
);
```

**Parameters:**

- `source_table`: Table to disable vectorization on
- `source_column`: Column to disable (NULL = disable all columns)
- `drop_chunk_table`: Whether to drop the chunk table

#### chunk_text()

Manually chunk text content.

```sql
SELECT pgedge_vectorizer.chunk_text(
    content TEXT,
    strategy TEXT DEFAULT NULL,
    chunk_size INT DEFAULT NULL,
    overlap INT DEFAULT NULL
);
```

Returns: `TEXT[]` array of chunks

#### retry_failed()

Retry failed queue items.

```sql
SELECT pgedge_vectorizer.retry_failed(
    max_age_hours INT DEFAULT 24
);
```

Returns: Number of items reset to pending

#### clear_completed()

Remove old completed items from queue.

```sql
SELECT pgedge_vectorizer.clear_completed(
    older_than_hours INT DEFAULT 24
);
```

Returns: Number of items deleted

#### reprocess_chunks()

Queue existing chunks without embeddings for processing.

```sql
SELECT pgedge_vectorizer.reprocess_chunks(
    chunk_table_name TEXT
);
```

**Parameters:**

- `chunk_table_name`: Name of the chunk table to reprocess

Returns: Number of chunks queued

**Example:**
```sql
-- Reprocess chunks that don't have embeddings yet
SELECT pgedge_vectorizer.reprocess_chunks('product_docs_content_chunks');
```

#### recreate_chunks()

Delete all chunks and recreate from source table (complete rebuild).

```sql
SELECT pgedge_vectorizer.recreate_chunks(
    source_table_name REGCLASS,
    source_column_name NAME
);
```

**Parameters:**

- `source_table_name`: Source table with the original data
- `source_column_name`: Column that was vectorized

Returns: Number of source rows processed

**Example:**
```sql
-- Completely rebuild all chunks and embeddings
SELECT pgedge_vectorizer.recreate_chunks('product_docs', 'content');
```

**Note:** This function deletes all existing chunks and queue items, then triggers re-chunking and re-embedding for all rows. Use with caution.

#### show_config()

Display all pgedge_vectorizer configuration settings.

```sql
SELECT * FROM pgedge_vectorizer.show_config();
```

Returns a table with `setting` and `value` columns showing all GUC parameters.

### Views

#### queue_status

Summary of queue items by status.

```sql
SELECT * FROM pgedge_vectorizer.queue_status;
```

Columns:

- `chunk_table`: Table name
- `status`: Item status
- `count`: Number of items
- `oldest`: Oldest item timestamp
- `newest`: Newest item timestamp
- `avg_processing_time_secs`: Average processing time

#### failed_items

Failed items with error details.

```sql
SELECT * FROM pgedge_vectorizer.failed_items;
```

#### pending_count

Count of pending items.

```sql
SELECT * FROM pgedge_vectorizer.pending_count;
```

## Monitoring

### Check Queue Status

```sql
-- Overall status
SELECT * FROM pgedge_vectorizer.queue_status;

-- Pending items
SELECT * FROM pgedge_vectorizer.pending_count;

-- Failed items with errors
SELECT * FROM pgedge_vectorizer.failed_items;
```

### Check Configuration

```sql
SELECT * FROM pgedge_vectorizer.show_config();
```

### PostgreSQL Logs

Workers log to PostgreSQL's standard log:

```bash
tail -f /var/log/postgresql/postgresql-*.log | grep pgedge_vectorizer
```

## Troubleshooting

### Workers Not Starting

1. Verify `shared_preload_libraries`:
```sql
SHOW shared_preload_libraries;
```

2. Check PostgreSQL logs for errors

3. Ensure proper permissions on API key file

### Slow Processing

1. Increase workers:
```sql
ALTER SYSTEM SET pgedge_vectorizer.num_workers = 4;
-- Requires restart
```

2. Increase batch size:
```sql
ALTER SYSTEM SET pgedge_vectorizer.batch_size = 20;
SELECT pg_reload_conf();
```

### Failed Embeddings

1. Check API key is valid
2. Verify network connectivity
3. Review error messages:
```sql
SELECT * FROM pgedge_vectorizer.failed_items;
```

4. Retry failed items:
```sql
SELECT pgedge_vectorizer.retry_failed();
```

## Best Practices

### Chunking

- **Size**: 200-500 tokens works well for most use cases
- **Overlap**: 10-20% overlap (50-100 tokens) provides good context
- **Strategy**: Use token_based for general purpose, markdown for structured docs

### Performance

- **Batching**: Larger batches (10-50) are more efficient
- **Workers**: Match worker count to your API rate limits
- **Cleanup**: Regularly clear completed items to keep queue small

### API Usage

- **Rate Limits**: Be aware of provider rate limits
- **Costs**: Monitor API usage, especially with large datasets
- **Keys**: Keep API keys secure, use proper file permissions (600)

### Data Management

- **Empty Content**: NULL, empty, and whitespace-only content is automatically skipped
- **Reprocessing**: Use `reprocess_chunks()` to queue existing chunks without embeddings
- **Full Rebuild**: Use `recreate_chunks()` for complete chunk regeneration (deletes all existing chunks)
- **Multiple Columns**: Each column gets independent chunk tables and triggers - disable selectively as needed

## Examples

### Example 1: Blog Posts

```sql
CREATE TABLE blog_posts (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,
    published_at TIMESTAMPTZ
);

SELECT pgedge_vectorizer.enable_vectorization(
    'blog_posts',
    'content',
    chunk_size := 500,
    chunk_overlap := 75
);

INSERT INTO blog_posts (title, content)
VALUES ('My Blog Post', 'Content here...');
```

### Example 2: Product Documentation

```sql
CREATE TABLE documentation (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    markdown_content TEXT,
    version TEXT
);

SELECT pgedge_vectorizer.enable_vectorization(
    'documentation',
    'markdown_content',
    chunk_strategy := 'markdown',
    chunk_size := 600
);
```

### Example 3: Customer Support Tickets

```sql
CREATE TABLE support_tickets (
    id BIGSERIAL PRIMARY KEY,
    subject TEXT,
    description TEXT,
    status TEXT
);

SELECT pgedge_vectorizer.enable_vectorization(
    'support_tickets',
    'description',
    chunk_size := 300,
    chunk_overlap := 50
);
```

### Example 4: Multi-Column Vectorization

```sql
CREATE TABLE articles (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    summary TEXT,
    content TEXT
);

-- Vectorize title with smaller chunks
SELECT pgedge_vectorizer.enable_vectorization(
    'articles',
    'title',
    chunk_size := 100,
    chunk_overlap := 10
);

-- Vectorize content with larger chunks
SELECT pgedge_vectorizer.enable_vectorization(
    'articles',
    'content',
    chunk_size := 500,
    chunk_overlap := 75
);

-- Query results:
-- - articles_title_chunks table with title embeddings
-- - articles_content_chunks table with content embeddings
-- - Each column operates independently
```

## Architecture

### Processing Flow

1. **Trigger**: Detects INSERT/UPDATE on configured table
2. **Chunking**: Splits text into chunks using configured strategy
3. **Queue**: Inserts chunk records and queue items
4. **Workers**: Pick up queue items using SKIP LOCKED
5. **Provider**: Generates embeddings via API
6. **Storage**: Updates chunk table with embeddings

### Component Diagram

```
┌─────────────┐
│ Source Table│
└──────┬──────┘
       │ Trigger
       ↓
┌──────────────┐
│   Chunking   │
└──────┬───────┘
       ↓
┌──────────────┐     ┌─────────────┐
│ Chunk Table  │←────┤    Queue    │
└──────────────┘     └──────┬──────┘
       ↑                    │
       │              ┌─────┴──────┐
       │              │  Worker 1  │
       │              │  Worker 2  │
       │              │  Worker N  │
       │              └─────┬──────┘
       │                    │
       │              ┌─────┴──────┐
       └──────────────┤  Provider  │
                      │  (OpenAI)  │
                      └────────────┘
```

## Testing

### Running Tests

The extension includes a comprehensive test suite using PostgreSQL's pg_regress framework:

```bash
# Build and install the extension first
make
make install

# Run all tests
make installcheck
```

### Test Coverage

The test suite includes 9 test files covering all functionality:

1. **setup** - Extension installation and configuration
2. **chunking** - Text chunking with various content sizes
3. **queue** - Queue table and monitoring views
4. **vectorization** - Basic enable/disable functionality
5. **multi_column** - Multiple columns on the same table
6. **maintenance** - reprocess_chunks() and recreate_chunks() functions
7. **edge_cases** - Empty, NULL, and whitespace handling
8. **worker** - Background worker configuration
9. **cleanup** - Queue cleanup functions

### Test Requirements

- PostgreSQL 14+ (tests run on installed version)
- `vector` extension must be installed
- Extension must be built and installed before running tests

## License

PostgreSQL License

Copyright (c) 2025, pgEdge, Inc.

## Support

- **GitHub**: https://github.com/pgEdge/pgedge-vectorizer
- **Issues**: https://github.com/pgEdge/pgedge-vectorizer/issues
- **Documentation**: https://pgedge.github.io/pgedge-vectorizer

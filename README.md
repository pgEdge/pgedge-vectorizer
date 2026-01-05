# pgEdge Vectorizer

[![CI](https://github.com/pgEdge/pgedge-vectorizer/actions/workflows/ci.yml/badge.svg)](https://github.com/pgEdge/pgedge-vectorizer/actions/workflows/ci.yml)
[![PostgreSQL 14+](https://img.shields.io/badge/PostgreSQL-14%2B-blue.svg)](https://www.postgresql.org/)
[![License](https://img.shields.io/badge/License-PostgreSQL-blue.svg)](LICENSE.md)

A PostgreSQL extension for asynchronous text chunking and vector embedding generation.

## Overview

pgEdge Vectorizer automatically chunks text content and generates vector embeddings using background workers. It supports multiple embedding providers (OpenAI, Voyage AI, and Ollama) and provides a simple SQL interface for enabling vectorization on any table.

### Key Features

- **Automatic Chunking**: Intelligently splits text into chunks with configurable strategies
- **Async Processing**: Background workers process embeddings without blocking your application
- **Multiple Providers**: Support for OpenAI, Voyage AI, and Ollama (local embeddings)
- **Configurable**: Extensive GUC parameters for fine-tuning behavior
- **Batching**: Efficient batch processing of embeddings
- **Retry Logic**: Automatic retry with exponential backoff for failed embeddings
- **Monitoring**: Built-in views and functions for monitoring queue status

## Requirements

- PostgreSQL 14 or later
- [pgvector](https://github.com/pgvector/pgvector) extension
- libcurl development files
- API key (for OpenAI or Voyage AI providers; not needed for Ollama)

## Installation

### 1. Install Dependencies

**Ubuntu/Debian:**
```bash
sudo apt-get install postgresql-server-dev-all libcurl4-openssl-dev
```

**macOS (Homebrew):**
```bash
brew install postgresql curl
```

### 2. Install pgvector

Follow the [pgvector installation instructions](https://github.com/pgvector/pgvector#installation).

### 3. Build and Install pgEdge Vectorizer

```bash
# Clone the repository
cd pgedge-vectorizer

# Build
make

# Install (may require sudo)
sudo make install
```

### 4. Configure PostgreSQL

Add to `postgresql.conf`:

```ini
shared_preload_libraries = 'pgedge_vectorizer'

# Provider configuration
pgedge_vectorizer.provider = 'openai'
pgedge_vectorizer.api_key_file = '/path/to/your/api_key_file'
pgedge_vectorizer.model = 'text-embedding-3-small'

# Worker configuration (optional)
pgedge_vectorizer.num_workers = 2
pgedge_vectorizer.batch_size = 10

# Chunking configuration (optional)
pgedge_vectorizer.default_chunk_size = 400
pgedge_vectorizer.default_chunk_overlap = 50
```

### 5. Create API Key File

Create a file containing only your API key:

```bash
echo "your-openai-api-key-here" > ~/.pgedge-vectorizer-llm-api-key
chmod 600 ~/.pgedge-vectorizer-llm-api-key
```

### 6. Restart PostgreSQL

```bash
sudo systemctl restart postgresql
# or
pg_ctl restart
```

### 7. Create Extension

```sql
CREATE EXTENSION vector;
CREATE EXTENSION pgedge_vectorizer;
```

## Quick Start

### Example: Vectorize a Documents Table

```sql
-- Create a documents table
CREATE TABLE articles (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,
    url TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable vectorization on the content column
SELECT pgedge_vectorizer.enable_vectorization(
    source_table := 'articles',
    source_column := 'content',
    chunk_strategy := 'token_based',
    chunk_size := 400,
    chunk_overlap := 50
);

-- Insert a document - it will be automatically chunked and vectorized
INSERT INTO articles (title, content, url)
VALUES (
    'Introduction to PostgreSQL',
    'PostgreSQL is a powerful, open source object-relational database system...',
    'https://example.com/postgres-intro'
);

-- Check queue status
SELECT * FROM pgedge_vectorizer.queue_status;

-- Wait for background workers to process...

-- Query for similar content
SELECT
    a.title,
    c.content,
    c.embedding <=> '[0.1, 0.2, ...]'::vector AS distance
FROM articles a
JOIN articles_content_chunks c ON a.id = c.source_id
ORDER BY distance
LIMIT 5;
```

## Configuration Parameters

All configuration parameters can be set in `postgresql.conf` or via `ALTER SYSTEM`.

### Provider Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `pgedge_vectorizer.provider` | string | `'openai'` | Embedding provider (openai, voyage, ollama) |
| `pgedge_vectorizer.api_key_file` | string | `'~/.pgedge-vectorizer-llm-api-key'` | Path to API key file |
| `pgedge_vectorizer.api_url` | string | `'https://api.openai.com/v1'` | API endpoint URL |
| `pgedge_vectorizer.model` | string | `'text-embedding-3-small'` | Embedding model name |

### Worker Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `pgedge_vectorizer.num_workers` | integer | `2` | Number of background workers (requires restart) |
| `pgedge_vectorizer.batch_size` | integer | `10` | Batch size for embedding generation |
| `pgedge_vectorizer.max_retries` | integer | `3` | Maximum retry attempts for failed embeddings |
| `pgedge_vectorizer.worker_poll_interval` | integer | `1000` | Worker polling interval in milliseconds |

### Chunking Configuration

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `pgedge_vectorizer.auto_chunk` | boolean | `true` | Enable automatic chunking |
| `pgedge_vectorizer.default_chunk_strategy` | string | `'token_based'` | Default chunking strategy |
| `pgedge_vectorizer.default_chunk_size` | integer | `400` | Default chunk size in tokens |
| `pgedge_vectorizer.default_chunk_overlap` | integer | `50` | Default chunk overlap in tokens |

### Queue Management

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `pgedge_vectorizer.auto_cleanup_hours` | integer | `24` | Automatically delete completed queue items older than this many hours. Set to 0 to disable automatic cleanup. |

## SQL API Reference

### Functions

#### `enable_vectorization()`

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

#### `disable_vectorization()`

Disable vectorization for a table.

```sql
SELECT pgedge_vectorizer.disable_vectorization(
    source_table REGCLASS,
    drop_chunk_table BOOLEAN DEFAULT FALSE
);
```

#### `chunk_text()`

Manually chunk text.

```sql
SELECT pgedge_vectorizer.chunk_text(
    content TEXT,
    strategy TEXT DEFAULT NULL,
    chunk_size INT DEFAULT NULL,
    overlap INT DEFAULT NULL
);
```

#### `retry_failed()`

Retry failed queue items.

```sql
SELECT pgedge_vectorizer.retry_failed(
    max_age_hours INT DEFAULT 24
);
```

#### `clear_completed()`

Remove old completed items from the queue.

```sql
SELECT pgedge_vectorizer.clear_completed(
    older_than_hours INT DEFAULT 24
);
```

**Note:** Workers automatically clean up completed items based on `pgedge_vectorizer.auto_cleanup_hours` (default 24 hours). Manual cleanup is only needed if you want to clean up more frequently or if automatic cleanup is disabled (set to 0).

#### `show_config()`

Show all configuration settings.

```sql
SELECT * FROM pgedge_vectorizer.show_config();
```

### Views

#### `queue_status`

Summary of queue items by table and status.

```sql
SELECT * FROM pgedge_vectorizer.queue_status;
```

#### `failed_items`

Failed queue items with error details.

```sql
SELECT * FROM pgedge_vectorizer.failed_items;
```

#### `pending_count`

Count of pending items.

```sql
SELECT * FROM pgedge_vectorizer.pending_count;
```

## Architecture

### Components

1. **Triggers**: Automatically detect changes to configured columns
2. **Chunking Engine**: Splits text into optimal-sized chunks
3. **Queue Table**: Stores pending embedding tasks
4. **Background Workers**: Process queue items asynchronously
5. **Provider Interface**: Abstraction layer for different embedding APIs
6. **Chunk Tables**: Store chunks and their embeddings

### Processing Flow

```
INSERT/UPDATE → Trigger → Chunk Text → Insert Chunks → Queue Items
                                                           ↓
                                                     Background Worker
                                                           ↓
                                                   Generate Embeddings
                                                           ↓
                                                   Update Chunk Tables
```

## Monitoring

### Check Queue Status

```sql
-- Overall status
SELECT * FROM pgedge_vectorizer.queue_status;

-- Pending items
SELECT * FROM pgedge_vectorizer.pending_count;

-- Failed items
SELECT * FROM pgedge_vectorizer.failed_items;
```

### Check Configuration

```sql
SELECT * FROM pgedge_vectorizer.show_config();
```

### Manual Queue Inspection

```sql
SELECT id, chunk_table, status, attempts, error_message, created_at
FROM pgedge_vectorizer.queue
WHERE status = 'failed'
ORDER BY created_at DESC
LIMIT 10;
```

## Troubleshooting

### Workers Not Starting

Check PostgreSQL logs:
```bash
tail -f /var/log/postgresql/postgresql-*.log
```

Verify `shared_preload_libraries`:
```sql
SHOW shared_preload_libraries;
```

### Embeddings Not Generated

1. Check API key file exists and is readable
2. Verify provider configuration
3. Check queue for errors:
```sql
SELECT * FROM pgedge_vectorizer.failed_items;
```

### Slow Processing

1. Increase number of workers:
```sql
ALTER SYSTEM SET pgedge_vectorizer.num_workers = 4;
-- Restart required
```

2. Increase batch size:
```sql
ALTER SYSTEM SET pgedge_vectorizer.batch_size = 20;
SELECT pg_reload_conf();
```

## Performance Tips

1. **Batch Size**: Larger batches (10-50) are more efficient for API calls
2. **Worker Count**: Match to your API rate limits and server capacity
3. **Chunk Size**: 200-500 tokens is optimal for most use cases
4. **Overlap**: 10-20% overlap provides good context without too much duplication

## Development

### Building from Source

```bash
make clean
make
make install
```

### Running Tests

The extension includes a comprehensive test suite with 9 test files covering all functionality:

```bash
make installcheck
```

Tests cover:

- Extension installation and configuration
- Text chunking with various strategies
- Queue management and monitoring views
- Vectorization enable/disable
- Multi-column vectorization
- Maintenance functions (reprocess, recreate)
- Edge cases (empty, NULL, whitespace handling)
- Worker configuration

All tests must pass on PostgreSQL 14-18 before merging changes.

### Debugging

Enable debug logging:
```sql
SET client_min_messages = DEBUG1;
```

## Roadmap

- [x] Support for Voyage AI embedding models
- [x] Support for Ollama (local models)
- [ ] Semantic chunking strategy
- [ ] Markdown-aware chunking
- [ ] Sentence-based chunking
- [ ] Integration with tiktoken for accurate token counting
- [ ] Cost tracking and quotas
- [ ] Multi-database support
- [ ] Custom embedding dimensions
- [ ] Webhook notifications

## License

PostgreSQL License (see LICENSE.md)

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

Quick checklist:

- All tests must pass (`make installcheck`)
- Code follows PostgreSQL conventions
- New features include tests
- Documentation is updated

## Support

For issues and questions:

- **GitHub**: https://github.com/pgEdge/pgedge-vectorizer
- **Issues**: https://github.com/pgEdge/pgedge-vectorizer/issues
- **Documentation**: https://github.com/pgEdge/pgedge-vectorizer/blob/main/docs/index.md


## Credits

Developed by pgEdge, Inc.

Portions copyright (c) 2025 - 2026, pgEdge, Inc.

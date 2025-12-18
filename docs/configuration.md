# Configuration

pgEdge Vectorizer can be configured through PostgreSQL's GUC (Grand Unified Configuration) system. These settings control how the extension connects to embedding providers, manages background workers, processes text chunks, and maintains the processing queue. Most settings can be changed by any user and take effect after reloading the configuration with `pg_reload_conf()`, though some require a server restart.

## Provider Settings

These settings configure the connection to your embedding provider, including the API endpoint, authentication, and model selection.

| Parameter | Default | Description | Reload | Restart | Superuser |
|-----------|---------|-------------|--------|---------|-----------|
| `pgedge_vectorizer.provider` | `openai` | Embedding provider (openai, voyage, ollama) | No | No | No |
| `pgedge_vectorizer.api_key_file` | `~/.pgedge-vectorizer-llm-api-key` | API key file path (not needed for Ollama) | No | No | No |
| `pgedge_vectorizer.api_url` | `https://api.openai.com/v1` | API endpoint | No | No | No |
| `pgedge_vectorizer.model` | `text-embedding-3-small` | Model name | No | No | No |

## Worker Settings

These settings control the background workers that process the embedding queue, including concurrency, batch sizes, and retry behavior.

| Parameter | Default | Description | Reload | Restart | Superuser |
|-----------|---------|-------------|--------|---------|-----------|
| `pgedge_vectorizer.num_workers` | `2` | Number of workers | No | Yes | Yes |
| `pgedge_vectorizer.databases` | (empty) | Comma-separated list of databases to monitor | Yes | Yes | No |
| `pgedge_vectorizer.batch_size` | `10` | Batch size for embeddings | Yes | No | No |
| `pgedge_vectorizer.max_retries` | `3` | Max retry attempts | Yes | No | No |
| `pgedge_vectorizer.worker_poll_interval` | `1000` | Poll interval in ms | Yes | No | No |

## Chunking Settings

These settings determine how text content is split into chunks before embedding generation.

| Parameter | Default | Description | Reload | Restart | Superuser |
|-----------|---------|-------------|--------|---------|-----------|
| `pgedge_vectorizer.auto_chunk` | `true` | Enable auto-chunking | Yes | No | No |
| `pgedge_vectorizer.default_chunk_strategy` | `token_based` | Chunking strategy | Yes | No | No |
| `pgedge_vectorizer.default_chunk_size` | `400` | Chunk size in tokens | Yes | No | No |
| `pgedge_vectorizer.default_chunk_overlap` | `50` | Overlap in tokens | Yes | No | No |
| `pgedge_vectorizer.strip_non_ascii` | `true` | Strip non-ASCII characters (emoji, box-drawing, etc.) | Yes | No | No |

## Queue Management

These settings control automatic cleanup of completed queue items to prevent unbounded growth.

| Parameter | Default | Description | Reload | Restart | Superuser |
|-----------|---------|-------------|--------|---------|-----------|
| `pgedge_vectorizer.auto_cleanup_hours` | `24` | Automatically delete completed queue items older than this many hours. Set to 0 to disable. Workers clean up once per hour. | Yes | No | No |

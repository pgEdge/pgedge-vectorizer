# Configuration

## Provider Settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| `pgedge_vectorizer.provider` | `openai` | Embedding provider (openai, voyage, ollama) |
| `pgedge_vectorizer.api_key_file` | `~/.pgedge-vectorizer-llm-api-key` | API key file path (not needed for Ollama) |
| `pgedge_vectorizer.api_url` | `https://api.openai.com/v1` | API endpoint |
| `pgedge_vectorizer.model` | `text-embedding-3-small` | Model name |

## Worker Settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| `pgedge_vectorizer.num_workers` | `2` | Number of workers (requires restart) |
| `pgedge_vectorizer.databases` | (empty) | Comma-separated list of databases to monitor |
| `pgedge_vectorizer.batch_size` | `10` | Batch size for embeddings |
| `pgedge_vectorizer.max_retries` | `3` | Max retry attempts |
| `pgedge_vectorizer.worker_poll_interval` | `1000` | Poll interval in ms |

## Chunking Settings

| Parameter | Default | Description |
|-----------|---------|-------------|
| `pgedge_vectorizer.auto_chunk` | `true` | Enable auto-chunking |
| `pgedge_vectorizer.default_chunk_strategy` | `token_based` | Chunking strategy |
| `pgedge_vectorizer.default_chunk_size` | `400` | Chunk size in tokens |
| `pgedge_vectorizer.default_chunk_overlap` | `50` | Overlap in tokens |
| `pgedge_vectorizer.strip_non_ascii` | `true` | Strip non-ASCII characters (emoji, box-drawing, etc.) |

## Queue Management

| Parameter | Default | Description |
|-----------|---------|-------------|
| `pgedge_vectorizer.auto_cleanup_hours` | `24` | Automatically delete completed queue items older than this many hours. Set to 0 to disable. Workers clean up once per hour. |

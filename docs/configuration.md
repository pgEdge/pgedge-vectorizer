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

### Chunking Strategies

The `default_chunk_strategy` parameter accepts the following values:

| Strategy | Description |
|----------|-------------|
| `token_based` | Fixed token count chunking with overlap. Simple and fast. Default strategy. |
| `markdown` | Structure-aware chunking that respects markdown boundaries. Preserves heading context but without merge/split refinement. Good balance of structure awareness and simplicity. |
| `hybrid` | Full structure-aware chunking inspired by Docling. Parses markdown structure, preserves heading context, and applies two-pass refinement (split oversized, merge undersized). Best for RAG with structured documents. |

#### Automatic Fallback for Plain Text

Both `markdown` and `hybrid` strategies include **automatic fallback detection**. If the content doesn't appear to be markdown (no headings, code fences, lists, etc.), the chunker automatically falls back to `token_based` chunking. This ensures:

- No unnecessary overhead for plain text documents
- Consistent behavior regardless of content type
- Optimal chunking strategy is always used

Detection criteria (content is treated as markdown if it has):
- At least one heading (`# `, `## `, etc.)
- At least one code fence (` ``` ` or `~~~`)
- Or two or more of: lists, blockquotes, tables, links

#### Markdown Chunking Strategy

The `markdown` strategy provides structure-aware chunking with heading context:

1. **Parses markdown structure**: Recognizes headings, code blocks, lists, blockquotes, tables, and paragraphs
2. **Preserves heading context**: Each chunk includes its heading hierarchy (e.g., `[Context: # Chapter 1 > ## Section 1.1]`)
3. **Respects structure boundaries**: Doesn't split in the middle of code blocks or tables

This is simpler and faster than `hybrid` but may produce less optimal chunk sizes.

#### Hybrid Chunking Strategy

The `hybrid` strategy provides superior chunking for structured documents by:

1. **Parsing markdown structure**: Recognizes headings, code blocks, lists, blockquotes, tables, and paragraphs
2. **Preserving heading context**: Each chunk includes its heading hierarchy (e.g., `[Context: # Chapter 1 > ## Section 1.1]`)
3. **Two-pass refinement**:
   - Pass 1: Splits chunks that exceed the token limit at natural boundaries
   - Pass 2: Merges consecutive undersized chunks that share the same heading context

This approach significantly improves RAG retrieval accuracy by maintaining semantic context that would be lost with naive text splitting.

#### Choosing a Strategy

| Use Case | Recommended Strategy |
|----------|---------------------|
| Mixed content (markdown + plain text) | `hybrid` or `markdown` (auto-fallback handles plain text) |
| Structured documentation | `hybrid` (best retrieval quality) |
| Simple documents, speed priority | `token_based` |
| Code-heavy content | `markdown` or `hybrid` (preserves code blocks) |

Example usage:

```sql
-- Enable vectorization with hybrid chunking
SELECT pgedge_vectorizer.enable_vectorization(
    'documents',
    'content',
    chunk_strategy := 'hybrid',
    chunk_size := 400,
    chunk_overlap := 50
);

-- Or chunk text directly
SELECT * FROM unnest(
    pgedge_vectorizer.chunk_text(
        '# Introduction

This is the introduction.

## Background

More content here...',
        'hybrid',
        200,
        20
    )
);

-- Plain text automatically falls back to token-based
SELECT * FROM unnest(
    pgedge_vectorizer.chunk_text(
        'This plain text document will use token-based chunking automatically.',
        'hybrid',
        100,
        10
    )
);
```

## Queue Management

These settings control automatic cleanup of completed queue items to prevent unbounded growth.

| Parameter | Default | Description | Reload | Restart | Superuser |
|-----------|---------|-------------|--------|---------|-----------|
| `pgedge_vectorizer.auto_cleanup_hours` | `24` | Automatically delete completed queue items older than this many hours. Set to 0 to disable. Workers clean up once per hour. | Yes | No | No |

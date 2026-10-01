# Configuration

pgEdge Vectorizer can be configured through PostgreSQL's GUC (Grand Unified Configuration) system. These settings control how the extension connects to embedding providers, manages background workers, processes text chunks, and maintains the processing queue. Most settings can be changed by any user and take effect after reloading the configuration with `pg_reload_conf()`, though some require a server restart.

## Provider Settings

These settings configure the connection to your embedding provider, including the API endpoint, authentication, and model selection.

| Parameter | Default | Description | Reload | Restart | Superuser |
|-----------|---------|-------------|--------|---------|-----------|
| `pgedge_vectorizer.provider` | `openai` | Embedding provider (openai, voyage, ollama, gemini) | No | No | No |
| `pgedge_vectorizer.api_key_file` | `~/.pgedge-vectorizer-llm-api-key` | API key file path (not needed for Ollama; optional for OpenAI with custom URL) | No | No | No |
| `pgedge_vectorizer.api_url` | (empty) | API endpoint URL. Leave empty for provider defaults. Set for custom/local endpoints. | No | No | No |
| `pgedge_vectorizer.model` | `text-embedding-3-small` | Model name | No | No | No |
| `pgedge_vectorizer.extra_headers` | (empty) | Semicolon-separated `key: value` HTTP headers added to all API requests | No | No | No |

!!! warning "The model fixes the vector dimension of a chunk table"

    The model determines how many dimensions the provider returns, and
    `enable_vectorization()` fixes that number into the chunk table's
    `embedding vector(N)` column when the table is created. Changing
    `pgedge_vectorizer.model` to a model with a different dimension does
    not migrate an existing chunk table. The background worker compares
    the dimensions before writing, so nothing is corrupted, but it marks
    the affected queue items `failed` with the message
    `Dimension mismatch: model=N, table=M` and no new embeddings are
    stored for that table until you act. The
    [Troubleshooting](troubleshooting.md) document describes how to
    recover.

### Per-vectorizer provider and model

The settings above are the defaults for the whole database, which is the right
thing when every table wants the same embeddings, and the wrong thing when they
do not: a table of short product titles and a table of long technical documents
are rarely well served by one model, and you may want one table embedded
locally through Ollama whilst another goes to a hosted provider. A vectorizer
can therefore name its own provider and model, and falls back to the settings
above where it does not.

Pin them when the vectorizer is created:

```sql
SELECT pgedge_vectorizer.enable_vectorization(
    'articles'::regclass, 'body',
    provider => 'ollama',
    model    => 'nomic-embed-text'
);
```

Or change them afterwards with `set_embedding_model()`, which takes the model
first because that is the argument you usually want:

```sql
SELECT pgedge_vectorizer.set_embedding_model(
    'articles'::regclass, 'body', 'nomic-embed-text', provider => 'ollama');
```

Both settings live in `pgedge_vectorizer.vectorizers` as nullable columns,
where NULL means inherit. Inheritance is resolved when the work runs rather
than copied at creation, so a vectorizer that inherits follows the GUC as the
GUC changes.

`set_embedding_model()` always writes both columns to exactly what you pass,
and both default to NULL, so the shortest call resets both to inheriting:

```sql
-- Back to inheriting the provider and the model
SELECT pgedge_vectorizer.set_embedding_model('articles'::regclass, 'body', NULL);
```

That cuts both ways: to change only the model whilst keeping a pinned
provider, name the provider again, or it reverts to inheriting alongside the
model.

```sql
-- Keep the pinned provider, change only the model
SELECT pgedge_vectorizer.set_embedding_model(
    'articles'::regclass, 'body', 'mxbai-embed-large', provider => 'ollama');
```

Either call needs `force_reembed => true` if the vectorizer already has
embeddings and the effective model actually moves, in which case every
embedding is cleared and every chunk requeued. Where the effective model does
not move, because the value passed matches what was already in force, nothing
is requeued and no flag is needed. See
[Best Practices](best_practices.md) for what a re-embed costs and why the
refusal is not limited to changes of dimension.

!!! warning "Changing the GUC still moves every inheriting vectorizer"

    The refusal above protects a vectorizer that has pinned its model. A
    vectorizer that inherits has not, so changing
    `pgedge_vectorizer.model` globally re-points every inheriting table at
    once, with no guard and no re-embed, exactly as it did before this
    setting existed. Pin the model on any vectorizer whose embeddings
    matter.

    Where it has already happened, it is at least visible and repairable:
    `embedding_model_status()` reports what each chunk table is a mixture
    of, and `reembed()` redoes the chunks that are not current. See
    [Seeing what a table was embedded with](#seeing-what-a-table-was-embedded-with).

### Seeing what a table was embedded with

Every chunk records the provider and model that produced its vector, so a
disagreement between that and what the vectorizer would use now is visible
rather than something you discover through poor search results:

```sql
SELECT * FROM pgedge_vectorizer.embedding_model_status('articles'::regclass);
```

```
source_table         | articles
source_column        | body
effective_provider   | openai
effective_model      | text-embedding-3-large
chunks_embedded      | 12043
chunks_current       | 9945
chunks_other_model   | 2098
chunks_model_unknown | 0
embedded_models      | {openai/text-embedding-3-large,openai/text-embedding-3-small}
```

`chunks_other_model` is the count that matters: those rows hold vectors from a
different model, and similarity between two models' vectors is meaningless, so
they are effectively invisible to search rather than merely stale.
`chunks_model_unknown` counts rows embedded before this was recorded, which is
every row on an installation that has just upgraded; they may well be current,
so they are reported separately rather than assumed wrong.

To repair it:

```sql
SELECT pgedge_vectorizer.reembed('articles'::regclass, 'body');
```

That clears and requeues everything not known to have come from the provider
and model the vectorizer would use now, which includes the unknown rows, since
a row that cannot be shown to be current is one that needs doing again. Rows
that are already current are left alone, unless the new model is a different
width, in which case the column has to be altered and every chunk goes with it.
Chunks, token counts, sparse embeddings and the BM25 statistics are untouched
throughout, because none of them depends on the embedding model.

Both functions scan the chunk table, so give them a source table rather than
running them across every vectorizer out of habit.

## Worker Settings

These settings control the background workers that process the embedding queue, including concurrency, batch sizes, and retry behavior.

| Parameter | Default | Description | Reload | Restart | Superuser |
|-----------|---------|-------------|--------|---------|-----------|
| `pgedge_vectorizer.num_workers` | `2` | Maximum number of concurrent workers. Databases are serviced in rotation, so every configured database is processed even when there are more databases than workers | Yes | No | Yes |
| `pgedge_vectorizer.databases` | (empty) | **Required.** Comma-separated list of databases to monitor. Workers will not process any embeddings if this is not set. | Yes | No | No |
| `pgedge_vectorizer.worker_service_quantum` | `60s` | Seconds a worker services one database before yielding its slot, when there are more databases than workers. Ignored when every database can have its own worker | Yes | No | No |
| `pgedge_vectorizer.batch_size` | `10` | Batch size for embeddings | Yes | No | No |
| `pgedge_vectorizer.max_retries` | `3` | Max retry attempts before a queue item is marked `failed` | Yes | No | No |
| `pgedge_vectorizer.worker_poll_interval` | `1000` | Poll interval in ms | Yes | No | No |

## Chunking Settings

These settings determine how text content is split into chunks before embedding generation.

| Parameter | Default | Description | Reload | Restart | Superuser |
|-----------|---------|-------------|--------|---------|-----------|
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

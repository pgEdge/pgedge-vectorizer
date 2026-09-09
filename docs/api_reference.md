# API Reference

## Functions

### enable_vectorization()

Enable automatic vectorization for a table column.

```sql
SELECT pgedge_vectorizer.enable_vectorization(
    source_table REGCLASS,
    source_column NAME,
    chunk_strategy TEXT DEFAULT NULL,
    chunk_size INT DEFAULT NULL,
    chunk_overlap INT DEFAULT NULL,
    embedding_dimension INT DEFAULT NULL,
    chunk_table_name TEXT DEFAULT NULL,
    source_pk NAME DEFAULT NULL,
    provider TEXT DEFAULT NULL,
    model TEXT DEFAULT NULL
);
```

**Parameters:**

- `source_table`: Table to vectorize
- `source_column`: Column containing text
- `chunk_strategy`: Chunking method (token_based, semantic, markdown)
- `chunk_size`: Target chunk size in tokens
- `chunk_overlap`: Overlap between chunks in tokens
- `embedding_dimension`: Vector dimension. When NULL (the default), the dimension is auto-detected by making a probe call to the configured embedding provider/model. Can be set explicitly to override auto-detection.
- `chunk_table_name`: Custom chunk table name (default: `{table}_{column}_chunks`)
- `source_pk`: Primary key column to use as the document identifier in the chunk table. When NULL (the default), the primary key column name and type are auto-detected from the table's primary key index via `pg_index`. Set explicitly to use a specific column (e.g., `'external_id'`).
- `provider`: Embedding provider for this vectorizer. When NULL (the default), `pgedge_vectorizer.provider` is used, and continues to be used as it changes.
- `model`: Embedding model for this vectorizer. When NULL (the default), `pgedge_vectorizer.model` is used, and continues to be used as it changes. Where `embedding_dimension` is not given, the probe asks about this model rather than the configured one.

**Primary Key Handling:**

- **Auto-detection**: When `source_pk` is NULL, the primary key column name and type are detected from `pg_index`. The chunk table's `source_id` column is created with the matching type (e.g., `UUID`, `BIGINT`, `TEXT`, `VARCHAR(26)`).
- **Supported types**: Any single-column primary key type — `UUID`, `BIGSERIAL`/`BIGINT`, `SERIAL`/`INTEGER`, `TEXT`, `VARCHAR(n)`, etc.
- **Composite keys**: Auto-detection does not support composite (multi-column) primary keys. However, you can vectorize a composite-PK table by passing `source_pk` to select one column explicitly (e.g., `source_pk := 'item_id'`).
- **No primary key**: Tables without a primary key must specify `source_pk` explicitly.
- **Override**: Pass `source_pk` to use a different column than the table's actual primary key (e.g., an `external_id UUID` column).
- **Uniqueness requirement**: The column specified by `source_pk` must contain globally unique values. The chunk table enforces a `UNIQUE(source_id, chunk_index)` constraint, so duplicate `source_pk` values will cause conflicts.

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

### disable_vectorization()

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

### refresh_triggers()

Recreate the DELETE and TRUNCATE cleanup triggers for every registered vectorizer.

```sql
SELECT pgedge_vectorizer.refresh_triggers();
```

**Returns:** the number of vectorized columns whose triggers were recreated.

Vectorization installs three triggers per column: one for INSERT and UPDATE, one for DELETE, and one for TRUNCATE. Upgrading the extension repairs tables that were vectorized before the cleanup triggers existed, so this function is not normally needed. Use it if a trigger has been dropped by hand, or on an installation that acquired its vectorized tables under a build predating the cleanup triggers and so will never run the relevant upgrade script.

Columns whose document identifier is not recorded in `pgedge_vectorizer.vectorizers` are skipped with a warning rather than guessed at; re-run `enable_vectorization()` for those.

### chunk_text()

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

### generate_embedding()

Generate an embedding vector from query text.

```sql
SELECT pgedge_vectorizer.generate_embedding(
    query_text TEXT,
    provider   TEXT DEFAULT NULL,
    model      TEXT DEFAULT NULL
);
```

**Parameters:**

- `query_text`: Text to generate an embedding for
- `provider`: Provider to use. NULL (the default) uses `pgedge_vectorizer.provider`.
- `model`: Model to use. NULL (the default) uses `pgedge_vectorizer.model`.

Returns: `vector` - The embedding vector

A query embedding must come from the same model as the embeddings it is
compared against, so name the model explicitly when searching a chunk table
whose vectorizer pins one. Vectors from two models are not comparable, and
nothing will report an error if you mix them.

**Example:**

```sql
-- Generate an embedding for a search query
SELECT
    d.id,
    c.content,
    c.embedding <=> pgedge_vectorizer.generate_embedding('machine learning tutorials') AS distance
FROM documents d
JOIN documents_content_chunks c ON d.id = c.source_id
ORDER BY distance
LIMIT 5;
```

**Note:** This function calls the embedding provider synchronously, so it will wait for the API response. For large-scale batch operations, use the automatic vectorization features instead.

### detect_embedding_dimension()

Detect the embedding dimension of a provider and model.

```sql
SELECT pgedge_vectorizer.detect_embedding_dimension(
    provider TEXT DEFAULT NULL,
    model    TEXT DEFAULT NULL
);
```

**Parameters:**

- `provider`: Provider to probe. NULL (the default) uses `pgedge_vectorizer.provider`.
- `model`: Model to probe. NULL (the default) uses `pgedge_vectorizer.model`.

Returns: `INT` - The number of dimensions in the embedding vector

This function generates a probe embedding and returns the dimension of the result, which means a real request to the provider. It is called automatically by `enable_vectorization()` and `set_embedding_model()` when `embedding_dimension` is not specified.

### set_embedding_model()

Change the embedding provider and model for one vectorizer.

```sql
SELECT pgedge_vectorizer.set_embedding_model(
    source_table        REGCLASS,
    source_column       NAME,
    model               TEXT,
    provider            TEXT DEFAULT NULL,
    embedding_dimension INT DEFAULT NULL,
    force_reembed       BOOLEAN DEFAULT FALSE
);
```

**Parameters:**

- `source_table`, `source_column`: The vectorizer to change
- `model`: Model to use. NULL means inherit `pgedge_vectorizer.model`.
- `provider`: Provider to use. NULL means inherit `pgedge_vectorizer.provider`.
- `embedding_dimension`: Dimension of the new model. When NULL (the default), the new provider and model are probed for it, which is a real request. The chunk table's vector column is altered to match whether or not the vectorizer has any chunks yet, since a column left at the old width would fail every embedding written afterwards.
- `force_reembed`: Whether to clear the existing embeddings and requeue every chunk. Required to change a vectorizer that has any chunks.

Returns: `BIGINT` - The number of chunks requeued, which is zero unless the re-embed ran

Both columns are written to exactly what you pass, NULL included, so this is also how a vectorizer goes back to inheriting the GUCs. Where the effective provider and model do not actually change, nothing is requeued.

Changing a vectorizer that has chunks raises an error unless `force_reembed` is true. With it, every `embedding` is set to NULL, the column's dimension is altered if the new model differs, the vectorizer's queue rows are cleared and every chunk is requeued, all in one transaction. Chunk rows, their token counts, their sparse embeddings and the BM25 statistics are left alone, because none of them depends on the embedding model.

The refusal triggers on the model changing rather than on the dimension changing. See [Best Practices](best_practices.md) for why, and for what a re-embed costs.

**Example:**

```sql
-- Move one table to a local model, re-embedding what is already there
SELECT pgedge_vectorizer.set_embedding_model(
    'articles'::regclass, 'body', 'nomic-embed-text',
    provider      => 'ollama',
    force_reembed => true
);
```

### embedding_model_status()

Report which provider and model each vectorizer's chunks were actually embedded
with, and where that disagrees with what it would use now.

```sql
SELECT * FROM pgedge_vectorizer.embedding_model_status(
    source_table  REGCLASS DEFAULT NULL,
    source_column NAME DEFAULT NULL
);
```

**Parameters:** both optional, narrowing the result to one source table or one
column of it. With neither, every registered vectorizer is reported.

Columns:

- `source_table`, `source_column`, `chunk_table`: The vectorizer, as registered
- `effective_provider`, `effective_model`: What it would use now, inheritance
  resolved
- `chunks_embedded`: Chunks with a vector. Every count below is a subset of
  this one; a chunk with no vector has no model to disagree about and is
  excluded throughout
- `chunks_current`: Embedded by the effective provider and model
- `chunks_other_model`: Embedded by something else. Vectors from two models are
  not comparable, so these rows are effectively invisible to search
- `chunks_model_unknown`: Embedded before the extension recorded this, which is
  every row on an installation that has just upgraded. Reported apart from a
  mismatch because they may well be current
- `embedded_models`: The distinct `provider/model` pairs actually present,
  ordered

Each row scans a chunk table, so this costs considerably more than the queue
views. A chunk table that has been dropped, or that the caller cannot read,
gives NULL counts rather than failing the whole result set.

### reembed()

Re-embed a vectorizer's chunks with the provider and model it would use now.

```sql
SELECT pgedge_vectorizer.reembed(
    source_table        REGCLASS,
    source_column       NAME,
    embedding_dimension INT DEFAULT NULL
);
```

**Parameters:**

- `source_table`, `source_column`: The vectorizer to repair
- `embedding_dimension`: Dimension of the effective model. When NULL (the
  default) the provider is probed for it, which is a real request

Returns: `BIGINT` - The number of chunks queued

Clears and requeues every chunk not known to have been produced by the
effective provider and model, which includes chunks with nothing recorded:
a row that cannot be shown to be current is treated as needing doing again, so
the first call on a freshly upgraded installation re-embeds the whole table.
Chunks already current are left alone.

If the effective model is a different width from the chunk table's vector
column, that distinction cannot hold: the column is altered and every chunk is
requeued, since a column cannot carry two widths. A notice says so.

Chunk rows, token counts, sparse embeddings and the BM25 statistics are
untouched either way, because none of them depends on the embedding model.

Unlike `set_embedding_model()`, there is no confirmation flag: this function
does what its name says. It does spend money against a metered provider, and
raises a notice with the count for that reason.

This is the supported repair for a vectorizer that drifted because
`pgedge_vectorizer.model` changed under it. `set_embedding_model()` will not do
it, because an inheriting vectorizer's effective model already is the new one,
so from that function's point of view nothing has changed.

### retry_failed()

Retry failed queue items.

```sql
SELECT pgedge_vectorizer.retry_failed(
    max_age_hours INT DEFAULT 24
);
```

Returns: Number of items reset to pending

### clear_completed()

Remove old completed items from queue.

```sql
SELECT pgedge_vectorizer.clear_completed(
    older_than_hours INT DEFAULT 24
);
```

Returns: Number of items deleted

**Note:** Workers automatically clean up completed items based on `pgedge_vectorizer.auto_cleanup_hours`. Manual cleanup is only needed if you want to clean up more frequently or if automatic cleanup is disabled.

### reprocess_chunks()

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

### recreate_chunks()

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

### hybrid_search()

Run a hybrid BM25 + dense vector search and merge results with Reciprocal Rank
Fusion (RRF). Requires `pgedge_vectorizer.enable_hybrid = true`.

```sql
SELECT * FROM pgedge_vectorizer.hybrid_search(
    p_source_table   REGCLASS,
    p_query          TEXT,
    p_limit          INT     DEFAULT 10,
    p_alpha          FLOAT8  DEFAULT 0.7,
    p_rrf_k          INT     DEFAULT 60,
    p_source_column  NAME    DEFAULT NULL
);
```

**Parameters:**

- `p_source_table`: The source table that was vectorized
- `p_query`: Search query text
- `p_limit`: Maximum number of results to return
- `p_alpha`: Balance between dense and sparse results (`0.0` = pure keyword,
  `1.0` = pure semantic, `0.7` = default)
- `p_rrf_k`: RRF smoothing constant (higher values reduce the influence of
  rank position)
- `p_source_column`: Source column name. Required when a table has multiple
  vectorized columns; optional otherwise

Returns a table with columns:

- `source_id` (`TEXT`): Primary key of the source row (cast to text for
  compatibility with all PK types)
- `chunk` (`TEXT`): The matching text chunk
- `dense_rank` (`INT`): Rank from dense vector search (9999 if not found)
- `sparse_rank` (`INT`): Rank from BM25 keyword search (9999 if not found)
- `rrf_score` (`FLOAT8`): Combined RRF score (higher is better)

**Example:**

```sql
SELECT source_id, chunk, dense_rank, sparse_rank, rrf_score
FROM pgedge_vectorizer.hybrid_search(
    p_source_table := 'articles'::regclass,
    p_query        := 'PostgreSQL replication',
    p_limit        := 5,
    p_alpha        := 0.7
);
```

### hybrid_search_simple()

Convenience wrapper around `hybrid_search()` that returns only the source ID,
chunk text, and combined score.

```sql
SELECT * FROM pgedge_vectorizer.hybrid_search_simple(
    p_source_table  REGCLASS,
    p_query         TEXT,
    p_limit         INT  DEFAULT 10,
    p_source_column NAME DEFAULT NULL
);
```

Returns a table with columns: `source_id`, `chunk`, `rrf_score`.

**Example:**

```sql
SELECT * FROM pgedge_vectorizer.hybrid_search_simple(
    'articles'::regclass, 'PostgreSQL replication', 5
);
```

### bm25_query_vector()

Compute a BM25 sparse vector for a query string. Primarily used internally by
`hybrid_search()`, but available for advanced use cases.

```sql
SELECT pgedge_vectorizer.bm25_query_vector(
    query       TEXT,
    chunk_table TEXT
);
```

Returns: `sparsevec` -- A sparse vector of BM25 scores using IDF statistics
from the specified chunk table.

### bm25_avg_doc_len()

Return the average document length (in tokens) for a chunk table.

```sql
SELECT pgedge_vectorizer.bm25_avg_doc_len(chunk_table TEXT);
```

Returns: `FLOAT8`

### bm25_tokenize()

Tokenize text using the BM25 tokenizer (lowercase, remove stopwords,
deduplicate). Useful for debugging and testing.

```sql
SELECT pgedge_vectorizer.bm25_tokenize(query TEXT);
```

Returns: `TEXT[]` -- Array of distinct non-stopword terms.

### count_tokens()

Approximate the number of tokens in a piece of text. This is the same estimate
the chunking engine uses when it decides where a chunk ends, and it is what
gets stored in the `token_count` column of a chunk table, so it is useful for
working out why a given piece of text chunked the way it did.

```sql
SELECT pgedge_vectorizer.count_tokens(content TEXT);
```

Returns: `INT` -- The estimated token count, or `NULL` for `NULL` input.

The estimate counts UTF-8 characters and divides by four, rounding up, which
is a reasonable rule of thumb for English prose but no more than that: text
that tokenises unusually, such as code, dense punctuation or languages other
than English, will be some way out. Do not use it where an exact count
matters, such as checking a payload against a provider's hard token limit.

### show_config()

Display all pgedge_vectorizer configuration settings.

```sql
SELECT * FROM pgedge_vectorizer.show_config();
```

Returns a table with `setting` and `value` columns showing all GUC parameters.

## Views

### queue_status

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

### failed_items

Failed items with error details.

```sql
SELECT * FROM pgedge_vectorizer.failed_items;
```

### pending_count

Count of pending items.

```sql
SELECT * FROM pgedge_vectorizer.pending_count;
```

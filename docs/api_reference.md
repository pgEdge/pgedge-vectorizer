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
    source_pk NAME DEFAULT NULL
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
    query_text TEXT
);
```

**Parameters:**

- `query_text`: Text to generate an embedding for

Returns: `vector` - The embedding vector using the configured provider

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

Detect the embedding dimension of the currently configured provider/model.

```sql
SELECT pgedge_vectorizer.detect_embedding_dimension();
```

Returns: `INT` - The number of dimensions in the embedding vector

This function generates a probe embedding using the configured provider and model, and returns the dimension of the resulting vector. It is called automatically by `enable_vectorization()` when `embedding_dimension` is not specified.

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

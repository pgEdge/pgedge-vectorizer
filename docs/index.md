# pgEdge Vectorizer

pgEdge Vectorizer is a PostgreSQL extension that automatically chunks text
content and generates vector embeddings using background workers. Vectorizer
provides a seamless integration between your PostgreSQL database and embedding
providers like OpenAI, making it easy to build AI-powered search and retrieval
applications.

pgEdge Vectorizer:

- intelligently splits text into optimal-sized chunks.
- handles embedding generation asynchronously using background workers
  without blocking.
- enables easy switching between OpenAI, Voyage AI, and Ollama.
- processes embeddings efficiently in batches for better API usage.
- automatically retries failed operations with exponential backoff.
- provides built-in views for queue and worker monitoring.
- offers extensive GUC parameters for flexible configuration.

## pgEdge Vectorizer Architecture

pgEdge Vectorizer uses a trigger-based architecture with background workers to
process text asynchronously. The following steps describe the processing flow
from data insertion to embedding storage:

1. A trigger detects INSERT or UPDATE operations on the configured table.
2. The chunking module splits the text into chunks using the configured
   strategy.
3. The system inserts chunk records and queue items into the processing
   queue.
4. Background workers pick up queue items using SKIP LOCKED for concurrent
   processing.
5. The configured provider generates embeddings via its API.
6. The storage layer updates the chunk table with the generated
   embeddings.


## Component Diagram

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




## Hybrid Search (BM25)

Standard vector search uses dense embeddings to find content that is
*semantically similar* to a query. This works well for conceptual matches
(searching for "car" also finds "automobile"), but it can miss results that
contain exact keywords, especially proper nouns, product codes, or technical
terms.

**BM25** is a traditional keyword-ranking algorithm widely used in search
engines. It scores documents by how often query terms appear, adjusted for
document length, so results that contain your exact words rank higher.

Hybrid search runs **both** searches in parallel and merges the two ranked lists
using **Reciprocal Rank Fusion (RRF)**, a simple technique that combines
rankings without needing to normalize scores. The result is a single list that
balances semantic understanding with keyword precision.

### When to use hybrid search

- Queries that mix natural language with specific identifiers
  (e.g., "PostgreSQL 17 release notes", "order ABC-1234").
- Domains where exact terminology matters (legal, medical, technical docs).
- Any time dense-only search returns conceptually related but not quite right
  results.

### How it works

When hybrid search is enabled, the background worker computes a **BM25 sparse
vector** for each text chunk alongside the existing dense embedding. No changes
to your `enable_vectorization()` setup are required; the worker handles
everything automatically.

Behind the scenes, the extension:

1. Tokenizes each chunk, removes stopwords, and counts term frequencies.
2. Maintains an `_idf_stats` table that tracks how common each term is across
   the corpus (used to weight rare terms higher).
3. Computes a sparse vector from the BM25 scores and stores it in the
   `sparse_embedding` column of the chunk table.

At query time, `hybrid_search()` generates both a dense embedding and a BM25
sparse vector for the query text, runs both ranked retrievals, and fuses the
results with RRF.

### Enabling hybrid search

Add to `postgresql.conf` and reload (`SELECT pg_reload_conf()`):

```ini
pgedge_vectorizer.enable_hybrid = true
```

That's it. The workers will begin populating sparse embeddings for all existing
and new chunks.

Two optional parameters let you tune BM25 scoring:

```ini
pgedge_vectorizer.bm25_k1 = 1.2    # term-frequency saturation (0.0-3.0)
pgedge_vectorizer.bm25_b  = 0.75   # length normalization (0.0-1.0)
```

- **k1** controls how quickly the benefit of a repeated term saturates. Higher
  values give more weight to terms that appear many times.
- **b** controls how much a document's length affects its score. At 0, length
  is ignored; at 1, longer documents are penalized more.

The defaults (1.2 and 0.75) are well-established values from information
retrieval research and work well for most use cases.

### Usage example

```sql
-- Enable vectorization as normal
SELECT pgedge_vectorizer.enable_vectorization(
    source_table  := 'articles',
    source_column := 'content'
);

-- Hybrid search with RRF fusion
SELECT source_id, chunk, dense_rank, sparse_rank, rrf_score
FROM pgedge_vectorizer.hybrid_search(
    p_source_table := 'articles'::regclass,
    p_query        := 'PostgreSQL 17 release notes',
    p_limit        := 10,
    p_alpha        := 0.7,   -- weight toward dense results (0 = pure keyword, 1 = pure semantic)
    p_rrf_k        := 60     -- RRF smoothing constant
);

-- Convenience wrapper returning just source_id, chunk, and score
SELECT * FROM pgedge_vectorizer.hybrid_search_simple(
    'articles'::regclass, 'PostgreSQL 17 release notes', 5
);
```

The **p_alpha** parameter lets you control the balance between the two search
methods. A value of 0.7 (the default) favors semantic search; lower values
shift weight toward keyword matching. You can adjust this per query to suit
different use cases.

### Hybrid search GUC parameters

| Parameter | Default | Range | Description |
|-----------|---------|-------|-------------|
| `pgedge_vectorizer.enable_hybrid` | `false` | -- | Enable BM25 sparse vectors alongside dense embeddings |
| `pgedge_vectorizer.bm25_k1` | `1.2` | `0.0-3.0` | BM25 term-frequency saturation |
| `pgedge_vectorizer.bm25_b` | `0.75` | `0.0-1.0` | BM25 document-length normalization |

For more information or to download Vectorizer visit:

- **GitHub**: https://github.com/pgEdge/pgedge-vectorizer
- **Documentation**: (https://docs.pgedge.com/pgedge-vectorizer/)
- **Issues**: https://github.com/pgEdge/pgedge-vectorizer/issues

This software is released under [the PostgreSQL License](LICENCE.md).
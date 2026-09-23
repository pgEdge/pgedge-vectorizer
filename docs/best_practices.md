# Best Practices

The following sections discuss practices that can impact your data integrity, performance, and cost.

**Chunking**

Proper chunking is essential for effective vector search because it balances semantic coherence with search granularity. Chunks that are too small lose context, while chunks that are too large dilute relevance signals.

- A chunk size of 200-500 tokens works well for most use cases.
- An overlap of 10-20% (50-100 tokens) provides good context between adjacent chunks.
- Use a token-based strategy for general purpose content and the markdown strategy for structured documents.

**Changing an embedding model**

Changing the model for a table that already has embeddings is not free, and
`set_embedding_model()` refuses to do it silently for that reason. Passing
`force_reembed => true` clears every embedding and requeues every chunk, so the
whole table is embedded again: against a metered provider that is a bill, and
if the dimension changes it is also a rewrite of the chunk table. The chunks
themselves are not rebuilt, because neither chunk boundaries nor the BM25
statistics depend on the embedding model, so the sparse embeddings and token
counts survive untouched.

- The refusal keys on the model changing, not on the dimension changing. Two
  models of the same width, such as `text-embedding-3-small` and
  `text-embedding-ada-002`, both produce 1536 values, so swapping one for the
  other would leave the old vectors in place, correctly shaped and meaningless
  beside the new ones. Similarity between two models' vectors is noise, and
  nothing else in the system would report a problem, which makes it the more
  dangerous of the two cases.
- A model wider than 2000 dimensions cannot be used, because the HNSW index
  that `enable_vectorization()` creates does not support one. That rules out
  `text-embedding-3-large` at its full 3072, though it can be requested at a
  smaller size from providers that support shortening.
- Pin the model rather than inheriting it wherever the embeddings matter, since
  an inheriting vectorizer follows `pgedge_vectorizer.model` with no guard.

**Performance**

Optimizing performance ensures efficient resource utilization and faster embedding generation. These settings help minimize API costs while maintaining responsive processing speeds.

- Larger batches of 10-50 items are more efficient for API calls.
- Match the worker count to your API rate limits to avoid throttling.
- Regularly clear completed items from the queue to keep it small and responsive.

**API Usage**

Managing API usage carefully prevents service interruptions and controls costs. Following these practices helps maintain reliable operation and protects sensitive credentials.

- Be aware of your provider's rate limits to avoid service interruptions.
- Monitor your API usage closely, especially when working with large datasets.
- Keep API keys secure by using proper file permissions (`0600`) on key files.

**Data Management**

Effective data management ensures clean operations and provides flexibility when updating embeddings. These practices help maintain data integrity and optimize storage usage.

- The system automatically skips NULL, empty, and whitespace-only content.
- Use the `reprocess_chunks()` function to queue existing chunks that are missing embeddings.
- Use the `recreate_chunks()` function for a complete chunk regeneration, which deletes all existing chunks first.
- Each column gets independent chunk tables and triggers, so you can disable them selectively as needed.
- Change a vectorizer's model with `set_embedding_model()`, which alters the
  chunk table's vector column for you where the new model is a different
  width. Dropping the chunk table and enabling vectorization again also works,
  but throws away chunk rows, sparse embeddings and BM25 statistics that were
  never wrong, and has to be repeated for every vectorized column.
  `recreate_chunks()` is not an alternative: it rebuilds the chunks and leaves
  the column exactly as it was.
- Budget for the provider cost of re-embedding an entire table before
  changing the model on a populated one.

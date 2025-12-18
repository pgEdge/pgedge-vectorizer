# Best Practices

The following sections discuss practices that can impact your data integrity, performance, and cost.

**Chunking**

Proper chunking is essential for effective vector search because it balances semantic coherence with search granularity. Chunks that are too small lose context, while chunks that are too large dilute relevance signals.

- A chunk size of 200-500 tokens works well for most use cases.
- An overlap of 10-20% (50-100 tokens) provides good context between adjacent chunks.
- Use a token-based strategy for general purpose content and the markdown strategy for structured documents.

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

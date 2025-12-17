# Best Practices

## Chunking

- **Size**: 200-500 tokens works well for most use cases
- **Overlap**: 10-20% overlap (50-100 tokens) provides good context
- **Strategy**: Use token_based for general purpose, markdown for structured docs

## Performance

- **Batching**: Larger batches (10-50) are more efficient
- **Workers**: Match worker count to your API rate limits
- **Cleanup**: Regularly clear completed items to keep queue small

## API Usage

- **Rate Limits**: Be aware of provider rate limits
- **Costs**: Monitor API usage, especially with large datasets
- **Keys**: Keep API keys secure, use proper file permissions (600)

## Data Management

- **Empty Content**: NULL, empty, and whitespace-only content is automatically skipped
- **Reprocessing**: Use `reprocess_chunks()` to queue existing chunks without embeddings
- **Full Rebuild**: Use `recreate_chunks()` for complete chunk regeneration (deletes all existing chunks)
- **Multiple Columns**: Each column gets independent chunk tables and triggers - disable selectively as needed

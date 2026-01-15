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




For more information or to download Vectorizer visit:

- **GitHub**: https://github.com/pgEdge/pgedge-vectorizer
- **Documentation**: (https://docs.pgedge.com/pgedge-vectorizer/)
- **Issues**: https://github.com/pgEdge/pgedge-vectorizer/issues

This software is released under [the PostgreSQL License](LICENCE.md).
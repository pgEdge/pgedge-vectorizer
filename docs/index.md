# pgEdge Vectorizer

pgEdge Vectorizer is a PostgreSQL extension that automatically chunks text content and generates vector embeddings using background workers. Vectorizer provides a seamless integration between your PostgreSQL database and embedding providers like OpenAI, making it easy to build AI-powered search and retrieval applications.

pgEdge Vectorizer:

- intelligently splits text into optimal-sized chunks.
- handles embedding generation asynchronously using background workers without blocking.
- enables easy switching between OpenAI, Voyage AI, and Ollama.
- processes embeddings efficiently in batches for better API usage.
- automatically retries failed operations with exponential backoff.
- provides built-in views for queue and worker monitoring.
- offers extensive GUC parameters for flexible configuration.

For more information or to download Vectorizer visit:

- **GitHub**: https://github.com/pgEdge/pgedge-vectorizer
- **Documentation**: (https://docs.pgedge.com/pgedge-vectorizer/)
- **Issues**: https://github.com/pgEdge/pgedge-vectorizer/issues

This software is released under [the PostgreSQL License](LICENCE.md).
# Changelog

All notable changes to pgEdge Vectorizer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0-alpha3] - 2025-11-03

### Added

- Added a garbage collector to automatically delete old queue entries based on the
    age defined in the pgedge_vectorizer.auto_cleanup_hours GUC.
- `generate_embedding()` function for generating embeddings from query text directly in SQL

## [1.0-alpha2] - 2025-11-02

### Added

- PostgreSQL 18 support

### Changed

- Updated pgvector dependency to v0.8.1 for PostgreSQL 18 compatibility

## [1.0-alpha1] - 2025-11-21

### Added

- Initial release of pgEdge Vectorizer
- Automatic text chunking with configurable strategies (token_based, semantic, markdown)
- Background worker processing for asynchronous embedding generation
- Support for multiple embedding providers:
    - OpenAI (text-embedding-3-small, text-embedding-3-large, text-embedding-ada-002)
    - Voyage AI (voyage-2, voyage-large-2, voyage-code-2)
    - Ollama (nomic-embed-text, mxbai-embed-large, all-minilm)
- Multi-column vectorization support
- Queue management with monitoring views (queue_status, failed_items, pending_count)
- Maintenance functions:
    - `enable_vectorization()` - Enable automatic vectorization for a table column
    - `disable_vectorization()` - Disable vectorization
    - `chunk_text()` - Manual text chunking
    - `retry_failed()` - Retry failed queue items
    - `clear_completed()` - Remove completed items from queue
    - `reprocess_chunks()` - Queue existing chunks for reprocessing
    - `recreate_chunks()` - Complete rebuild of chunks from source
    - `show_config()` - Display configuration settings
- Configurable chunking parameters (chunk_size, chunk_overlap)
- Automatic retry with exponential backoff
- Batch processing for efficient API usage
- Non-ASCII character stripping option
- Comprehensive test suite with pg_regress

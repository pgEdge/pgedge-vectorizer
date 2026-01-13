# Changelog

All notable changes to pgEdge Vectorizer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.0-beta2] - 2026-01-13

### Added

- Hybrid chunking strategy (`hybrid`) inspired by Docling's approach
    - Parses markdown structure (headings, code blocks, lists, blockquotes, tables)
    - Preserves heading context hierarchy in each chunk for better RAG retrieval
    - Two-pass refinement: splits oversized chunks, merges undersized consecutive chunks with same context
    - Significantly improves retrieval accuracy for structured documents
- Markdown chunking strategy (`markdown`) - structure-aware without refinement passes
    - Simpler and faster alternative to hybrid
    - Good balance of structure awareness and performance
- Automatic fallback detection for `hybrid` and `markdown` strategies
    - Detects if content is likely markdown based on syntax patterns
    - Falls back to `token_based` chunking for plain text to avoid overhead
    - Ensures optimal strategy is always used regardless of content type

### Fixed

- Fixed potential buffer over-read vulnerabilities in markdown detection
- Fixed infinite recursion in markdown/hybrid fallback when content is plain text

## [1.0-beta1] - 2025-12-15

### Changed

- Promoted to beta status after extensive testing and bug fixes

### Fixed

- Fixed table name reference in vectorization code

## [1.0-alpha5] - 2025-12-12

### Fixed

- Fixed token-based chunking producing corrupted chunks when overlap > 0
    (chunks would start mid-word like "ntence." instead of proper word boundaries)
- Fixed potential negative index access in `find_good_break_point()` function

## [1.0-alpha4] - 2025-12-08

### Fixed

- Fixed uninitialized dimension variable in `generate_embedding()` that caused
    spurious "Dimension mismatch" errors with random dimension values

## [1.0-alpha3] - 2025-12-03

### Added

- Added a garbage collector to automatically delete old queue entries based on the
    age defined in the pgedge_vectorizer.auto_cleanup_hours GUC.
- `generate_embedding()` function for generating embeddings from query text directly in SQL

## [1.0-alpha2] - 2025-12-02

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

# Changelog

All notable changes to pgEdge Vectorizer will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Security

- Hardened API key file loading in OpenAI and Voyage providers (#17)
    - Reject API key files larger than 4096 bytes (`MAX_API_KEY_FILE_SIZE`) before
      reading, preventing unbounded memory allocation (CWE-20 / CWE-120)
    - Replaced the `stat()`-then-`fopen()` pattern with `open(O_RDONLY|O_CLOEXEC)`
      + `fstat()` + `fdopen()` to close a TOCTOU race where the file could be
      swapped between check and open
    - Added an `S_ISREG()` check to reject non-regular files (devices, FIFOs,
      directories) and a runtime byte counter that aborts the read if the file
      grows past the limit mid-read
- Stopped trusting the `HOME` environment variable when expanding `~` in API key
  paths; `expand_tilde()` now uses `getpwuid(geteuid())` so an attacker-controlled
  environment cannot redirect the path (CWE-807)
- Replaced `strncpy` + manual null-termination in the background worker with
  `strlcpy`, guaranteeing null termination of the database name buffer (CWE-120)
- Pinned all GitHub Actions in the CI workflow to full commit SHAs rather than
  mutable `@v4` tags, so a repointed tag in an upstream action cannot silently
  change what runs in CI (CWE-1357)
- Replaced `strtok()` with `strtok_r()` when parsing
  `pgedge_vectorizer.databases` in the background worker; `strtok()` keeps its
  parsing position in a single process-wide static, which any other `strtok()`
  caller reached from the same loop would corrupt (CWE-676)

### Added

- Added `pgedge_vectorizer.worker_service_quantum`, which bounds how long a
  worker services one database before yielding its slot when there are more
  configured databases than workers. It is ignored when every configured
  database can have its own worker, in which case workers stay resident.
- `pgedge_vectorizer.refresh_triggers()` recreates the DELETE and TRUNCATE
  cleanup triggers for every registered vectorizer, returning the number
  recreated. Upgrading repairs existing tables automatically, so this is only
  needed if a trigger has been dropped by hand, or on an installation whose
  vectorized tables were created under a build predating those triggers.
- `pgedge_vectorizer.vectorizers` now records the document identifier column and
  its type, so cleanup triggers can be recreated without re-detecting it.

### Changed

- `pgedge_vectorizer.num_workers` now sets the maximum number of *concurrent*
  workers rather than a fixed pool size, and can be changed with a reload
  instead of requiring a restart. Configurations that raised it purely to obtain
  coverage of every configured database no longer need to do so. Note that this
  is a change in meaning: a value chosen to guarantee coverage now caps
  concurrency instead.
- Background workers are now spawned per database by a launcher process rather
  than being statically registered at startup, so the set of serviced databases
  follows `pgedge_vectorizer.databases` as it changes, without a restart.

### Fixed

- Fixed databases beyond `pgedge_vectorizer.num_workers` never being processed
  ([#23](https://github.com/pgEdge/pgedge-vectorizer/issues/23)). Workers were
  assigned to databases by `worker_id % db_count`, and because `worker_id` only
  ranged over `0` to `num_workers-1`, any database at a later position in the
  list was silently never serviced: its queue accumulated entries that were
  never handled, with nothing logged to indicate it. With the default
  `num_workers = 2` and five databases configured, three of them were affected.
- Deleting rows from a vectorized source table, or truncating it, no longer
  leaves orphaned chunks, embeddings, queue entries and BM25 document
  frequencies behind
  ([#24](https://github.com/pgEdge/pgedge-vectorizer/issues/24)). Vectorization
  previously installed an `AFTER INSERT OR UPDATE` trigger only, so removing
  source data left every piece of derived data in place: vector and hybrid
  search returned hits pointing at rows that no longer existed, the queue spent
  embedding API calls on chunks for deleted rows, and `idf_weight` drifted for
  the whole corpus, distorting relevance ranking for every query rather than
  only those touching deleted rows.

  Vectorization now installs three triggers per column, adding an `AFTER DELETE`
  and an `AFTER TRUNCATE` trigger. The DELETE trigger is statement-level and uses
  a transition table, so a bulk delete stays set-based rather than doing per-row
  work. **Upgrading also repairs tables that were already vectorized**, which
  otherwise would have kept leaking silently.

## [1.0] - 2026-03-13

### Added

- Support for any single-column primary key type in vectorized tables (#11)
    - Auto-detect PK column name and type from `pg_index` instead of hardcoding `BIGINT`
    - Chunk table `source_id` column now matches the source table's PK type (`UUID`, `TEXT`, `VARCHAR(n)`, etc.)
    - New `source_pk` parameter on `enable_vectorization()` for explicit column selection
    - Composite primary key tables supported by specifying `source_pk` explicitly

### Fixed

- Fixed stale embeddings and orphaned queue entries on content update (#12)
    - Queue entries are now cleaned up before deleting chunks in the vectorization trigger
    - Stale high-index chunks are cleaned up when re-enabling vectorization
    - Worker warns when a chunk is deleted by a concurrent source update
- Fixed queue processing not starting until SIGHUP after `CREATE EXTENSION` (#10)
    - Workers now use exponential backoff (5s, 10s, 20s, ... up to 5 min) when checking for extension installation, instead of a fixed 5-minute sleep
    - Extension is discovered within seconds of running `CREATE EXTENSION`, no SIGHUP needed
    - Improved log messages with actionable hints on first check failure

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

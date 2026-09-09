# Monitoring

Monitoring helps you understand the behavior of the vectorizer system, diagnose issues, and verify that background workers and queues are running as expected. The following commands provide visibility into logs, configuration, and queue activity.

## Accessing PostgreSQL Logs

The vectorizer workers write operational and error messages directly into PostgreSQL’s standard server log. You can tail the log to observe real-time activity or troubleshoot unexpected behavior:

```bash
tail -f /var/log/postgresql/postgresql-*.log | grep pgedge_vectorizer
```

## Checking the Runtime Configuration

You can view Vectorizer’s active runtime configuration using the built-in extension function:

```sql
SELECT * FROM pgedge_vectorizer.show_config();
```


## Check Queue Status

Vectorizer maintains internal queues for pending, active, and failed items. The following views let you inspect the current workload and identify any processing issues:

```sql
-- Overall status
SELECT * FROM pgedge_vectorizer.queue_status;

-- Pending items
SELECT * FROM pgedge_vectorizer.pending_count;

-- Failed items with errors
SELECT * FROM pgedge_vectorizer.failed_items;
```

## Check Embedding Coverage

Embeddings are generated asynchronously, so there is always some lag between a change to a source table and the embedding catching up with it. The `vectorizer_status` view reports, for every registered vectorizer, how much of the source is embedded and how much work is still outstanding, which is what you need in order to judge whether a search result set reflects recent changes:

```sql
SELECT * FROM pgedge_vectorizer.vectorizer_status;
```

```
source_table        | articles
source_column       | body
chunk_table         | articles_body_chunks
source_rows         | 2110
source_rows_covered | 2098
source_coverage     | 0.9943
chunks_total        | 12043
chunks_embedded     | 11890
chunk_coverage      | 0.9873
queue_pending       | 153
queue_processing    | 2
queue_failed        | 0
oldest_pending_age  | 00:04:12.882
last_processed_at   | 2026-09-09 11:58:07.114+01
```

Coverage is reported two ways because they answer different questions. `source_coverage` is the fraction of source rows with at least one embedded chunk, which is the closer match to "can I trust a search over this table"; `chunk_coverage` is the fraction of individual chunks embedded, which is the better measure of how much work is left to do. A large document part-way through being embedded counts as covered on the first measure and only partly on the second.

Alongside those, `queue_pending`, `queue_processing` and `queue_failed` are the backlog for this vectorizer, `oldest_pending_age` is how long the oldest unprocessed item has been waiting, and `last_processed_at` is when an item was most recently completed. A backlog that is not shrinking and an `oldest_pending_age` that keeps growing point at a worker that is not running, or at a provider that is rejecting requests; `queue_failed` above zero is worth following up in `failed_items`.

To look at a single vectorizer rather than all of them, call the function form, optionally naming the column as well:

```sql
SELECT * FROM pgedge_vectorizer.vectorizer_status('articles'::regclass);
SELECT * FROM pgedge_vectorizer.vectorizer_status('articles'::regclass, 'body');
```

Three things are worth knowing before you put this anywhere automated.

It is not cheap. Each row counts the chunk table and the source table, so unlike the queue views above, which read only an indexed queue table, this scans your data. Treat it as a diagnostic you run when you want an answer, rather than something a dashboard polls every few seconds, and use the function form to scope it to one table where you can.

`last_processed_at` reflects only queue rows that still exist, so running `clear_completed()` will move it backwards or set it to NULL. It says when the queue last completed something it still remembers, not when the embeddings were last touched.

A `source_coverage` above 1 means the chunk table holds rows for source rows that no longer exist. That is left visible rather than clamped, because it is a real problem worth seeing: it usually means chunks were orphaned by a bulk operation that bypassed the triggers.

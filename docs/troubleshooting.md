# Troubleshooting

## Workers Not Starting

1. Verify `shared_preload_libraries`:
```sql
SHOW shared_preload_libraries;
```

2. Check PostgreSQL logs for errors

3. Ensure proper permissions on API key file

## Workers Not Processing After CREATE EXTENSION

Background workers start with PostgreSQL, before the extension is created. Workers automatically detect the extension using exponential backoff (checking every 5s, 10s, 20s, ... up to 5 minutes). After running `CREATE EXTENSION pgedge_vectorizer`, workers should discover it within seconds.

If workers don't start processing:

1. Check the logs for messages like:
```
pgedge_vectorizer worker 1: extension not installed in database 'mydb', will check again in 5s (hint: run CREATE EXTENSION pgedge_vectorizer)
```

2. Verify the extension was created in a database listed in `pgedge_vectorizer.databases`:
```sql
SHOW pgedge_vectorizer.databases;
```

3. If needed, reload the configuration to reset the detection interval:
```sql
SELECT pg_reload_conf();
```

## Slow Processing

1. Increase workers:
```sql
ALTER SYSTEM SET pgedge_vectorizer.num_workers = 4;
SELECT pg_reload_conf();
```

Workers are drawn from `max_worker_processes`, so raising `num_workers` beyond
the slots left spare there achieves nothing; the launcher simply logs that
`max_worker_processes` may be exhausted and carries on with what it has.
Raising `max_worker_processes` itself does require a restart.

2. Increase batch size:
```sql
ALTER SYSTEM SET pgedge_vectorizer.batch_size = 20;
SELECT pg_reload_conf();
```

## Failed Embeddings

1. Check API key is valid
2. Verify network connectivity
3. Review error messages:
```sql
SELECT * FROM pgedge_vectorizer.failed_items;
```

4. Retry failed items:
```sql
SELECT pgedge_vectorizer.retry_failed();
```

## Dimension Mismatch After Changing the Model

Each chunk table stores its vectors in an `embedding vector(N)` column,
where N is fixed when `enable_vectorization()` creates the table. If you
change `pgedge_vectorizer.model` to a model returning a different number
of dimensions, the worker cannot write the new vectors into the existing
column, and embeddings stop being produced for that table.

Nothing is corrupted when this happens. The worker compares the two
dimensions before it writes, so the existing embeddings are left intact
and no vector of the wrong size is ever stored.

The affected queue items move to `failed` rather than being retried,
because retrying cannot succeed. Run the following query to identify
them:

```sql
SELECT chunk_table, error_message, count(*)
  FROM pgedge_vectorizer.queue
 WHERE status = 'failed'
 GROUP BY chunk_table, error_message;
```

An affected item reports `Dimension mismatch: model=N, table=M`, where N
is the dimension the configured model returned and M is the dimension
the chunk table expects. The server log carries a matching warning that
names the table.

Restoring the previous model is the quicker of the two remedies, and is
the right one if the change was accidental:

```sql
ALTER SYSTEM SET pgedge_vectorizer.model = 'text-embedding-3-small';
SELECT pg_reload_conf();
SELECT pgedge_vectorizer.retry_failed();
```

Rebuilding the vectorizer keeps the new model and re-embeds the table
under it. Note that `recreate_chunks()` does not resolve a dimension
change, because that function deletes the rows of a chunk table without
altering the type of the column. Follow these steps instead:

1. Set the new model and reload the configuration so that the dimension
   detection uses the model you want.

    ```sql
    ALTER SYSTEM SET pgedge_vectorizer.model = 'text-embedding-3-large';
    SELECT pg_reload_conf();
    ```

2. Drop the vectorizer together with its chunk table, which discards the
   embeddings of the old dimension.

    ```sql
    SELECT pgedge_vectorizer.disable_vectorization(
        'docs', 'body', drop_chunk_table => TRUE);
    ```

3. Enable vectorization again, which detects the new dimension, creates
   the chunk table to match, and queues every source row.

    ```sql
    SELECT pgedge_vectorizer.enable_vectorization('docs', 'body');
    ```

Re-embedding calls the provider for every chunk in the table, so confirm
the cost against your provider's pricing before starting on a large
table.

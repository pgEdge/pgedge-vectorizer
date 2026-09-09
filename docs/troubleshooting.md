# Troubleshooting

## Workers Not Starting

1. Verify `shared_preload_libraries`:
```sql
SHOW shared_preload_libraries;
```

2. Check PostgreSQL logs for errors

3. Ensure proper permissions on API key file

## Workers Not Processing After CREATE EXTENSION

Background workers start with PostgreSQL, before the extension is
created. A worker checks for the extension on an exponential backoff,
waiting 5s, then 10s, then 20s, and so on up to a ceiling of 5 minutes.
After running `CREATE EXTENSION pgedge_vectorizer`, a worker discovers it
on its next check, so a database configured long before the extension was
created can wait up to 5 minutes. Reload the configuration to have the
workers check immediately.

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

## Provider Rate Limits

Every hosted provider limits how fast it will answer, and a queue with
real work in it will reach that limit. This is ordinary traffic, not a
failure, and the worker treats it as such:

- The refused items go back to `pending` together and are retried as one
  request.
- The wait comes from the provider's `Retry-After`, falling back to 5
  seconds doubling to a minute if it sent none.
- No attempt is charged, so throttling cannot exhaust an item's
  `max_attempts`. The deferrals are counted in
  `queue.rate_limit_deferrals`, and an item is only given up on after a
  hundred of them.
- The worker stops sending to *that provider* until the wait has passed.
  Vectorizers using a different provider carry on, including in the same
  batch: a hosted provider's quota does not hold up a local model that has
  no quota at all.

A queue being throttled looks like this and needs no intervention:

```sql
SELECT status, count(*), max(attempts) AS attempts,
       max(rate_limit_deferrals) AS deferrals
  FROM pgedge_vectorizer.queue
 GROUP BY status;
```

Each deferral is logged with the status code and the wait taken:

```text
LOG:  pgedge_vectorizer worker for database "app": provider rate limited
      (HTTP 429), deferring 22 queue items, next attempt in 4s
```

If deferrals climb steadily instead of clearing, work is arriving faster
than the provider's quota allows. Lower
`pgedge_vectorizer.num_workers` so fewer requests compete for it, raise
`pgedge_vectorizer.batch_size` so each request carries more, or move to a
plan with a higher limit.

## A Vectorizer Names a Provider That Does Not Exist

A vectorizer can name its own provider, and a name that does not match one
the extension knows about, or a provider that cannot start because its API
key file is unreadable, cannot be embedded against. The worker says so and
leaves that vectorizer's work alone:

```text
WARNING:  pgedge_vectorizer worker for database "app": provider "openia" for
          articles_body_chunks is unavailable, leaving 3 items queued:
          provider not found
```

Its items stay `pending` with `attempts` still at zero, because the fault is
in the configuration rather than in the work, and charging them would retire
the queue one blameless row at a time. Every other vectorizer in the database
carries on as normal.

Confirm it with:

```sql
SELECT source_table, source_column, provider, model
  FROM pgedge_vectorizer.vectorizers
 WHERE provider IS NOT NULL;

SELECT status, count(*), max(attempts) AS attempts
  FROM pgedge_vectorizer.queue
 WHERE chunk_table = 'articles_body_chunks'
 GROUP BY status;
```

The fix is to correct the provider, and nothing else:

```sql
SELECT pgedge_vectorizer.set_embedding_model(
    'articles'::regclass, 'body', 'text-embedding-3-small',
    provider => 'openai');
```

There is no need to retry anything, because nothing was ever charged; the
worker picks the items up on its next poll. If every vectorizer in the
database is affected, which is what a mistyped `pgedge_vectorizer.provider`
does, the worker also backs off between attempts rather than polling flat
out, and says so:

```text
LOG:  pgedge_vectorizer worker for database "app": no usable provider for the
      queued work, waiting 20s before trying again
```

That wait resets as soon as the configuration is corrected and reloaded.

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
the right one if the change was accidental. Substitute the model that
built the table rather than the name shown here, because setting any
other model leaves the dimensions mismatched:

```sql
ALTER SYSTEM SET pgedge_vectorizer.model = 'the-previous-model';
SELECT pg_reload_conf();
SELECT pgedge_vectorizer.retry_failed();
```

The `table=M` figure in the error gives the dimension the chunk table
expects, so the model you restore must be one that returns M dimensions.

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

Repeat those steps for every vectorized column, not just the one you
noticed. The model is a single global setting while chunk tables are
independent per column, so changing it affects every vectorizer whose
dimension no longer matches. The following query lists them:

```sql
SELECT source_table, source_column, chunk_table
  FROM pgedge_vectorizer.vectorizers
 ORDER BY source_table, source_column;
```

Re-embedding calls the provider for every chunk in every table rebuilt,
so confirm the cost against your provider's pricing before starting.

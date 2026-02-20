# Troubleshooting

## Workers Not Starting

1. Verify `shared_preload_libraries`:
```sql
SHOW shared_preload_libraries;
```

2. Check PostgreSQL logs for errors

3. Ensure proper permissions on API key file

## Workers Not Processing After CREATE EXTENSION

Background workers start with PostgreSQL — before the extension is created. Workers automatically detect the extension using exponential backoff (checking every 5s, 10s, 20s, ... up to 5 minutes). After running `CREATE EXTENSION pgedge_vectorizer`, workers should discover it within seconds.

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
-- Requires restart
```

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

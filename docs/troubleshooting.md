# Troubleshooting

## Workers Not Starting

1. Verify `shared_preload_libraries`:
```sql
SHOW shared_preload_libraries;
```

2. Check PostgreSQL logs for errors

3. Ensure proper permissions on API key file

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

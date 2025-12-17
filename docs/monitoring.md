# Monitoring

## Check Queue Status

```sql
-- Overall status
SELECT * FROM pgedge_vectorizer.queue_status;

-- Pending items
SELECT * FROM pgedge_vectorizer.pending_count;

-- Failed items with errors
SELECT * FROM pgedge_vectorizer.failed_items;
```

## Check Configuration

```sql
SELECT * FROM pgedge_vectorizer.show_config();
```

## PostgreSQL Logs

Workers log to PostgreSQL's standard log:

```bash
tail -f /var/log/postgresql/postgresql-*.log | grep pgedge_vectorizer
```

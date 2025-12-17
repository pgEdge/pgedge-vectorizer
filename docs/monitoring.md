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

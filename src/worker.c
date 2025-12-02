/*-------------------------------------------------------------------------
 *
 * worker.c
 *		Background worker implementation for async embedding generation
 *
 * This file implements the background worker that processes the embedding
 * queue and generates embeddings using configured providers.
 *
 * Portions copyright (c) 2025, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"

#include <time.h>

#include "commands/dbcommands.h"
#include "pgstat.h"
#include "postmaster/interrupt.h"
#include "storage/proc.h"
#include "tcop/tcopprot.h"
#include "utils/memutils.h"
#include "utils/ps_status.h"

/* Signal flags */
static volatile sig_atomic_t got_sigterm = false;
static volatile sig_atomic_t got_sighup = false;

/* Last cleanup timestamp */
static time_t last_cleanup_time = 0;

/* Forward declarations */
static void worker_sigterm(SIGNAL_ARGS);
static void worker_sighup(SIGNAL_ARGS);
static void process_queue_batch(int worker_id);
static void cleanup_completed_items(int worker_id);
static void update_embedding(int64 chunk_id, const char *chunk_table,
							 const float *embedding, int dim);

/*
 * Signal handler for SIGTERM
 */
static void
worker_sigterm(SIGNAL_ARGS)
{
	int save_errno = errno;
	got_sigterm = true;
	SetLatch(MyLatch);
	errno = save_errno;
}

/*
 * Signal handler for SIGHUP
 */
static void
worker_sighup(SIGNAL_ARGS)
{
	int save_errno = errno;
	got_sighup = true;
	SetLatch(MyLatch);
	errno = save_errno;
}

/*
 * Register background workers
 *
 * Called during _PG_init when shared_preload_libraries is processed.
 */
void
register_background_workers(void)
{
	BackgroundWorker worker;

	for (int i = 0; i < pgedge_vectorizer_num_workers; i++)
	{
		memset(&worker, 0, sizeof(BackgroundWorker));

		/* Set worker properties */
		worker.bgw_flags = BGWORKER_SHMEM_ACCESS |
						   BGWORKER_BACKEND_DATABASE_CONNECTION;
		worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
		worker.bgw_restart_time = 10;  /* Restart after 10 seconds if crashes */

		snprintf(worker.bgw_library_name, BGW_MAXLEN, "pgedge_vectorizer");
		snprintf(worker.bgw_function_name, BGW_MAXLEN, "pgedge_vectorizer_worker_main");
		snprintf(worker.bgw_name, BGW_MAXLEN, "pgedge_vectorizer worker %d", i + 1);
		snprintf(worker.bgw_type, BGW_MAXLEN, "pgedge_vectorizer");

		worker.bgw_main_arg = Int32GetDatum(i);
		worker.bgw_notify_pid = 0;

		RegisterBackgroundWorker(&worker);
	}
}

/*
 * Check if extension is installed in current database
 */
static bool
extension_installed(void)
{
	int ret;
	bool found = false;

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	SPI_connect();
	PushActiveSnapshot(GetTransactionSnapshot());

	ret = SPI_execute("SELECT 1 FROM pg_extension WHERE extname = 'pgedge_vectorizer'",
					  true, 1);

	if (ret == SPI_OK_SELECT && SPI_processed > 0)
		found = true;

	SPI_finish();
	PopActiveSnapshot();
	CommitTransactionCommand();

	return found;
}

/*
 * Background worker main entry point
 */
PGDLLEXPORT void
pgedge_vectorizer_worker_main(Datum main_arg)
{
	int worker_id = DatumGetInt32(main_arg);
	char dbname[NAMEDATALEN];
	char *db_list;
	char *db_name;
	char *db_copy;
	int db_count = 0;
	bool extension_exists = false;
	int retry_interval = 300000; /* 5 minutes when extension not found */

	/* Setup signal handlers */
	pqsignal(SIGTERM, worker_sigterm);
	pqsignal(SIGHUP, worker_sighup);

	/* We're now ready to receive signals */
	BackgroundWorkerUnblockSignals();

	/* Check if databases are configured */
	if (pgedge_vectorizer_databases == NULL || pgedge_vectorizer_databases[0] == '\0')
	{
		elog(LOG, "pgedge_vectorizer worker %d: no databases configured in pgedge_vectorizer.databases, sleeping",
			 worker_id + 1);

		/* Sleep indefinitely, checking periodically for config changes */
		while (!got_sigterm)
		{
			int rc;

			if (got_sighup)
			{
				got_sighup = false;
				ProcessConfigFile(PGC_SIGHUP);

				/* Check if databases were configured */
				if (pgedge_vectorizer_databases != NULL && pgedge_vectorizer_databases[0] != '\0')
					break;
			}

			rc = WaitLatch(MyLatch,
						   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
						   60000L, /* Check every minute */
						   PG_WAIT_EXTENSION);

			ResetLatch(MyLatch);

			if (rc & WL_POSTMASTER_DEATH)
				proc_exit(1);
		}

		if (got_sigterm)
			proc_exit(0);
	}

	/* Parse database list and select one for this worker */
	db_list = pstrdup(pgedge_vectorizer_databases);
	db_copy = db_list;

	/* Count databases */
	while ((db_name = strtok(db_copy, ",")) != NULL)
	{
		db_copy = NULL;
		db_count++;
	}

	if (db_count == 0)
	{
		elog(LOG, "pgedge_vectorizer worker %d: empty database list, exiting",
			 worker_id + 1);
		proc_exit(0);
	}

	/* Select database for this worker (round-robin) */
	pfree(db_list);
	db_list = pstrdup(pgedge_vectorizer_databases);
	db_copy = db_list;

	for (int i = 0; i <= (worker_id % db_count); i++)
	{
		db_name = strtok(db_copy, ",");
		db_copy = NULL;
	}

	/* Trim whitespace */
	while (*db_name == ' ' || *db_name == '\t')
		db_name++;

	strncpy(dbname, db_name, NAMEDATALEN - 1);
	dbname[NAMEDATALEN - 1] = '\0';

	/* Remove trailing whitespace */
	for (int i = strlen(dbname) - 1; i >= 0 && (dbname[i] == ' ' || dbname[i] == '\t'); i--)
		dbname[i] = '\0';

	pfree(db_list);

	/* Connect to the selected database */
	BackgroundWorkerInitializeConnection(dbname, NULL, 0);

	elog(LOG, "pgedge_vectorizer worker %d started (database: %s)",
		 worker_id + 1, dbname);

	/* Set process display */
	pgstat_report_appname(psprintf("pgedge_vectorizer worker %d", worker_id + 1));

	/* Main work loop */
	while (!got_sigterm)
	{
		int rc;
		int wait_time;

		/* Reload configuration if SIGHUP received */
		if (got_sighup)
		{
			got_sighup = false;
			ProcessConfigFile(PGC_SIGHUP);
			/* Recheck extension status after config reload */
			extension_exists = false;
		}

		/* Check if extension is installed (periodically recheck) */
		if (!extension_exists)
		{
			PG_TRY();
			{
				extension_exists = extension_installed();
				if (!extension_exists)
				{
					/* Log once, then sleep for longer interval */
					if (got_sighup || (time(NULL) % 300) == 0) /* Log every 5 minutes */
					{
						elog(LOG, "pgedge_vectorizer worker %d: extension not installed in database '%s', will retry",
							 worker_id + 1, dbname);
					}
				}
				else
				{
					elog(LOG, "pgedge_vectorizer worker %d: extension found in database '%s', starting to process queue",
						 worker_id + 1, dbname);
				}
			}
			PG_CATCH();
			{
				EmitErrorReport();
				FlushErrorState();
				AbortCurrentTransaction();
				extension_exists = false;
			}
			PG_END_TRY();
		}

		/* Update process status */
		pgstat_report_activity(STATE_IDLE, NULL);

		/* Use longer wait time if extension not installed */
		wait_time = extension_exists ? pgedge_vectorizer_worker_poll_interval : retry_interval;

		/* Wait for work or timeout */
		rc = WaitLatch(MyLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   wait_time,
					   PG_WAIT_EXTENSION);

		ResetLatch(MyLatch);

		/* Emergency bailout if postmaster has died */
		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		/* Only process queue if extension is installed */
		if (!extension_exists)
			continue;

		/* Process pending queue items */
		pgstat_report_activity(STATE_RUNNING, "processing embedding queue");

		PG_TRY();
		{
			process_queue_batch(worker_id);

			/* Perform automatic cleanup if enabled */
			cleanup_completed_items(worker_id);
		}
		PG_CATCH();
		{
			EmitErrorReport();
			FlushErrorState();

			/* Don't exit on errors - log and continue */
			elog(LOG, "pgedge_vectorizer worker %d: error in processing, continuing",
				 worker_id + 1);

			/* Abort any transaction */
			AbortCurrentTransaction();

			/* Recheck extension status on error */
			extension_exists = false;
		}
		PG_END_TRY();
	}

	/* Cleanup before exit */
	elog(LOG, "pgedge_vectorizer worker %d shutting down", worker_id + 1);
	proc_exit(0);
}

/*
 * Process a batch of queue items
 */
static void
process_queue_batch(int worker_id)
{
	int ret;
	int batch_size = pgedge_vectorizer_batch_size;
	EmbeddingProvider *provider = NULL;
	char *error_msg = NULL;

	/* Start a transaction */
	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());
	SPI_connect();

	/* Fetch pending items using FOR UPDATE SKIP LOCKED */
	ret = SPI_execute(psprintf(
		"SELECT id, chunk_id, chunk_table, content, attempts, max_attempts "
		"FROM pgedge_vectorizer.queue "
		"WHERE status = 'pending' "
		"AND (next_retry_at IS NULL OR next_retry_at <= NOW()) "
		"ORDER BY attempts DESC, created_at "
		"LIMIT %d "
		"FOR UPDATE SKIP LOCKED",
		batch_size),
		false, batch_size);

	if (ret == SPI_OK_SELECT && SPI_processed > 0)
	{
		int n_items = SPI_processed;
		int64 *queue_ids = palloc(n_items * sizeof(int64));
		int64 *chunk_ids = palloc(n_items * sizeof(int64));
		char **chunk_tables = palloc(n_items * sizeof(char *));
		const char **contents = palloc(n_items * sizeof(char *));
		int *attempts = palloc(n_items * sizeof(int));
		int *max_attempts = palloc(n_items * sizeof(int));
		float **embeddings = NULL;
		int dim = 0;
		bool has_retries = false;
		int effective_batch_size = n_items;

		elog(DEBUG1, "Worker %d processing %d queue items", worker_id + 1, n_items);

		/* Extract data from result */
		for (int i = 0; i < n_items; i++)
		{
			bool isnull;
			Datum val;

			val = SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 1, &isnull);
			queue_ids[i] = DatumGetInt64(val);

			val = SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 2, &isnull);
			chunk_ids[i] = DatumGetInt64(val);

			val = SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 3, &isnull);
			chunk_tables[i] = TextDatumGetCString(val);

			val = SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 4, &isnull);
			contents[i] = TextDatumGetCString(val);

			val = SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 5, &isnull);
			attempts[i] = DatumGetInt32(val);

			val = SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 6, &isnull);
			max_attempts[i] = DatumGetInt32(val);

			if (attempts[i] > 0)
				has_retries = true;
		}

		/* If any items have been retried, process individually to isolate failures */
		if (has_retries && n_items > 1)
		{
			effective_batch_size = 1;
			elog(DEBUG1, "Worker %d: found retried items, processing individually", worker_id + 1);
		}

		/* Mark all as processing */
		for (int i = 0; i < n_items; i++)
		{
			SPI_execute(psprintf(
				"UPDATE pgedge_vectorizer.queue "
				"SET status = 'processing', processing_started_at = NOW() "
				"WHERE id = %ld",
				queue_ids[i]),
				false, 0);
		}

		/* Get the provider */
		provider = get_current_provider();
		if (provider == NULL)
		{
			elog(ERROR, "No provider configured");
		}

		/* Initialize provider if needed */
		if (!provider->init(&error_msg))
		{
			elog(ERROR, "Failed to initialize provider: %s",
				 error_msg ? error_msg : "unknown error");
		}

		/* Process items in batches of effective_batch_size */
		for (int batch_start = 0; batch_start < n_items; batch_start += effective_batch_size)
		{
			int batch_end;
			int batch_count;

			batch_end = batch_start + effective_batch_size;
			if (batch_end > n_items)
				batch_end = n_items;
			batch_count = batch_end - batch_start;

			/* Generate embeddings for this batch */
			embeddings = provider->generate_batch(&contents[batch_start], batch_count, &dim, &error_msg);

			if (embeddings != NULL)
			{
				/* Update chunk tables and mark as completed */
				for (int i = 0; i < batch_count; i++)
				{
					int idx = batch_start + i;
					PG_TRY();
					{
						update_embedding(chunk_ids[idx], chunk_tables[idx], embeddings[i], dim);

						/* Mark as completed */
						SPI_execute(psprintf(
							"UPDATE pgedge_vectorizer.queue "
							"SET status = 'completed', processed_at = NOW() "
							"WHERE id = %ld",
							queue_ids[idx]),
							false, 0);

						elog(DEBUG2, "Successfully processed queue item %ld", queue_ids[idx]);
					}
					PG_CATCH();
					{
						/* Check if retries remain */
						if (attempts[idx] + 1 >= max_attempts[idx])
						{
							/* No retries left - mark as permanently failed */
							SPI_execute(psprintf(
								"UPDATE pgedge_vectorizer.queue "
								"SET status = 'failed', "
								"    attempts = attempts + 1, "
								"    error_message = 'Failed to update embedding', "
								"    next_retry_at = NULL "
								"WHERE id = %ld",
								queue_ids[idx]),
								false, 0);
						}
						else
						{
							/* Retries remain - set back to pending with delay */
							SPI_execute(psprintf(
								"UPDATE pgedge_vectorizer.queue "
								"SET status = 'pending', "
								"    attempts = attempts + 1, "
								"    error_message = 'Failed to update embedding', "
								"    next_retry_at = NOW() + (attempts + 1) * INTERVAL '1 minute' "
								"WHERE id = %ld",
								queue_ids[idx]),
								false, 0);
						}

						/* Re-throw */
						PG_RE_THROW();
					}
					PG_END_TRY();
				}

				/* Free embeddings */
				for (int i = 0; i < batch_count; i++)
				{
					if (embeddings[i] != NULL)
						pfree(embeddings[i]);
				}
				pfree(embeddings);
			}
			else
			{
				/* Failed to generate embeddings - update status based on remaining retries */
				for (int i = 0; i < batch_count; i++)
				{
					int idx = batch_start + i;

					/* Check if retries remain */
					if (attempts[idx] + 1 >= max_attempts[idx])
					{
						/* No retries left - mark as permanently failed */
						SPI_execute(psprintf(
							"UPDATE pgedge_vectorizer.queue "
							"SET status = 'failed', "
							"    attempts = attempts + 1, "
							"    error_message = %s, "
							"    next_retry_at = NULL "
							"WHERE id = %ld",
							error_msg ? psprintf("'%s'", error_msg) : "NULL",
							queue_ids[idx]),
							false, 0);
					}
					else
					{
						/* Retries remain - set back to pending with exponential backoff */
						SPI_execute(psprintf(
							"UPDATE pgedge_vectorizer.queue "
							"SET status = 'pending', "
							"    attempts = attempts + 1, "
							"    error_message = %s, "
							"    next_retry_at = NOW() + (attempts + 1) * INTERVAL '1 minute' "
							"WHERE id = %ld",
							error_msg ? psprintf("'%s'", error_msg) : "NULL",
							queue_ids[idx]),
							false, 0);
					}
				}

				elog(WARNING, "Failed to generate embeddings for batch starting at %d: %s",
					 batch_start, error_msg ? error_msg : "unknown error");
			}
		}

		/* Cleanup */
		pfree(queue_ids);
		pfree(chunk_ids);
		pfree(chunk_tables);
		pfree(contents);
		pfree(attempts);
		pfree(max_attempts);
	}

	SPI_finish();
	PopActiveSnapshot();
	CommitTransactionCommand();
}

/*
 * Update a chunk table with the generated embedding
 */
static void
update_embedding(int64 chunk_id, const char *chunk_table, const float *embedding, int dim)
{
	StringInfoData vector_str;
	int ret;

	/* Build vector string: [0.1, 0.2, 0.3, ...] */
	initStringInfo(&vector_str);
	appendStringInfoChar(&vector_str, '[');
	for (int i = 0; i < dim; i++)
	{
		if (i > 0)
			appendStringInfoChar(&vector_str, ',');
		appendStringInfo(&vector_str, "%f", embedding[i]);
	}
	appendStringInfoChar(&vector_str, ']');

	/* Update the chunk table */
	ret = SPI_execute(psprintf(
		"UPDATE %s SET embedding = '%s'::vector WHERE id = %ld",
		chunk_table, vector_str.data, chunk_id),
		false, 0);

	if (ret != SPI_OK_UPDATE)
	{
		elog(ERROR, "Failed to update embedding in table %s for chunk %ld",
			 chunk_table, chunk_id);
	}

	pfree(vector_str.data);
}

/*
 * Clean up completed queue items older than auto_cleanup_hours
 */
static void
cleanup_completed_items(int worker_id)
{
	int ret;
	int rows_deleted = 0;
	time_t now;

	/* Skip if auto cleanup is disabled (set to 0) */
	if (pgedge_vectorizer_auto_cleanup_hours <= 0)
		return;

	/* Only perform cleanup once per hour (3600 seconds) */
	now = time(NULL);
	if (last_cleanup_time > 0 && (now - last_cleanup_time) < 3600)
		return;

	last_cleanup_time = now;

	StartTransactionCommand();

	SPI_connect();

	/* Delete completed items older than configured hours */
	ret = SPI_execute(psprintf(
		"DELETE FROM pgedge_vectorizer.queue "
		"WHERE status = 'completed' "
		"AND processed_at < NOW() - INTERVAL '%d hours'",
		pgedge_vectorizer_auto_cleanup_hours),
		false, 0);

	if (ret == SPI_OK_DELETE)
	{
		rows_deleted = SPI_processed;
		if (rows_deleted > 0)
		{
			elog(LOG, "pgedge_vectorizer worker %d: cleaned up %d completed queue items older than %d hours",
				 worker_id + 1, rows_deleted, pgedge_vectorizer_auto_cleanup_hours);
		}
	}

	SPI_finish();
	CommitTransactionCommand();
}

/*-------------------------------------------------------------------------
 *
 * worker.c
 *		Background worker implementation for async embedding generation
 *
 * This file implements the background worker that processes the embedding
 * queue and generates embeddings using configured providers.
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"
#include "bm25.h"

#include <time.h>

#include "commands/dbcommands.h"
#include "pgstat.h"
#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"
#include "storage/proc.h"
#include "storage/procsignal.h"
#include "tcop/tcopprot.h"
#include "utils/memutils.h"
#include "utils/ps_status.h"
#include "utils/timestamp.h"

/* Signal flags */
static volatile sig_atomic_t got_sigterm = false;
static volatile sig_atomic_t got_sighup = false;

/* Last cleanup timestamp */
static time_t last_cleanup_time = 0;

/*
 * Queue item whose processing was under way when an error escaped.
 *
 * A batch runs inside one transaction, so an error anywhere in it aborts the
 * lot: the 'processing' marks, any chunk rows already written, and any attempt
 * to record the failure. Bookkeeping written before the abort therefore cannot
 * survive it, which left attempts stuck at its original value however many
 * times an item was tried. max_attempts never tripped, next_retry_at was never
 * set, and a deterministically failing item was reclaimed on every poll.
 *
 * The identity of the item is kept here instead, in process-local memory that
 * the abort cannot touch, and the failure is recorded afterwards in a fresh
 * transaction. That is enough to restart the machinery the queue already has:
 * next_retry_at holds the item out of the claim, a non-zero attempts count
 * makes the worker process claimed items one at a time, and max_attempts
 * eventually moves it to 'failed'.
 */
static int64 failed_item_queue_id = -1;
static int	failed_item_attempts = 0;
static int	failed_item_max_attempts = 0;

/*
 * Launcher state
 *
 * All of this is process-local: there is deliberately no shared memory
 * segment, which avoids RequestAddinShmemSpace() and the shmem_request_hook
 * that does not exist before PostgreSQL 15.
 *
 * The cost is that a restarted launcher cannot rediscover workers started by
 * its predecessor, so a launcher crash may briefly leave two workers on one
 * database. Queue rows are claimed with FOR UPDATE SKIP LOCKED, so concurrent
 * workers take disjoint rows for as long as they hold their claims. A claim
 * does not outlive an abort, though, so a row whose worker failed can be taken
 * up by the other before the first records the failure; queue_item_record_failure()
 * matches on the state it last saw rather than on the row id alone.
 */
typedef struct LauncherSlot
{
	char		dbname[NAMEDATALEN];
	BackgroundWorkerHandle *handle;
	bool		terminating;	/* asked to stop; awaiting confirmation */
	TimestampTz spawn_time;		/* when this worker was registered */
} LauncherSlot;

static LauncherSlot launcher_slots[PGEDGE_VECTORIZER_MAX_WORKERS];
static int	launcher_nslots = 0;
static int	launcher_cursor = 0;	/* round-robin position in the database list */

/*
 * Failed-start backoff.
 *
 * A worker that cannot start at all, because its database does not exist or
 * will not accept connections, exits within a few milliseconds, and the exit
 * notification brings the launcher straight back round to spawn a replacement.
 * Nothing in the spawn path rate limits that, so the launcher forks as fast as
 * the postmaster will oblige: left alone it burns thousands of PIDs a minute
 * and fills the log at a comparable rate. A single mistyped name in
 * pgedge_vectorizer.databases is enough to provoke it.
 *
 * A worker is judged to have failed to start if it exits within
 * LAUNCHER_FAILED_START_MS of being spawned. Its database is then held off for
 * an interval that doubles on each successive failure, from
 * LAUNCHER_RETRY_INTERVAL_MIN_MS up to LAUNCHER_RETRY_INTERVAL_MAX_MS, which
 * mirrors the extension-not-installed backoff in
 * pgedge_vectorizer_worker_main(). A worker that lives longer than the
 * threshold clears its database's backoff, so a database that recovers is
 * serviced at full speed again.
 *
 * The threshold sits below the one second minimum of
 * pgedge_vectorizer.worker_service_quantum, so a worker yielding its slot at
 * the end of a quantum can never be mistaken for one that failed to start. It
 * is still two orders of magnitude more than a failing worker needs to reach
 * its FATAL, so the distinction is not a fine one in practice.
 *
 * This state is keyed by database name rather than held on the slot, because
 * launcher_reap_workers() drops the slot at the moment the worker exits and
 * the backoff has to outlive it.
 */
#define LAUNCHER_FAILED_START_MS			500
#define LAUNCHER_RETRY_INTERVAL_MIN_MS		5000
#define LAUNCHER_RETRY_INTERVAL_MAX_MS		300000

typedef struct LauncherBackoff
{
	char		dbname[NAMEDATALEN];
	int			interval_ms;	/* interval applied for the latest failure */
	TimestampTz retry_after;	/* no further attempt before this */
} LauncherBackoff;

static LauncherBackoff *launcher_backoffs = NULL;
static int	launcher_nbackoffs = 0;
static int	launcher_backoffs_size = 0;

/*
 * Sweep intervals.
 *
 * Workers are registered with bgw_notify_pid set to the launcher, and the
 * launcher installs procsignal_sigusr1_handler, so the postmaster's exit
 * notification sets the launcher's latch and a freed slot is normally refilled
 * within milliseconds. See the signal setup in
 * pgedge_vectorizer_launcher_main() for why the handler has to be installed
 * explicitly.
 *
 * These intervals are therefore a backstop rather than the mechanism: they
 * bound how quickly the launcher notices something no notification covers,
 * chiefly a configuration change that neither started nor stopped a worker.
 * Sweep briskly whilst databases are queued waiting for a turn, since a missed
 * wakeup there costs throughput, and rarely once every database has its own
 * resident worker.
 *
 * Whichever applies is shortened when a failed-start backoff is due to expire
 * sooner, so that a database being retried does not wait out the idle sweep.
 */
#define LAUNCHER_SWEEP_INTERVAL_ROTATING_MS		1000
#define LAUNCHER_SWEEP_INTERVAL_IDLE_MS			60000

/* Forward declarations */
static void worker_sigterm(SIGNAL_ARGS);
static void worker_sighup(SIGNAL_ARGS);
static void queue_item_begin(int64 queue_id, int attempts, int max_attempts);
static void queue_item_done(void);
static void queue_item_record_failure(void);
static void process_queue_batch(const char *dbname);
static void cleanup_completed_items(const char *dbname);
static void update_embedding(int64 chunk_id, const char *chunk_table,
							 const float *embedding, int dim);
static char *trim_whitespace(char *str);
static int	parse_database_list(char ***names);
static int	worker_quantum_secs(void);
static void launcher_retire_surplus(void);
static void launcher_retire_unconfigured(char **db_names, int db_count);
static int	launcher_reload_databases(char ***db_names, int old_count,
									  bool *logged_empty);
static BackgroundWorkerHandle *launch_worker_for_database(const char *dbname);
static void launcher_reap_workers(void);
static bool database_has_worker(const char *dbname);
static void launcher_sweep(char **db_names, int db_count);
static LauncherBackoff *launcher_backoff_find(const char *dbname);
static void launcher_backoff_record(const char *dbname);
static void launcher_backoff_clear(const char *dbname);
static void launcher_backoff_prune(char **db_names, int db_count);
static long launcher_backoff_next_retry_ms(TimestampTz now);

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
 * queue_item_begin — note the item about to be worked on.
 *
 * Called before anything that could raise, so that a failure can be charged to
 * the right row once the aborted transaction has been cleaned up.
 */
static void
queue_item_begin(int64 queue_id, int attempts, int max_attempts)
{
	failed_item_queue_id = queue_id;
	failed_item_attempts = attempts;
	failed_item_max_attempts = max_attempts;
}

/*
 * queue_item_done — the item completed, so there is nothing to charge.
 */
static void
queue_item_done(void)
{
	failed_item_queue_id = -1;
}

/*
 * queue_item_record_failure — charge the noted item for a failed attempt.
 *
 * Must run after the failed transaction has been aborted, since it opens one
 * of its own. Errors here are swallowed: this is already the error path, and
 * losing the bookkeeping is preferable to taking the worker down with it. The
 * item is cleared either way, so a persistent problem recording failures
 * cannot make the worker retry the same row forever on that account.
 */
static void
queue_item_record_failure(void)
{
	int64	queue_id = failed_item_queue_id;
	int		attempts = failed_item_attempts;
	bool	exhausted;

	if (queue_id < 0)
		return;

	exhausted = (failed_item_attempts + 1 >= failed_item_max_attempts);
	queue_item_done();

	/*
	 * Everything, including the transaction setup, sits inside the handler:
	 * this runs from the worker's own PG_CATCH, which is not a handler for
	 * errors raised within it, so anything escaping here would take the
	 * worker down rather than being swallowed as intended.
	 */
	PG_TRY();
	{
		SetCurrentStatementStartTimestamp();
		StartTransactionCommand();
		PushActiveSnapshot(GetTransactionSnapshot());
		SPI_connect();

		/*
		 * Match on the state this worker last saw.  A launcher restart can
		 * briefly leave two workers on one database, and the abort that
		 * brought us here released this row's lock, so another worker may
		 * have claimed and finished it in the meantime.  Updating on id
		 * alone would then revive a completed item as pending, or mark a
		 * succeeded one failed.
		 *
		 * The qualified UPDATE is sufficient on its own: under READ
		 * COMMITTED it takes the row lock and re-checks its WHERE clause
		 * against the newest version of the row, so a row that has moved on
		 * simply fails the match and is left alone.
		 */
		if (exhausted)
			SPI_execute(psprintf(
				"UPDATE pgedge_vectorizer.queue "
				"SET status = 'failed', "
				"    attempts = attempts + 1, "
				"    error_message = 'Processing failed', "
				"    next_retry_at = NULL "
				"WHERE id = " INT64_FORMAT
				"  AND status = 'pending' AND attempts = %d",
				queue_id, attempts), false, 0);
		else
			SPI_execute(psprintf(
				"UPDATE pgedge_vectorizer.queue "
				"SET status = 'pending', "
				"    attempts = attempts + 1, "
				"    error_message = 'Processing failed', "
				"    next_retry_at = NOW() + (attempts + 1) * INTERVAL '1 minute' "
				"WHERE id = " INT64_FORMAT
				"  AND status = 'pending' AND attempts = %d",
				queue_id, attempts), false, 0);

		if (SPI_processed == 0)
			elog(DEBUG1, "pgedge_vectorizer worker: queue item " INT64_FORMAT
				 " changed underneath, leaving it alone", queue_id);

		SPI_finish();
		PopActiveSnapshot();
		CommitTransactionCommand();
	}
	PG_CATCH();
	{
		EmitErrorReport();
		FlushErrorState();
		AbortCurrentTransaction();
		elog(LOG, "pgedge_vectorizer worker: could not record failure for "
			 "queue item " INT64_FORMAT, queue_id);
	}
	PG_END_TRY();
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

	memset(&worker, 0, sizeof(BackgroundWorker));

	/*
	 * The launcher needs shared memory access so that it can register dynamic
	 * workers, but deliberately takes no database connection: the database
	 * list comes from a GUC rather than the catalogue, so it needs neither SPI
	 * nor a backend. That keeps its crash surface very small.
	 */
	worker.bgw_flags = BGWORKER_SHMEM_ACCESS;
	worker.bgw_start_time = BgWorkerStart_RecoveryFinished;
	worker.bgw_restart_time = 10;  /* Restart after 10 seconds if it crashes */

	snprintf(worker.bgw_library_name, BGW_MAXLEN, "pgedge_vectorizer");
	snprintf(worker.bgw_function_name, BGW_MAXLEN,
			 "pgedge_vectorizer_launcher_main");
	snprintf(worker.bgw_name, BGW_MAXLEN, "pgedge_vectorizer launcher");
	snprintf(worker.bgw_type, BGW_MAXLEN, "pgedge_vectorizer");

	worker.bgw_main_arg = (Datum) 0;
	worker.bgw_notify_pid = 0;

	RegisterBackgroundWorker(&worker);
}

/*
 * Trim leading and trailing spaces and tabs from a token, returning a pointer
 * into the original buffer.
 *
 * The length is measured with strnlen() bounded by NAMEDATALEN rather than with
 * strlen(). A database name longer than that cannot be valid and would be
 * truncated by strlcpy() when we come to use it, and the bound means we cannot
 * over-read even if handed a buffer that is somehow not NUL-terminated
 * (CWE-126).
 */
static char *
trim_whitespace(char *str)
{
	size_t		len;

	while (*str == ' ' || *str == '\t')
		str++;

	len = strnlen(str, NAMEDATALEN);
	while (len > 0 && (str[len - 1] == ' ' || str[len - 1] == '\t'))
		str[--len] = '\0';

	return str;
}

/*
 * Parse pgedge_vectorizer.databases into a palloc'd array of trimmed names.
 *
 * Returns the number of names found, with *names set to a palloc'd array of
 * palloc'd strings. Returns 0 with *names set to NULL when nothing is
 * configured. Empty entries produced by stray commas are skipped.
 */
static int
parse_database_list(char ***names)
{
	char	   *list;
	char	   *tok;
	char	   *saveptr = NULL;
	char	  **result;
	int			count = 0;
	int			capacity = 8;

	if (pgedge_vectorizer_databases == NULL ||
		pgedge_vectorizer_databases[0] == '\0')
	{
		*names = NULL;
		return 0;
	}

	result = palloc(capacity * sizeof(char *));
	list = pstrdup(pgedge_vectorizer_databases);

	/*
	 * Use strtok_r() rather than strtok(): the latter keeps its parsing
	 * position in a single process-wide static, so any other strtok() caller
	 * reached from this loop would silently corrupt it.
	 */
	for (tok = strtok_r(list, ",", &saveptr); tok != NULL;
		 tok = strtok_r(NULL, ",", &saveptr))
	{
		char	   *name = trim_whitespace(tok);

		if (name[0] == '\0')
			continue;

		if (count == capacity)
		{
			capacity *= 2;
			result = repalloc(result, capacity * sizeof(char *));
		}

		result[count++] = pstrdup(name);
	}

	pfree(list);
	*names = result;
	return count;
}

/*
 * How long may a worker hold its slot before yielding it?
 *
 * Zero means stay resident, which is correct whenever every configured database
 * can have a worker of its own.
 *
 * Whether we are oversubscribed is a pure function of the database count and
 * the concurrency cap, so a worker can evaluate this itself rather than being
 * told at spawn time, and must re-evaluate it after every reload. A worker that
 * latched the value at startup would stay resident forever after a reload that
 * added databases, starving the additions exactly as the old static assignment
 * starved anything beyond num_workers.
 */
static int
worker_quantum_secs(void)
{
	char	  **db_names;
	int			db_count;
	int			quantum;

	db_count = parse_database_list(&db_names);

	quantum = (db_count > pgedge_vectorizer_num_workers)
		? pgedge_vectorizer_worker_service_quantum
		: 0;

	for (int i = 0; i < db_count; i++)
		pfree(db_names[i]);
	if (db_names != NULL)
		pfree(db_names);

	return quantum;
}

/*
 * Spawn a worker for one database.
 *
 * Returns the handle, or NULL when no worker slot could be obtained, which
 * normally means max_worker_processes is exhausted.
 */
static BackgroundWorkerHandle *
launch_worker_for_database(const char *dbname)
{
	BackgroundWorker worker;
	BackgroundWorkerHandle *handle;

	memset(&worker, 0, sizeof(BackgroundWorker));

	worker.bgw_flags = BGWORKER_SHMEM_ACCESS |
					   BGWORKER_BACKEND_DATABASE_CONNECTION;
	worker.bgw_start_time = BgWorkerStart_RecoveryFinished;

	/*
	 * The launcher owns respawn, so the postmaster must not resurrect a worker
	 * for a database that has since been removed from the configuration.
	 */
	worker.bgw_restart_time = BGW_NEVER_RESTART;

	snprintf(worker.bgw_library_name, BGW_MAXLEN, "pgedge_vectorizer");
	snprintf(worker.bgw_function_name, BGW_MAXLEN,
			 "pgedge_vectorizer_worker_main");
	snprintf(worker.bgw_name, BGW_MAXLEN,
			 "pgedge_vectorizer worker (%s)", dbname);
	snprintf(worker.bgw_type, BGW_MAXLEN, "pgedge_vectorizer");

	/*
	 * bgw_main_arg is a single Datum and cannot carry a string, so the target
	 * database name travels in bgw_extra. The worker works out its own service
	 * quantum from the GUCs, so nothing else needs passing: were the launcher
	 * to pass it at spawn time, the value would go stale on the next reload.
	 */
	worker.bgw_main_arg = (Datum) 0;
	strlcpy(worker.bgw_extra, dbname, NAMEDATALEN);

	/* Be signalled when this worker starts or stops */
	worker.bgw_notify_pid = MyProcPid;

	if (!RegisterDynamicBackgroundWorker(&worker, &handle))
		return NULL;

	return handle;
}

/*
 * Find the backoff entry for a database, or NULL if it has none.
 */
static LauncherBackoff *
launcher_backoff_find(const char *dbname)
{
	for (int i = 0; i < launcher_nbackoffs; i++)
	{
		if (strcmp(launcher_backoffs[i].dbname, dbname) == 0)
			return &launcher_backoffs[i];
	}

	return NULL;
}

/*
 * Note that a worker for this database failed to start, and hold the database
 * off for a while before trying again.
 *
 * The interval doubles on each consecutive failure, so a database that is
 * briefly unavailable is retried promptly whilst one that is misconfigured
 * settles at a rate that costs nothing to leave running indefinitely.
 */
static void
launcher_backoff_record(const char *dbname)
{
	LauncherBackoff *entry = launcher_backoff_find(dbname);

	if (entry == NULL)
	{
		/*
		 * Entries are bounded by the number of configured databases, since
		 * launcher_backoff_prune() drops those that leave the list.
		 */
		if (launcher_nbackoffs >= launcher_backoffs_size)
		{
			int			newsize = (launcher_backoffs_size == 0)
				? 8 : launcher_backoffs_size * 2;

			if (launcher_backoffs == NULL)
				launcher_backoffs = palloc(newsize * sizeof(LauncherBackoff));
			else
				launcher_backoffs = repalloc(launcher_backoffs,
											 newsize * sizeof(LauncherBackoff));
			launcher_backoffs_size = newsize;
		}

		entry = &launcher_backoffs[launcher_nbackoffs++];
		strlcpy(entry->dbname, dbname, NAMEDATALEN);
		entry->interval_ms = LAUNCHER_RETRY_INTERVAL_MIN_MS;
	}
	else
	{
		entry->interval_ms = Min(entry->interval_ms * 2,
								 LAUNCHER_RETRY_INTERVAL_MAX_MS);
	}

	entry->retry_after = TimestampTzPlusMilliseconds(GetCurrentTimestamp(),
													entry->interval_ms);

	elog(LOG, "pgedge_vectorizer launcher: worker for database \"%s\" exited "
		 "immediately, retrying in %dms", dbname, entry->interval_ms);
}

/*
 * Forget any backoff for a database, so that it is serviced at full speed
 * again once a worker of its own has run successfully.
 */
static void
launcher_backoff_clear(const char *dbname)
{
	LauncherBackoff *entry = launcher_backoff_find(dbname);

	if (entry == NULL)
		return;

	/* Compact the array by moving the final entry into the hole */
	*entry = launcher_backoffs[launcher_nbackoffs - 1];
	launcher_nbackoffs--;
}

/*
 * Drop backoff entries for databases that are no longer configured, so that
 * the array cannot outgrow the database list.
 *
 * Removing a database and putting it back therefore earns it an immediate
 * attempt, which is the right answer: the operator has just changed something.
 */
static void
launcher_backoff_prune(char **db_names, int db_count)
{
	int			i = 0;

	while (i < launcher_nbackoffs)
	{
		bool		still_configured = false;

		for (int j = 0; j < db_count; j++)
		{
			if (strcmp(launcher_backoffs[i].dbname, db_names[j]) == 0)
			{
				still_configured = true;
				break;
			}
		}

		if (still_configured)
			i++;
		else
		{
			launcher_backoffs[i] = launcher_backoffs[launcher_nbackoffs - 1];
			launcher_nbackoffs--;
		}
	}
}

/*
 * Milliseconds until the earliest retry still in the future, or -1 if there is
 * none to wait for.
 *
 * Entries that have already come due are skipped rather than reported as due
 * now. The sweep will have taken any it could, so one still sitting here is
 * waiting on a worker slot rather than on the clock, and returning a zero or
 * one millisecond timeout for it would spin the launcher until a slot freed.
 * The exit notification covers that case, and the sweep interval backs it up.
 *
 * Never returns zero, so a sub-millisecond wait cannot spin either.
 */
static long
launcher_backoff_next_retry_ms(TimestampTz now)
{
	long		earliest = -1;

	for (int i = 0; i < launcher_nbackoffs; i++)
	{
		long		secs;
		int			usecs;
		long		msecs;

		if (launcher_backoffs[i].retry_after <= now)
			continue;

		TimestampDifference(now, launcher_backoffs[i].retry_after,
							&secs, &usecs);
		msecs = secs * 1000 + usecs / 1000;

		if (msecs < 1)
			msecs = 1;

		if (earliest < 0 || msecs < earliest)
			earliest = msecs;
	}

	return earliest;
}

/*
 * Drop tracking entries for workers that have exited.
 */
static void
launcher_reap_workers(void)
{
	int			i = 0;
	TimestampTz now = GetCurrentTimestamp();

	while (i < launcher_nslots)
	{
		pid_t		pid;

		if (GetBackgroundWorkerPid(launcher_slots[i].handle, &pid) == BGWH_STOPPED)
		{
			/*
			 * A worker that exited almost as soon as it was spawned never got
			 * as far as doing any work, so hold its database off rather than
			 * spinning on it. One we asked to stop does not count, however
			 * promptly it obliged.
			 */
			if (!launcher_slots[i].terminating &&
				!TimestampDifferenceExceeds(launcher_slots[i].spawn_time, now,
											LAUNCHER_FAILED_START_MS))
				launcher_backoff_record(launcher_slots[i].dbname);
			else
				launcher_backoff_clear(launcher_slots[i].dbname);

			pfree(launcher_slots[i].handle);

			/* Compact the array by moving the final entry into the hole */
			launcher_slots[i] = launcher_slots[launcher_nslots - 1];
			launcher_nslots--;
		}
		else
			i++;
	}
}

/*
 * Is this database already covered?
 *
 * Workers that have been asked to stop still count, so that we do not spawn a
 * replacement alongside one that is still shutting down.
 */
static bool
database_has_worker(const char *dbname)
{
	for (int i = 0; i < launcher_nslots; i++)
	{
		if (strcmp(launcher_slots[i].dbname, dbname) == 0)
			return true;
	}

	return false;
}

/*
 * Stop the newest workers until no more than num_workers remain, so that
 * lowering num_workers takes effect without waiting for workers to yield.
 */
static void
launcher_retire_surplus(void)
{
	int			live = 0;

	for (int i = 0; i < launcher_nslots; i++)
	{
		if (!launcher_slots[i].terminating)
			live++;
	}

	for (int i = launcher_nslots - 1;
		 i >= 0 && live > pgedge_vectorizer_num_workers; i--)
	{
		if (launcher_slots[i].terminating)
			continue;

		elog(LOG, "pgedge_vectorizer launcher: retiring worker for database "
			 "\"%s\" after num_workers was lowered",
			 launcher_slots[i].dbname);
		TerminateBackgroundWorker(launcher_slots[i].handle);
		launcher_slots[i].terminating = true;
		live--;
	}
}

/*
 * Stop workers whose database is no longer configured, so that removing a
 * database from pgedge_vectorizer.databases actually releases it.
 */
static void
launcher_retire_unconfigured(char **db_names, int db_count)
{
	for (int i = 0; i < launcher_nslots; i++)
	{
		bool		still_configured = false;

		if (launcher_slots[i].terminating)
			continue;

		for (int j = 0; j < db_count; j++)
		{
			if (strcmp(launcher_slots[i].dbname, db_names[j]) == 0)
			{
				still_configured = true;
				break;
			}
		}

		if (still_configured)
			continue;

		elog(LOG, "pgedge_vectorizer launcher: stopping worker for database "
			 "\"%s\", no longer configured", launcher_slots[i].dbname);
		TerminateBackgroundWorker(launcher_slots[i].handle);
		launcher_slots[i].terminating = true;
	}
}

/*
 * One pass over the database list, spawning workers where they are missing.
 *
 * Databases are visited from a persistent cursor rather than always from the
 * head of the list. Combined with the service quantum that makes busy workers
 * relinquish their slots, this is what guarantees that every database is
 * eventually serviced when there are more databases than slots.
 */
static void
launcher_sweep(char **db_names, int db_count)
{
	int			visited;
	bool		warned = false;
	TimestampTz now;

	if (db_count == 0)
		return;

	launcher_retire_surplus();

	now = GetCurrentTimestamp();

	for (visited = 0; visited < db_count; visited++)
	{
		int			idx = (launcher_cursor + visited) % db_count;
		const char *dbname = db_names[idx];
		LauncherBackoff *backoff;
		BackgroundWorkerHandle *handle;

		if (launcher_nslots >= pgedge_vectorizer_num_workers)
			break;

		if (database_has_worker(dbname))
			continue;

		/* Still serving out a failed-start backoff; leave it for a later pass */
		backoff = launcher_backoff_find(dbname);
		if (backoff != NULL && now < backoff->retry_after)
			continue;

		handle = launch_worker_for_database(dbname);
		if (handle == NULL)
		{
			if (!warned)
			{
				elog(LOG, "pgedge_vectorizer launcher: could not register a "
					 "worker for database \"%s\"; max_worker_processes may be "
					 "exhausted, will retry", dbname);
				warned = true;
			}
			break;
		}

		strlcpy(launcher_slots[launcher_nslots].dbname, dbname, NAMEDATALEN);
		launcher_slots[launcher_nslots].handle = handle;
		launcher_slots[launcher_nslots].terminating = false;
		launcher_slots[launcher_nslots].spawn_time = GetCurrentTimestamp();
		launcher_nslots++;
	}

	/* Start the next sweep further along, so every database gets a turn */
	launcher_cursor = (launcher_cursor + visited) % db_count;
}

/*
 * Re-read the configured database list, freeing the previous one.
 *
 * Returns the new count. *logged_empty tracks whether we have already
 * complained about an empty list, so that the complaint appears once rather
 * than on every sweep.
 */
static int
launcher_reload_databases(char ***db_names, int old_count, bool *logged_empty)
{
	int			db_count;

	if (*db_names != NULL)
	{
		for (int i = 0; i < old_count; i++)
			pfree((*db_names)[i]);
		pfree(*db_names);
		*db_names = NULL;
	}

	db_count = parse_database_list(db_names);

	launcher_backoff_prune(*db_names, db_count);

	if (db_count == 0)
	{
		if (!*logged_empty)
		{
			elog(LOG, "pgedge_vectorizer launcher: no databases configured in "
				 "pgedge_vectorizer.databases, waiting");
			*logged_empty = true;
		}

		return db_count;
	}

	*logged_empty = false;

	if (db_count > pgedge_vectorizer_num_workers)
		elog(LOG, "pgedge_vectorizer launcher: %d databases configured with "
			 "num_workers = %d, databases will be serviced in rotation",
			 db_count, pgedge_vectorizer_num_workers);

	return db_count;
}

/*
 * Launcher main entry point
 *
 * Spawns one dynamic worker per configured database, up to num_workers at a
 * time, and keeps doing so as workers exit and the configuration changes.
 *
 * Note: this process has no database connection and therefore no
 * PgBackendStatus entry, because that is allocated by InitPostgres() via
 * BackgroundWorkerInitializeConnection(). It must not call any pgstat_report_*
 * function.
 */
PGDLLEXPORT void
pgedge_vectorizer_launcher_main(Datum main_arg)
{
	char	  **db_names = NULL;
	int			db_count = 0;
	bool		reload_list = true;
	bool		logged_empty = false;

	/*
	 * Setup signal handlers.
	 *
	 * SIGUSR1 has to be handled explicitly. BackgroundWorkerMain() only
	 * installs procsignal_sigusr1_handler for workers that requested
	 * BGWORKER_BACKEND_DATABASE_CONNECTION, and points SIGUSR1 at SIG_IGN for
	 * everyone else. This launcher takes no database connection, so without
	 * this the bgw_notify_pid notification the postmaster sends when a worker
	 * exits would be discarded and refilling a slot would wait for the next
	 * sweep. contrib/pg_prewarm's leader does the same thing for the same
	 * reason; the handler is safe here because CheckProcSignal() ignores a
	 * process with no ProcSignal slot, leaving just the latch wakeup.
	 */
	pqsignal(SIGTERM, worker_sigterm);
	pqsignal(SIGHUP, worker_sighup);
	pqsignal(SIGUSR1, procsignal_sigusr1_handler);

	/* We're now ready to receive signals */
	BackgroundWorkerUnblockSignals();

	elog(LOG, "pgedge_vectorizer launcher started");

	while (!got_sigterm)
	{
		int			rc;
		long		sweep_interval;
		long		retry_ms;

		/* Reload configuration if SIGHUP received */
		if (got_sighup)
		{
			got_sighup = false;
			ProcessConfigFile(PGC_SIGHUP);
			reload_list = true;
		}

		if (reload_list)
		{
			db_count = launcher_reload_databases(&db_names, db_count,
												 &logged_empty);
			reload_list = false;
		}

		launcher_retire_unconfigured(db_names, db_count);
		launcher_reap_workers();
		launcher_sweep(db_names, db_count);

		/*
		 * Sweep briskly whilst databases are queued waiting for a slot, and
		 * rarely once every database has its own resident worker.
		 */
		sweep_interval = (db_count > pgedge_vectorizer_num_workers)
			? LAUNCHER_SWEEP_INTERVAL_ROTATING_MS
			: LAUNCHER_SWEEP_INTERVAL_IDLE_MS;

		/*
		 * Come back for the earliest pending retry if that falls sooner, so a
		 * backed-off database is not left waiting out the whole sweep.
		 */
		retry_ms = launcher_backoff_next_retry_ms(GetCurrentTimestamp());
		if (retry_ms >= 0 && retry_ms < sweep_interval)
			sweep_interval = retry_ms;

		rc = WaitLatch(MyLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   sweep_interval,
					   PG_WAIT_EXTENSION);

		ResetLatch(MyLatch);

		/* Emergency bailout if postmaster has died */
		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);
	}

	elog(LOG, "pgedge_vectorizer launcher shutting down");

	/* Workers are BGW_NEVER_RESTART and exit with the postmaster */
	proc_exit(0);
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
	int quantum_secs;
	char dbname[NAMEDATALEN];
	TimestampTz start_time;
	bool extension_exists = false;
	int ext_retry_interval = 5000;	/* Start at 5s, doubles up to max */
	bool first_ext_check = true;
#define EXT_RETRY_MAX	300000		/* Cap at 5 minutes */

	/* Setup signal handlers */
	pqsignal(SIGTERM, worker_sigterm);
	pqsignal(SIGHUP, worker_sighup);

	/* We're now ready to receive signals */
	BackgroundWorkerUnblockSignals();

	/*
	 * The launcher passes our target database in bgw_extra, because
	 * bgw_main_arg is a single Datum and cannot carry a string.
	 *
	 * Deciding which databases are covered is the launcher's job, so there is
	 * no database list parsing here any more, beyond working out our own
	 * service quantum below.
	 */
	strlcpy(dbname, MyBgworkerEntry->bgw_extra, NAMEDATALEN);

	if (dbname[0] == '\0')
	{
		elog(LOG, "pgedge_vectorizer worker started without a database name, exiting");
		proc_exit(0);
	}

	start_time = GetCurrentTimestamp();
	quantum_secs = worker_quantum_secs();

	/* Connect to the database the launcher assigned us */
	BackgroundWorkerInitializeConnection(dbname, NULL, 0);

	elog(LOG, "pgedge_vectorizer worker started (database: %s)", dbname);

	/* Set process display */
	pgstat_report_appname(psprintf("pgedge_vectorizer worker (%s)", dbname));

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
			ext_retry_interval = 5000;

			/*
			 * Re-evaluate our quantum: a reload may have added databases or
			 * lowered the cap, turning a resident worker into one that must
			 * yield its slot so the additions get serviced.
			 */
			quantum_secs = worker_quantum_secs();
		}

		/* Check if extension is installed (periodically recheck) */
		if (!extension_exists)
		{
			PG_TRY();
			{
				extension_exists = extension_installed();
				if (!extension_exists)
				{
					if (first_ext_check)
					{
						elog(LOG, "pgedge_vectorizer worker: extension not installed in database '%s', "
							 "will check again in %ds (hint: run CREATE EXTENSION pgedge_vectorizer)",
							 dbname, ext_retry_interval / 1000);
						first_ext_check = false;
					}
					else if (ext_retry_interval >= EXT_RETRY_MAX)
					{
						elog(LOG, "pgedge_vectorizer worker: extension still not installed in database '%s', "
							 "next check in %ds",
							 dbname, ext_retry_interval / 1000);
					}
				}
				else
				{
					elog(LOG, "pgedge_vectorizer worker: extension found in database '%s', starting to process queue",
						 dbname);
					ext_retry_interval = 5000;
					first_ext_check = true;
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
		wait_time = extension_exists ? pgedge_vectorizer_worker_poll_interval : ext_retry_interval;

		/* Wait for work or timeout */
		rc = WaitLatch(MyLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   wait_time,
					   PG_WAIT_EXTENSION);

		ResetLatch(MyLatch);

		/* Emergency bailout if postmaster has died */
		if (rc & WL_POSTMASTER_DEATH)
			proc_exit(1);

		/*
		 * Yield our slot once the service quantum expires, so that the
		 * launcher can hand it to the next database in the rotation. A worker
		 * that always has work would otherwise keep its slot indefinitely and
		 * starve the databases behind it.
		 *
		 * A quantum of zero means the launcher is not oversubscribed and every
		 * configured database can have its own worker, so we stay resident.
		 * That is the common case and involves no process churn at all.
		 */
		if (quantum_secs > 0 &&
			TimestampDifferenceExceeds(start_time, GetCurrentTimestamp(),
									   quantum_secs * 1000))
		{
			elog(LOG, "pgedge_vectorizer worker for database \"%s\" yielding its "
				 "slot after %d seconds so that another database can be serviced",
				 dbname, quantum_secs);
			break;
		}

		/* Only process queue if extension is installed */
		if (!extension_exists)
		{
			ext_retry_interval = Min(ext_retry_interval * 2, EXT_RETRY_MAX);
			continue;
		}

		/* Process pending queue items */
		pgstat_report_activity(STATE_RUNNING, "processing embedding queue");

		PG_TRY();
		{
			process_queue_batch(dbname);

			/* Perform automatic cleanup if enabled */
			cleanup_completed_items(dbname);
		}
		PG_CATCH();
		{
			EmitErrorReport();
			FlushErrorState();

			/* Don't exit on errors - log and continue */
			elog(LOG, "pgedge_vectorizer worker for database \"%s\": error in "
				 "processing, continuing", dbname);

			/* Abort any transaction */
			AbortCurrentTransaction();

			/*
			 * Charge the item that was in flight.  The abort above has to
			 * come first, since the record is written in a transaction of
			 * its own and none can be started until this one is cleared.
			 * Without it the attempt is discarded along with everything else
			 * and the same row is reclaimed on the next poll, indefinitely.
			 */
			queue_item_record_failure();

			/* Recheck extension status on error */
			extension_exists = false;
		}
		PG_END_TRY();
	}

	/* Cleanup before exit */
	elog(LOG, "pgedge_vectorizer worker for database \"%s\" shutting down", dbname);
	proc_exit(0);
}

/*
 * Process a batch of queue items
 */
static void
process_queue_batch(const char *dbname)
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
		"SELECT id, chunk_id, chunk_table, content, attempts, max_attempts, "
		"       COALESCE((metadata->>'sparse_only')::boolean, false) AS sparse_only "
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
		int *content_lens = palloc(n_items * sizeof(int));
		int *attempts = palloc(n_items * sizeof(int));
		int *max_attempts = palloc(n_items * sizeof(int));
		bool *sparse_only = palloc(n_items * sizeof(bool));
		float **embeddings = NULL;
		int dim = 0;
		bool has_retries = false;
		bool has_sparse_only = false;
		int effective_batch_size = n_items;

		elog(DEBUG1, "Worker for database \"%s\" processing %d queue items",
			 dbname, n_items);

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
			content_lens[i] = (int) VARSIZE_ANY_EXHDR(DatumGetTextPP(val));
			contents[i] = TextDatumGetCString(val);

			val = SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 5, &isnull);
			attempts[i] = DatumGetInt32(val);

			val = SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 6, &isnull);
			max_attempts[i] = DatumGetInt32(val);

			val = SPI_getbinval(SPI_tuptable->vals[i], SPI_tuptable->tupdesc, 7, &isnull);
			sparse_only[i] = (!isnull && DatumGetBool(val));

			if (attempts[i] > 0)
				has_retries = true;
		}

		/* Dense embedding already present means this item can be sparse-only. */
		for (int i = 0; i < n_items; i++)
		{
			bool	isnull = false;
			int		ret_dense;
			Datum	val;

			/*
			 * Charge this row if the probe raises.  A chunk table named by
			 * the queue but since dropped fails here, well before the loop
			 * that processes the items, so noting the item only there would
			 * leave this failure uncharged.
			 */
			queue_item_begin(queue_ids[i], attempts[i], max_attempts[i]);

			ret_dense = SPI_execute(psprintf(
				"SELECT embedding IS NOT NULL FROM %s WHERE id = %ld",
				quote_identifier(chunk_tables[i]),
				chunk_ids[i]),
				true, 1);

			if (ret_dense == SPI_OK_SELECT && SPI_processed == 1)
			{
				val = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
				if (!isnull && DatumGetBool(val))
					sparse_only[i] = true;
			}

			if (sparse_only[i])
				has_sparse_only = true;
		}

		/*
		 * Stop charging the last probed item.  What follows — marking the
		 * batch, resolving the provider, generating embeddings — either
		 * fails for the whole batch or for no single item in particular, and
		 * leaving one noted here would bill it for a fault that is not its
		 * own.  A misconfigured provider raises for every batch, so left
		 * uncleared it would work through the queue marking one blameless
		 * item failed per max_attempts cycles.
		 */
		queue_item_done();

		/* If any items have been retried, process individually to isolate failures */
		if (has_retries && n_items > 1)
		{
			effective_batch_size = 1;
			elog(DEBUG1, "Worker for database \"%s\": found retried items, "
				 "processing individually", dbname);
		}
		else if (has_sparse_only && n_items > 1)
		{
			effective_batch_size = 1;
			elog(DEBUG1, "Worker for database \"%s\": found sparse-only items, "
				 "processing individually", dbname);
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

			/* Skip dense generation when every item in this batch is sparse-only. */
			{
				bool batch_sparse_only = true;

				for (int i = 0; i < batch_count; i++)
				{
					int idx = batch_start + i;
					if (!sparse_only[idx])
					{
						batch_sparse_only = false;
						break;
					}
				}

				if (batch_sparse_only)
				{
					embeddings = palloc0(batch_count * sizeof(float *));
					dim = 0;
					error_msg = NULL;
				}
				else
				{
					/* Generate embeddings for this batch */
					embeddings = provider->generate_batch(&contents[batch_start], batch_count, &dim, &error_msg);
				}
			}

			if (embeddings != NULL)
			{
				/*
				 * Validate that the embedding dimension matches the chunk
				 * table's vector column. Check once per batch.
				 */
				if (!sparse_only[batch_start])
				{
					int idx0 = batch_start;
					int ret_dim;
					bool isnull_dim;
					Datum val_dim;

					ret_dim = SPI_execute(psprintf(
						"SELECT atttypmod FROM pg_attribute "
						"WHERE attrelid = '%s'::regclass "
						"AND attname = 'embedding'",
						chunk_tables[idx0]),
						true, 1);

					if (ret_dim == SPI_OK_SELECT && SPI_processed == 1)
					{
						val_dim = SPI_getbinval(SPI_tuptable->vals[0],
												SPI_tuptable->tupdesc, 1, &isnull_dim);
						if (!isnull_dim)
						{
							int table_dim = DatumGetInt32(val_dim);
							if (table_dim > 0 && table_dim != dim)
							{
								elog(WARNING, "Embedding dimension mismatch for table %s: "
									 "model returned %d dimensions but table expects %d. "
									 "Reconfigure pgedge_vectorizer.model or recreate the "
									 "chunk table with the correct dimension.",
									 chunk_tables[idx0], dim, table_dim);

								/* Fail all items in this batch */
								for (int i = 0; i < batch_count; i++)
								{
									int fidx = batch_start + i;
									SPI_execute(psprintf(
										"UPDATE pgedge_vectorizer.queue "
										"SET status = 'failed', "
										"    error_message = 'Dimension mismatch: model=%d, table=%d', "
										"    next_retry_at = NULL "
										"WHERE id = %ld",
										dim, table_dim, queue_ids[fidx]),
										false, 0);
								}

								/* Free embeddings and skip to next batch */
								for (int i = 0; i < batch_count; i++)
								{
									if (embeddings[i] != NULL)
										pfree(embeddings[i]);
								}
								pfree(embeddings);
								embeddings = NULL;
								continue;
							}
						}
					}
				}

				/* Update chunk tables and mark as completed */
				for (int i = 0; i < batch_count; i++)
				{
					int idx = batch_start + i;

					/*
					 * No handler here: a failure is charged to this item by
					 * the worker's own handler, from the identity noted
					 * below, once it has aborted the transaction.  Catching
					 * it locally could achieve nothing, since the queue
					 * cannot be updated from inside the aborted transaction
					 * and a re-throw would discard the update in any case.
					 */
					queue_item_begin(queue_ids[idx], attempts[idx],
									 max_attempts[idx]);
					if (!sparse_only[idx])
						update_embedding(chunk_ids[idx], chunk_tables[idx], embeddings[i], dim);
					else if (!pgedge_vectorizer_enable_hybrid)
						elog(ERROR, "cannot process sparse-only queue item while pgedge_vectorizer.enable_hybrid is disabled");

					/*
					 * BM25 sparse vector update (opt-in via
					 * pgedge_vectorizer.enable_hybrid GUC).
					 */
					if (pgedge_vectorizer_enable_hybrid)
					{
						int			ntokens;
						int			token_count = 0;
						bool		is_first_process = true;
						BM25Term   *tokens;
						HTAB	   *idf_htab;
						float8		avg_doc_len;
						char	   *sparse_str;
						int			ret_bm25;
						char	   *chunk_sql;

						/*
						 * Fetch token_count and check whether
						 * sparse_embedding is already set (for
						 * idempotency — skip IDF update on retry).
						 */
						chunk_sql = psprintf(
							"SELECT token_count, "
							"sparse_embedding IS NOT NULL "
							"FROM %s WHERE id = %ld",
							quote_identifier(chunk_tables[idx]),
							chunk_ids[idx]);
						ret_bm25 = SPI_execute(chunk_sql,
											   true, 1);
						pfree(chunk_sql);

						if (ret_bm25 == SPI_OK_SELECT &&
							SPI_processed > 0)
						{
							bool   isnull;
							Datum  v;

							v = SPI_getbinval(
								SPI_tuptable->vals[0],
								SPI_tuptable->tupdesc,
								1, &isnull);
							if (!isnull)
								token_count = DatumGetInt32(v);

							v = SPI_getbinval(
								SPI_tuptable->vals[0],
								SPI_tuptable->tupdesc,
								2, &isnull);
							if (!isnull)
								is_first_process =
									!DatumGetBool(v);

							/*
							 * Chunk row exists — proceed with BM25
							 * scoring and IDF stats update.
							 * Keeping this inside the SPI_processed > 0
							 * block ensures we bail out cleanly when
							 * the chunk has been concurrently deleted.
							 */
							if (token_count <= 0)
								token_count = 1;

							tokens = bm25_tokenize(contents[idx],
												   &ntokens);
							idf_htab = bm25_load_idf_stats(
									chunk_tables[idx], tokens, ntokens);
							avg_doc_len = bm25_avg_doc_len_internal(
									chunk_tables[idx]);
							sparse_str = bm25_compute_sparse_str(
									tokens, ntokens,
									idf_htab,
									pgedge_vectorizer_bm25_k1,
									pgedge_vectorizer_bm25_b,
									avg_doc_len,
									token_count);

							ret_bm25 = SPI_execute(
								psprintf(
									"UPDATE %s SET "
									"sparse_embedding = "
									"%s::sparsevec "
									"WHERE id = %ld",
									quote_identifier(chunk_tables[idx]),
									quote_literal_cstr(sparse_str),
									chunk_ids[idx]),
								false, 0);

							if (ret_bm25 != SPI_OK_UPDATE)
								elog(WARNING,
									 "Failed to update "
									 "sparse_embedding for "
									 "chunk " INT64_FORMAT,
									 chunk_ids[idx]);

							if (idf_htab != NULL)
								hash_destroy(idf_htab);

							/*
							 * Only update IDF stats the first time
							 * this chunk is processed — retries must
							 * not increment doc_freq again.
							 */
							if (is_first_process)
								bm25_update_idf_stats(
									chunk_tables[idx],
									tokens, ntokens);
						}
						/* else: chunk row gone (concurrent delete) —
						 * skip BM25 entirely to avoid inflating
						 * corpus stats for a nonexistent chunk.
						 */
					}

					/* Mark as completed */
					SPI_execute(psprintf(
						"UPDATE pgedge_vectorizer.queue "
						"SET status = 'completed', processed_at = NOW() "
						"WHERE id = %ld",
						queue_ids[idx]),
						false, 0);

					elog(DEBUG2, "Successfully processed queue item %ld", queue_ids[idx]);
					queue_item_done();
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
				/*
				 * Failed to generate embeddings - update status based on
				 * remaining retries.
				 *
				 * error_msg is quoted with quote_literal_cstr() rather than
				 * wrapped in quotes by hand.  A provider's message is
				 * arbitrary text and several carry an apostrophe of their
				 * own -- "Invalid response: 'data' field not found", for one
				 * -- which built invalid SQL and raised from the very code
				 * meant to record the failure, leaving the batch aborted with
				 * nothing charged and the items reclaimed on the next poll.
				 */
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
							error_msg ? quote_literal_cstr(error_msg) : "NULL",
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
							error_msg ? quote_literal_cstr(error_msg) : "NULL",
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
		pfree(sparse_only);
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

	if (SPI_processed == 0)
	{
		elog(WARNING, "Chunk " INT64_FORMAT " not found in table %s "
			 "(may have been deleted by a concurrent source update)",
			 chunk_id, chunk_table);
	}

	pfree(vector_str.data);
}

/*
 * Clean up completed queue items older than auto_cleanup_hours
 */
static void
cleanup_completed_items(const char *dbname)
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
	PushActiveSnapshot(GetTransactionSnapshot());

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
			elog(LOG, "pgedge_vectorizer worker for database \"%s\": cleaned up %d "
				 "completed queue items older than %d hours",
				 dbname, rows_deleted, pgedge_vectorizer_auto_cleanup_hours);
		}
	}

	SPI_finish();

	PopActiveSnapshot();
	CommitTransactionCommand();
}

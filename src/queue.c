/*-------------------------------------------------------------------------
 *
 * queue.c
 *		Queue management and monitoring functions
 *
 * This file implements SQL-callable functions for managing and monitoring
 * the embedding queue.
 *
 * Portions copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"
#include "funcapi.h"
#include "catalog/pg_type.h"

/*
 * Get queue status summary
 *
 * Returns a table showing the count of items in each status.
 */
PG_FUNCTION_INFO_V1(pgedge_vectorizer_queue_status);

Datum
pgedge_vectorizer_queue_status(PG_FUNCTION_ARGS)
{
	/* This will be implemented as a SQL view in the schema file */
	elog(ERROR, "pgedge_vectorizer_queue_status should be called via SQL view");
	PG_RETURN_NULL();
}

/*
 * Get worker statistics
 *
 * Returns statistics about worker activity.
 */
PG_FUNCTION_INFO_V1(pgedge_vectorizer_worker_stats);

Datum
pgedge_vectorizer_worker_stats(PG_FUNCTION_ARGS)
{
	/* This will be implemented as a SQL view in the schema file */
	elog(ERROR, "pgedge_vectorizer_worker_stats should be called via SQL view");
	PG_RETURN_NULL();
}

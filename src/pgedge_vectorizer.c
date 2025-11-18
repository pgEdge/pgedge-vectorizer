/*-------------------------------------------------------------------------
 *
 * pgedge_vectorizer.c
 *		Main entry point for pgEdge Vectorizer extension
 *
 * This file contains the extension initialization code and module magic.
 * It coordinates GUC setup, provider registration, and background worker
 * registration.
 *
 * Copyright (c) 2025, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"

PG_MODULE_MAGIC;

/*
 * Extension entry point - called when the extension is loaded
 */
void
_PG_init(void)
{
	/* Initialize GUC variables */
	pgedge_vectorizer_init_guc();

	/* Register embedding providers */
	register_embedding_providers();

	/* Register background workers if we're in the postmaster */
	if (process_shared_preload_libraries_in_progress)
	{
		register_background_workers();
		elog(LOG, "pgedge_vectorizer: %d background worker(s) registered",
			 pgedge_vectorizer_num_workers);
	}

	elog(LOG, "pgedge_vectorizer extension loaded (version 1.0)");
}

/*
 * Extension unload point (optional)
 */
void
_PG_fini(void)
{
	/* Cleanup code if needed */
	elog(LOG, "pgedge_vectorizer extension unloaded");
}

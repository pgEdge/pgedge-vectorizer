/*-------------------------------------------------------------------------
 *
 * guc.c
 *		GUC (Grand Unified Configuration) parameter definitions
 *
 * This file defines all configuration parameters for the pgedge_vectorizer
 * extension.
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#include "pgedge_vectorizer.h"
#include "utils/guc.h"

/*
 * GUC Variables - Provider Configuration
 */
char *pgedge_vectorizer_provider = NULL;
char *pgedge_vectorizer_api_key_file = NULL;
char *pgedge_vectorizer_api_url = NULL;
char *pgedge_vectorizer_model = NULL;

/*
 * GUC Variables - Worker Configuration
 */
char *pgedge_vectorizer_databases = NULL;
int pgedge_vectorizer_num_workers = 2;
int pgedge_vectorizer_batch_size = 10;
int pgedge_vectorizer_max_retries = 3;
int pgedge_vectorizer_worker_poll_interval = 1000;

/*
 * GUC Variables - Chunking Configuration
 */
bool pgedge_vectorizer_auto_chunk = true;
char *pgedge_vectorizer_default_chunk_strategy = NULL;
int pgedge_vectorizer_default_chunk_size = 400;
int pgedge_vectorizer_default_chunk_overlap = 50;
bool pgedge_vectorizer_strip_non_ascii = true;

/*
 * GUC Variables - Queue Management
 */
int pgedge_vectorizer_auto_cleanup_hours = 24;

/*
 * Initialize all GUC variables
 */
void
pgedge_vectorizer_init_guc(void)
{
	/* Provider configuration */
	DefineCustomStringVariable("pgedge_vectorizer.provider",
								"Embedding provider to use (openai, voyage, ollama)",
								"Determines which API provider is used for generating embeddings.",
								&pgedge_vectorizer_provider,
								"openai",
								PGC_USERSET,
								0,
								NULL, NULL, NULL);

	DefineCustomStringVariable("pgedge_vectorizer.api_key_file",
								"Path to file containing API key",
								"File should contain only the API key, one line. "
								"Tilde (~) expands to home directory.",
								&pgedge_vectorizer_api_key_file,
								"~/.pgedge-vectorizer-llm-api-key",
								PGC_USERSET,
								0,
								NULL, NULL, NULL);

	DefineCustomStringVariable("pgedge_vectorizer.api_url",
								"API endpoint URL",
								"API endpoint URL. Defaults: OpenAI=https://api.openai.com/v1, "
								"Voyage=https://api.voyageai.com/v1, Ollama=http://localhost:11434",
								&pgedge_vectorizer_api_url,
								"https://api.openai.com/v1",
								PGC_USERSET,
								0,
								NULL, NULL, NULL);

	DefineCustomStringVariable("pgedge_vectorizer.model",
								"Embedding model name",
								"Model to use for embeddings. Examples: "
								"OpenAI: text-embedding-3-small, text-embedding-3-large; "
								"Voyage: voyage-2, voyage-large-2, voyage-code-2; "
								"Ollama: nomic-embed-text, mxbai-embed-large",
								&pgedge_vectorizer_model,
								"text-embedding-3-small",
								PGC_USERSET,
								0,
								NULL, NULL, NULL);

	/* Worker configuration */
	DefineCustomStringVariable("pgedge_vectorizer.databases",
								"Comma-separated list of databases to monitor",
								"List of database names where the extension should process embeddings. "
								"If not set, workers will not connect to any database.",
								&pgedge_vectorizer_databases,
								"",
								PGC_SIGHUP,
								0,
								NULL, NULL, NULL);

	DefineCustomIntVariable("pgedge_vectorizer.num_workers",
							"Number of background workers",
							"Number of background worker processes to spawn. "
							"Requires PostgreSQL restart to change.",
							&pgedge_vectorizer_num_workers,
							2,      /* default */
							1,      /* min */
							32,     /* max */
							PGC_POSTMASTER,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("pgedge_vectorizer.batch_size",
							"Batch size for embedding generation",
							"Number of text chunks to process in a single API call. "
							"Larger batches are more efficient but require more memory.",
							&pgedge_vectorizer_batch_size,
							10,     /* default */
							1,      /* min */
							100,    /* max */
							PGC_SIGHUP,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("pgedge_vectorizer.max_retries",
							"Maximum retry attempts for failed embeddings",
							"Number of times to retry generating embeddings on failure. "
							"Uses exponential backoff.",
							&pgedge_vectorizer_max_retries,
							3,      /* default */
							0,      /* min */
							10,     /* max */
							PGC_SIGHUP,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("pgedge_vectorizer.worker_poll_interval",
							"Worker polling interval in milliseconds",
							"How often workers check for new work when idle.",
							&pgedge_vectorizer_worker_poll_interval,
							1000,   /* default: 1 second */
							100,    /* min: 100ms */
							60000,  /* max: 60 seconds */
							PGC_SIGHUP,
							0,
							NULL, NULL, NULL);

	/* Chunking configuration */
	DefineCustomBoolVariable("pgedge_vectorizer.auto_chunk",
							 "Enable automatic chunking",
							 "Automatically chunk documents when enabled via enable_vectorization().",
							 &pgedge_vectorizer_auto_chunk,
							 true,
							 PGC_SIGHUP,
							 0,
							 NULL, NULL, NULL);

	DefineCustomStringVariable("pgedge_vectorizer.default_chunk_strategy",
								"Default chunking strategy",
								"Strategy to use for chunking: token_based, semantic, markdown, sentence.",
								&pgedge_vectorizer_default_chunk_strategy,
								"token_based",
								PGC_SIGHUP,
								0,
								NULL, NULL, NULL);

	DefineCustomIntVariable("pgedge_vectorizer.default_chunk_size",
							"Default chunk size in tokens",
							"Target size for each chunk in tokens.",
							&pgedge_vectorizer_default_chunk_size,
							400,    /* default */
							50,     /* min */
							2000,   /* max */
							PGC_SIGHUP,
							0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("pgedge_vectorizer.default_chunk_overlap",
							"Default chunk overlap in tokens",
							"Number of tokens to overlap between consecutive chunks.",
							&pgedge_vectorizer_default_chunk_overlap,
							50,     /* default */
							0,      /* min */
							500,    /* max */
							PGC_SIGHUP,
							0,
							NULL, NULL, NULL);

	DefineCustomBoolVariable("pgedge_vectorizer.strip_non_ascii",
							 "Strip non-ASCII characters from chunks",
							 "Remove non-ASCII characters (like box-drawing, emoji, etc.) that may cause API issues.",
							 &pgedge_vectorizer_strip_non_ascii,
							 true,
							 PGC_SIGHUP,
							 0,
							 NULL, NULL, NULL);

	/* Queue management */
	DefineCustomIntVariable("pgedge_vectorizer.auto_cleanup_hours",
							"Automatically clean up completed queue items older than this many hours",
							"Workers will periodically delete completed items older than this value. "
							"Set to 0 to disable automatic cleanup.",
							&pgedge_vectorizer_auto_cleanup_hours,
							24,     /* default: 24 hours */
							0,      /* min: 0 = disabled */
							8760,   /* max: 1 year */
							PGC_SIGHUP,
							0,
							NULL, NULL, NULL);

	elog(DEBUG1, "pgedge_vectorizer GUC variables initialized");
}

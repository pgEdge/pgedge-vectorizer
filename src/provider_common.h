/*-------------------------------------------------------------------------
 *
 * provider_common.h
 *		Shared utilities for embedding provider implementations
 *
 * Copyright (c) 2025 - 2026, pgEdge, Inc.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PROVIDER_COMMON_H
#define PROVIDER_COMMON_H

#include "pgedge_vectorizer.h"
#include <curl/curl.h>

/*
 * Response buffer for libcurl callbacks
 */
typedef struct
{
	char   *data;
	size_t  size;
} ResponseBuffer;

/*
 * Shared provider utility functions
 */

/* curl write callback for all providers */
size_t provider_write_callback(void *contents, size_t size, size_t nmemb,
							   void *userp);

/* Load API key from file with tilde expansion and permission checks */
char *provider_load_api_key(const char *filepath, char **error_msg);

/* Expand tilde (~) to home directory in file paths */
char *provider_expand_tilde(const char *path);

/* Escape a string for safe inclusion in JSON */
char *provider_escape_json_string(const char *str);

/* Build OpenAI-format request body: {"input":[...], "model":"..."} */
char *provider_build_openai_request(const char **texts, int count,
									const char *model);

/*
 * Perform an HTTP POST request via curl.
 *
 * url: full endpoint URL
 * auth_header: e.g. "Authorization: Bearer xxx" or "x-goog-api-key: xxx",
 *              NULL for no auth
 * json_request: POST body
 * provider_name: for error messages (e.g. "OpenAI", "Gemini")
 * response_out: receives the response body (caller must pfree response_out->data)
 * error_msg: receives error message on failure
 *
 * Returns true on success (HTTP 200), false on failure.
 */
bool provider_do_curl_request(const char *url, const char *auth_header,
							  const char *json_request,
							  const char *provider_name,
							  ResponseBuffer *response_out,
							  char **error_msg);

/*
 * Parse OpenAI-format embedding response:
 * {"data":[{"embedding":[0.1,0.2,...]},{"embedding":[...]}],...}
 *
 * Used by OpenAI, Voyage, and OpenAI-compatible local providers.
 */
float **provider_parse_openai_embedding_response(const char *json_response,
												 int count, int *dim,
												 char **error_msg);

/* Count dimensions by counting commas in a JSON float array (after '[') */
int provider_count_array_dimensions(const char *p);

/* Parse a JSON float array into pre-allocated output; returns count parsed */
int provider_parse_float_array(const char **pos, float *output, int dim);

/* Append extra headers from GUC to a curl header list */
void provider_append_extra_headers(struct curl_slist **headers);

/* Free a partially-allocated embeddings array */
void provider_free_embeddings(float **embeddings, int count);

#endif /* PROVIDER_COMMON_H */

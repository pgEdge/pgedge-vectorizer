-- Provider selection test
-- This test verifies that all embedding providers can be configured

-- Test provider configuration defaults
SHOW pgedge_vectorizer.provider;

-- Test available providers are registered (all should work)
DO $$
BEGIN
    -- All providers should be available (we can't test actual API calls without keys)
    -- But we can verify they're registered in the system
    RAISE NOTICE 'Provider configuration test completed';
END;
$$;

-- Test OpenAI provider configuration
SET pgedge_vectorizer.provider = 'openai';
SET pgedge_vectorizer.api_url = 'https://api.openai.com/v1';
SET pgedge_vectorizer.model = 'text-embedding-3-small';
SHOW pgedge_vectorizer.provider;
SHOW pgedge_vectorizer.api_url;
SHOW pgedge_vectorizer.model;

-- Test Voyage AI provider configuration
SET pgedge_vectorizer.provider = 'voyage';
SET pgedge_vectorizer.api_url = 'https://api.voyageai.com/v1';
SET pgedge_vectorizer.model = 'voyage-2';
SHOW pgedge_vectorizer.provider;
SHOW pgedge_vectorizer.api_url;
SHOW pgedge_vectorizer.model;

-- Test Ollama provider configuration
SET pgedge_vectorizer.provider = 'ollama';
SET pgedge_vectorizer.api_url = 'http://localhost:11434';
SET pgedge_vectorizer.model = 'nomic-embed-text';
SHOW pgedge_vectorizer.provider;
SHOW pgedge_vectorizer.api_url;
SHOW pgedge_vectorizer.model;

-- Test Gemini provider configuration
SET pgedge_vectorizer.provider = 'gemini';
SET pgedge_vectorizer.api_url = 'https://generativelanguage.googleapis.com/v1beta';
SET pgedge_vectorizer.model = 'text-embedding-004';
SHOW pgedge_vectorizer.provider;
SHOW pgedge_vectorizer.api_url;
SHOW pgedge_vectorizer.model;

-- Test extra headers configuration
SET pgedge_vectorizer.extra_headers = 'x-portkey-provider: openai; x-custom-header: value123';
SHOW pgedge_vectorizer.extra_headers;

-- Test empty extra headers (default)
RESET pgedge_vectorizer.extra_headers;
SHOW pgedge_vectorizer.extra_headers;

-- Test OpenAI-compatible local provider configuration (custom URL, no key needed)
SET pgedge_vectorizer.provider = 'openai';
SET pgedge_vectorizer.api_url = 'http://localhost:1234/v1';
SET pgedge_vectorizer.model = 'local-embed-model';
SHOW pgedge_vectorizer.provider;
SHOW pgedge_vectorizer.api_url;
SHOW pgedge_vectorizer.model;

-- Reset to defaults
RESET pgedge_vectorizer.provider;
RESET pgedge_vectorizer.api_url;
RESET pgedge_vectorizer.model;
SHOW pgedge_vectorizer.provider;
SHOW pgedge_vectorizer.api_url;

---------------------------------------------------------------------------
-- GUC privilege boundary
---------------------------------------------------------------------------

-- api_key_file names a file the backend opens as the server's OS user, and
-- api_url and extra_headers decide where its contents are sent and what goes
-- with them; provider decides which vendor endpoint and header format the
-- configured key is presented to. Together, settable by anyone, they are an
-- arbitrary local file read delivered to a chosen host in an Authorization
-- header, so all four are superuser-only. model and the scoring knobs affect
-- only the calling session's own results and stay open.

CREATE ROLE pgv_guc_unpriv;
SET SESSION AUTHORIZATION pgv_guc_unpriv;

SELECT current_setting('is_superuser') AS unprivileged_session;

\set ON_ERROR_STOP off
SET pgedge_vectorizer.api_key_file = '/etc/passwd';
SET pgedge_vectorizer.api_url = 'http://example.invalid';
SET pgedge_vectorizer.extra_headers = 'x-evil: 1';
SET pgedge_vectorizer.provider = 'gemini';
\set ON_ERROR_STOP on

-- Settings scoped to the caller's own results stay available.
SET pgedge_vectorizer.model = 'text-embedding-3-large';
SET pgedge_vectorizer.bm25_k1 = 1.5;
SHOW pgedge_vectorizer.model;

RESET SESSION AUTHORIZATION;
DROP ROLE pgv_guc_unpriv;

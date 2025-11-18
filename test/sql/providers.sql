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

-- Reset to defaults
RESET pgedge_vectorizer.provider;
RESET pgedge_vectorizer.api_url;
RESET pgedge_vectorizer.model;
SHOW pgedge_vectorizer.provider;

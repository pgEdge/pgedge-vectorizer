# Embedding Providers

pgEdge Vectorizer supports multiple embedding providers. Each provider has different configuration requirements and capabilities.

## OpenAI

OpenAI provides industry-leading embedding models; these models offer excellent quality and are widely used for semantic search applications.  Save your OpenAI API key from https://platform.openai.com/api-keys; specify the path in the `pgedge_vectorizer.api_key_file` configuration parameter.

**Configuration:**
```ini
pgedge_vectorizer.provider = 'openai'
pgedge_vectorizer.api_key_file = '/path/to/api-key-file'
pgedge_vectorizer.model = 'text-embedding-3-small'
```

**Available Models:**
- `text-embedding-3-small` - 1536 dimensions, cost-effective
- `text-embedding-3-large` - 3072 dimensions, higher quality
- `text-embedding-ada-002` - 1536 dimensions, legacy model

## Google Gemini

Google Gemini provides embedding models through the Generative Language API.  Save your Gemini API key from https://aistudio.google.com/apikey; specify the path in the `pgedge_vectorizer.api_key_file` configuration parameter.

**Configuration:**
```ini
pgedge_vectorizer.provider = 'gemini'
pgedge_vectorizer.api_key_file = '/path/to/api-key-file'
pgedge_vectorizer.model = 'text-embedding-004'
```

**Available Models:**
- `text-embedding-004` - 768 dimensions, latest model
- `embedding-001` - 768 dimensions, earlier model

## Voyage AI

Voyage AI provides high-quality embeddings optimized for retrieval tasks. The API is OpenAI-compatible, making it easy to switch between providers.  Save your Voyage AI API key from https://www.voyageai.com/; specify the path in the `pgedge_vectorizer.api_key_file` configuration parameter.

**Configuration:**
```ini
pgedge_vectorizer.provider = 'voyage'
pgedge_vectorizer.api_key_file = '/path/to/api-key-file'
pgedge_vectorizer.model = 'voyage-2'
```

**Available Models:**
- `voyage-2` - 1024 dimensions, general purpose
- `voyage-large-2` - 1536 dimensions, higher quality
- `voyage-code-2` - 1536 dimensions, optimized for code

## Ollama (Local)

Ollama allows you to run embedding models locally without API keys or internet connectivity. This option is ideal for development, testing, or environments with strict data privacy requirements.

**Configuration:**
```ini
pgedge_vectorizer.provider = 'ollama'
pgedge_vectorizer.model = 'nomic-embed-text'
# No API key needed for Ollama
```

**Available Models** (install via `ollama pull <model>`):
- `nomic-embed-text` - 768 dimensions, good quality
- `mxbai-embed-large` - 1024 dimensions, high quality
- `all-minilm` - 384 dimensions, fast and small

Install Ollama from https://ollama.ai and pull your desired embedding model:
```bash
ollama pull nomic-embed-text
```

Note that Ollama doesn't support batch processing, so each text is embedded individually.

## OpenAI-Compatible Local Providers

The OpenAI provider also works with OpenAI-compatible local inference servers. Set `pgedge_vectorizer.api_url` to point at a local server. The API key is optional when using a custom base URL.

**Configuration:**
```ini
pgedge_vectorizer.provider = 'openai'
pgedge_vectorizer.api_url = 'http://localhost:1234/v1'
pgedge_vectorizer.model = 'your-local-model'
# No API key needed for local providers
```

**Compatible Servers and Default URLs:**

| Server | Default URL |
|--------|------------|
| Docker Model Runner | `http://localhost:12434/engines/llama.cpp/v1` |
| llama.cpp | `http://localhost:8080/v1` |
| LM Studio | `http://localhost:1234/v1` |
| EXO | `http://localhost:52415/v1` |

## Custom Base URLs

All providers support custom base URLs via the `pgedge_vectorizer.api_url` parameter. When left empty (the default), each provider uses its own default URL. Set a custom URL to use a proxy, gateway, or alternative endpoint.

## Extra Headers

For proxy servers and gateways that require additional HTTP headers (e.g., Portkey), use the `pgedge_vectorizer.extra_headers` parameter:

```ini
pgedge_vectorizer.provider = 'openai'
pgedge_vectorizer.api_url = 'https://api.portkey.ai/v1'
pgedge_vectorizer.extra_headers = 'x-portkey-api-key: pk-xxx; x-portkey-provider: openai'
```

Headers are semicolon-separated `key: value` pairs.

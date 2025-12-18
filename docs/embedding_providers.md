# Embedding Providers

pgEdge Vectorizer supports multiple embedding providers. Each provider has different configuration requirements and capabilities.

## OpenAI

OpenAI provides industry-leading embedding models; these models offer excellent quality and are widely used for semantic search applications.  Save your OpenAI API key from https://platform.openai.com/api-keys; specify the path in the `pgedge_vectorizer.api_key_file` configuration parameter.

**Configuration:**
```ini
pgedge_vectorizer.provider = 'openai'
pgedge_vectorizer.api_url = 'https://api.openai.com/v1'
pgedge_vectorizer.api_key_file = '/path/to/api-key-file'
pgedge_vectorizer.model = 'text-embedding-3-small'
```

**Available Models:**
- `text-embedding-3-small` - 1536 dimensions, cost-effective
- `text-embedding-3-large` - 3072 dimensions, higher quality
- `text-embedding-ada-002` - 1536 dimensions, legacy model

## Voyage AI

Voyage AI provides high-quality embeddings optimized for retrieval tasks. The API is OpenAI-compatible, making it easy to switch between providers.  Save your Voyage AI API key from https://www.voyageai.com/; specify the path in the `pgedge_vectorizer.api_key_file` configuration parameter.

**Configuration:**
```ini
pgedge_vectorizer.provider = 'voyage'
pgedge_vectorizer.api_url = 'https://api.voyageai.com/v1'
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
pgedge_vectorizer.api_url = 'http://localhost:11434'
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

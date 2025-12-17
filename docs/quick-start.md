# Quick Start

## Installation

```bash
# Install dependencies
sudo apt-get install postgresql-server-dev-all libcurl4-openssl-dev

# Install pgvector
# See: https://github.com/pgvector/pgvector

# Build and install
cd pgedge-vectorizer
make
sudo make install
```

## Configuration

Add to `postgresql.conf`:

```ini
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.provider = 'openai'
pgedge_vectorizer.api_key_file = '~/.pgedge-vectorizer-llm-api-key'
pgedge_vectorizer.model = 'text-embedding-3-small'
pgedge_vectorizer.databases = 'mydb'  # Comma-separated list of databases to monitor
```

Create API key file:

```bash
echo "your-api-key" > ~/.pgedge-vectorizer-llm-api-key
chmod 600 ~/.pgedge-vectorizer-llm-api-key
```

Restart PostgreSQL and create extension:

```sql
CREATE EXTENSION vector;
CREATE EXTENSION pgedge_vectorizer;
```

## Basic Usage

```sql
-- Create a table
CREATE TABLE documents (
    id BIGSERIAL PRIMARY KEY,
    content TEXT
);

-- Enable vectorization
SELECT pgedge_vectorizer.enable_vectorization(
    'documents',
    'content'
);

-- Insert data - automatically chunked and vectorized
INSERT INTO documents (content)
VALUES ('Your text content here...');

-- Query similar content using generate_embedding()
SELECT
    d.id,
    c.content,
    c.embedding <=> pgedge_vectorizer.generate_embedding('your search query') AS distance
FROM documents d
JOIN documents_content_chunks c ON d.id = c.source_id
ORDER BY distance
LIMIT 5;
```

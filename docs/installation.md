# Installing pgEdge Vectorizer

pgEdge Vectorizer automatically chunks text content and generates vector
embeddings using background workers. You can install pgEdge Vectorizer with
[pgEdge Enterprise Postgres](https://docs.pgedge.com/enterprise/) packages
or build from Vectorizer with source code from the
[pgEdge repository](https://github.com/pgEdge/pgedge-vectorizer).

Before installing pgEdge Vectorizer, you need to install:

* a Postgres server, version 14 or above
* libcurl4-openssl-dev (the cURL library)
* [pgVector](https://github.com/pgvector/pgvector)

Then, to build Vectorizer:

Clone the [pgedge-vectorizer](https://github.com/pgEdge/pgedge-vectorizer) 
repository, and move into the repository root:

```bash
git clone https://github.com/pgEdge/pgedge-vectorizer.git
cd pgedge-vectorizer
```

Then, use the `make` and `make install` commands to build Vectorizer:

```bash
make
sudo make install
```

Use your choice of API tooling to create an API key file named `pgedge-vectorizer-llm-api-key`:

```bash
echo "your-api-key" > ~/.pgedge-vectorizer-llm-api-key
chmod 600 ~/.pgedge-vectorizer-llm-api-key
```

Then, modify the `postgresql.conf` file, adding the Vectorizer extension and
API key file details:

```ini
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.provider = 'openai'
pgedge_vectorizer.api_key_file = '~/.pgedge-vectorizer-llm-api-key'
pgedge_vectorizer.model = 'text-embedding-3-small'
pgedge_vectorizer.databases = 'mydb'  # Comma-separated list of monitored databases
```

Restart PostgreSQL; then use your Postgres client to create the `vector` and `pgedge-vectorizer` extensions:

```sql
CREATE EXTENSION vector;
CREATE EXTENSION pgedge_vectorizer;
```


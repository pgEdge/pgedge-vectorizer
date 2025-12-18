# Using Vectorizer

Start by connecting to the Postgres server with your choice of Postgres client; then, create a table with a text column that will contain the content you want to vectorize:

```sql
CREATE TABLE documents (
    id BIGSERIAL PRIMARY KEY,
    content TEXT
);
```

Enable vectorization on the content column to automatically chunk and embed text as it is inserted or updated:

```sql
SELECT pgedge_vectorizer.enable_vectorization(
    'documents',
    'content'
);
```

Insert data into the table; the content will be automatically chunked and vectorized by background workers:

```sql
INSERT INTO documents (content)
VALUES ('Your text content here...');
```

Query the server for similar content by generating an embedding for your search query and finding the closest matches using vector similarity:

```sql
SELECT
    d.id,
    c.content,
    c.embedding <=> pgedge_vectorizer.generate_embedding('your search query') AS distance
FROM documents d
JOIN documents_content_chunks c ON d.id = c.source_id
ORDER BY distance
LIMIT 5;
```

For detailed usage examples, visit [here](examples.md).
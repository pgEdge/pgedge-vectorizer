# Examples

These examples demonstrate how to set up pgEdge Vectorizer for common use cases. Each example shows how to create a table, enable vectorization with appropriate chunk sizes and strategies, and insert data that will be automatically chunked and embedded. The examples progress from simple single-column vectorization to more advanced scenarios like markdown-aware chunking and multi-column vectorization.

## Example 1: Blog Posts

This example creates a table named `blog_posts` that uses vectorization on the `content` column with moderate chunk sizes (500 tokens with 75 token overlap) suitable for blog article text.

```sql
CREATE TABLE blog_posts (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    content TEXT,
    published_at TIMESTAMPTZ
);

SELECT pgedge_vectorizer.enable_vectorization(
    'blog_posts',
    'content',
    chunk_size := 500,
    chunk_overlap := 75
);

INSERT INTO blog_posts (title, content)
VALUES ('My Blog Post', 'Content here...');
```

## Example 2: Product Documentation

This example creates a table named `documentation` that uses vectorization with a markdown-aware chunking strategy to preserve document structure while processing technical documentation.

```sql
CREATE TABLE documentation (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    markdown_content TEXT,
    version TEXT
);

SELECT pgedge_vectorizer.enable_vectorization(
    'documentation',
    'markdown_content',
    chunk_strategy := 'markdown',
    chunk_size := 600
);
```

## Example 3: Customer Support Tickets

This example creates a table named `support_tickets` that uses vectorization with smaller chunk sizes (300 tokens with 50 token overlap) optimized for shorter support ticket descriptions.

```sql
CREATE TABLE support_tickets (
    id BIGSERIAL PRIMARY KEY,
    subject TEXT,
    description TEXT,
    status TEXT
);

SELECT pgedge_vectorizer.enable_vectorization(
    'support_tickets',
    'description',
    chunk_size := 300,
    chunk_overlap := 50
);
```

## Example 4: UUID Primary Keys

This example creates a table using UUID primary keys, which are auto-detected by the vectorizer. The chunk table's `source_id` column will automatically use the `UUID` type to match.

```sql
CREATE TABLE knowledge_base (
    id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
    title TEXT,
    content TEXT
);

SELECT pgedge_vectorizer.enable_vectorization(
    'knowledge_base',
    'content',
    chunk_size := 400,
    chunk_overlap := 60
);

INSERT INTO knowledge_base (title, content)
VALUES ('Getting Started', 'Welcome to our platform...');

-- Query with UUID join
SELECT
    kb.id,
    kb.title,
    c.content,
    c.embedding <=> pgedge_vectorizer.generate_embedding('how to get started') AS distance
FROM knowledge_base kb
JOIN knowledge_base_content_chunks c ON kb.id = c.source_id
ORDER BY distance
LIMIT 5;
```

## Example 5: Custom Primary Key Column

This example uses `source_pk` to vectorize a table using a non-PK column as the document identifier.

```sql
CREATE TABLE imported_docs (
    id BIGSERIAL PRIMARY KEY,
    external_id UUID NOT NULL DEFAULT gen_random_uuid(),
    content TEXT
);

SELECT pgedge_vectorizer.enable_vectorization(
    'imported_docs',
    'content',
    source_pk := 'external_id'
);
```

## Example 6: Multi-Column Vectorization

This example creates a table named `articles` that uses vectorization on multiple columns independently, with different chunk sizes for the title (100 tokens) and content (500 tokens) to match each field's characteristics.

```sql
CREATE TABLE articles (
    id BIGSERIAL PRIMARY KEY,
    title TEXT,
    summary TEXT,
    content TEXT
);

-- Vectorize title with smaller chunks
SELECT pgedge_vectorizer.enable_vectorization(
    'articles',
    'title',
    chunk_size := 100,
    chunk_overlap := 10
);

-- Vectorize content with larger chunks
SELECT pgedge_vectorizer.enable_vectorization(
    'articles',
    'content',
    chunk_size := 500,
    chunk_overlap := 75
);

-- Query results:
-- - articles_title_chunks table with title embeddings
-- - articles_content_chunks table with content embeddings
-- - Each column operates independently
```

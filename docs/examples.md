# Examples

## Example 1: Blog Posts

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

## Example 4: Multi-Column Vectorization

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

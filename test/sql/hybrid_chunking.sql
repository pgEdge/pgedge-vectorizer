-- Hybrid chunking test
-- This test verifies the hybrid chunking strategy (Docling-style)

-- Test 1: Basic hybrid chunking with markdown structure
SELECT array_length(
    pgedge_vectorizer.chunk_text(
        '# Introduction

This is the introduction paragraph.

## Section 1

This is section 1 content.

## Section 2

This is section 2 content.',
        'hybrid',
        100,
        10
    ),
    1
) >= 1 AS hybrid_basic_works;

-- Test 2: Verify heading context is preserved
SELECT
    chunk,
    chunk LIKE '%[Context:%' AS has_context
FROM unnest(
    pgedge_vectorizer.chunk_text(
        '# Main Title

Introduction text.

## Subsection

Subsection content here.',
        'hybrid',
        50,
        0
    )
) AS chunk;

-- Test 3: Code blocks should be kept together
SELECT
    chunk,
    chunk LIKE '%```%' AS contains_code_fence
FROM unnest(
    pgedge_vectorizer.chunk_text(
        '# Code Example

Here is some code:

```python
def hello():
    print("Hello, World!")
```

That was the code.',
        'hybrid',
        200,
        0
    )
) AS chunk
WHERE chunk LIKE '%```%';

-- Test 4: Lists should be handled properly
SELECT
    array_length(
        pgedge_vectorizer.chunk_text(
            '# Shopping List

- Apples
- Bananas
- Oranges
- Grapes

# Todo List

1. Wake up
2. Code
3. Sleep',
            'hybrid',
            50,
            0
        ),
        1
    ) >= 1 AS lists_handled;

-- Test 5: Large document chunking with structure preservation
SELECT
    array_length(
        pgedge_vectorizer.chunk_text(
            '# Chapter 1: Introduction

This is a long introduction that spans multiple sentences. We need to test how the hybrid chunker handles large documents with multiple sections and subsections. The goal is to maintain semantic coherence while respecting token limits.

## 1.1 Background

The background section provides context. It explains the history and motivation behind this work. Understanding the background is essential for appreciating the contributions.

## 1.2 Objectives

Our objectives are:
- First objective is to test chunking
- Second objective is to verify structure
- Third objective is to ensure quality

# Chapter 2: Methods

This chapter describes our methods.

## 2.1 Data Collection

We collected data from various sources. The data was preprocessed and cleaned before analysis.

## 2.2 Analysis

The analysis involved multiple steps including statistical tests and machine learning models.',
            'hybrid',
            100,
            10
        ),
        1
    ) >= 3 AS large_doc_chunked;

-- Test 6: Blockquotes handling
SELECT
    array_length(
        pgedge_vectorizer.chunk_text(
            '# Quotes

Here is a famous quote:

> To be or not to be,
> that is the question.

And another one:

> The only thing we have to fear is fear itself.',
            'hybrid',
            100,
            0
        ),
        1
    ) >= 1 AS blockquotes_handled;

-- Test 7: Tables handling
SELECT
    chunk,
    chunk LIKE '%|%' AS contains_table
FROM unnest(
    pgedge_vectorizer.chunk_text(
        '# Data Table

| Name | Age | City |
|------|-----|------|
| Alice | 30 | NYC |
| Bob | 25 | LA |

The table above shows our data.',
        'hybrid',
        200,
        0
    )
) AS chunk
WHERE chunk LIKE '%|%';

-- Test 8: Empty content handling
SELECT array_length(
    pgedge_vectorizer.chunk_text(
        '',
        'hybrid',
        100,
        10
    ),
    1
) IS NULL AS empty_returns_null;

-- Test 9: Plain text (no markdown) still works
SELECT
    array_length(
        pgedge_vectorizer.chunk_text(
            'This is plain text without any markdown formatting. It should still be chunked properly by the hybrid strategy, treating it as paragraph content.',
            'hybrid',
            20,
            5
        ),
        1
    ) >= 1 AS plain_text_works;

-- Test 10: Nested headings preserve full context
SELECT
    chunk
FROM unnest(
    pgedge_vectorizer.chunk_text(
        '# Level 1

Content at level 1.

## Level 2

Content at level 2.

### Level 3

Content at level 3 should have full heading hierarchy.',
        'hybrid',
        30,
        0
    )
) AS chunk
WHERE chunk LIKE '%Level 3%';

-- Test 11: Horizontal rules create section breaks
SELECT
    array_length(
        pgedge_vectorizer.chunk_text(
            '# Section A

Content A.

---

# Section B

Content B.',
            'hybrid',
            100,
            0
        ),
        1
    ) >= 1 AS hr_handled;

-- Test 12: Mixed content with all element types
SELECT
    array_length(
        pgedge_vectorizer.chunk_text(
            '# Documentation

Welcome to the docs.

## Getting Started

Install the package:

```bash
npm install mypackage
```

## Configuration

Configure with these options:

| Option | Default | Description |
|--------|---------|-------------|
| debug | false | Enable debug mode |
| timeout | 30 | Request timeout |

> Note: Always set timeout in production.

## Features

Key features include:
- Easy installation
- Fast performance
- Great documentation

---

## Conclusion

Thanks for reading!',
            'hybrid',
            100,
            10
        ),
        1
    ) >= 2 AS mixed_content_works;

-- Test 13: Chunks start properly (not mid-word)
SELECT
    chunk,
    substring(chunk, 1, 1) ~ '^[\[A-Za-z#>\-\*0-9`|"'']' AS starts_properly
FROM unnest(
    pgedge_vectorizer.chunk_text(
        '# First Section

This is content that needs to be split into multiple chunks for testing purposes.

## Second Section

More content here that will also be split.',
        'hybrid',
        15,
        3
    )
) AS chunk;

# Architecture

## Processing Flow

1. **Trigger**: Detects INSERT/UPDATE on configured table
2. **Chunking**: Splits text into chunks using configured strategy
3. **Queue**: Inserts chunk records and queue items
4. **Workers**: Pick up queue items using SKIP LOCKED
5. **Provider**: Generates embeddings via API
6. **Storage**: Updates chunk table with embeddings

## Component Diagram

```
┌─────────────┐
│ Source Table│
└──────┬──────┘
       │ Trigger
       ↓
┌──────────────┐
│   Chunking   │
└──────┬───────┘
       ↓
┌──────────────┐     ┌─────────────┐
│ Chunk Table  │←────┤    Queue    │
└──────────────┘     └──────┬──────┘
       ↑                    │
       │              ┌─────┴──────┐
       │              │  Worker 1  │
       │              │  Worker 2  │
       │              │  Worker N  │
       │              └─────┬──────┘
       │                    │
       │              ┌─────┴──────┐
       └──────────────┤  Provider  │
                      │  (OpenAI)  │
                      └────────────┘
```

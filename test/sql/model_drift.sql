-- model_drift test
--
-- A vectorizer that inherits follows pgedge_vectorizer.model as it changes, so
-- a chunk table can end up holding vectors from two models with nothing
-- reporting it. Each chunk now records what produced its vector,
-- embedding_model_status() reports where that disagrees with what the
-- vectorizer would use now, and reembed() repairs it.
--
-- Nothing here reaches a provider: embeddings and their provenance are written
-- by hand, as the vectorizer_status tests do, and every call passes a
-- dimension explicitly.

SET pgedge_vectorizer.provider = 'openai';
SET pgedge_vectorizer.model = 'text-embedding-3-small';

CREATE TABLE drift_docs (id BIGSERIAL PRIMARY KEY, body TEXT);

INSERT INTO drift_docs (body)
VALUES ('The first document, long enough to be worth embedding.'),
       ('The second document, on an unrelated subject.'),
       ('The third document, which predates the new columns.'),
       ('The fourth document, never embedded at all.');

SELECT pgedge_vectorizer.enable_vectorization(
    'drift_docs'::regclass, 'body', 'token_based', 100, 10, 1536);

---------------------------------------------------------------------------
-- The chunk table records what produced each vector
---------------------------------------------------------------------------

SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS type
  FROM pg_attribute a
 WHERE a.attrelid = 'drift_docs_body_chunks'::regclass
   AND a.attname IN ('embedding_provider', 'embedding_model')
 ORDER BY a.attname;

---------------------------------------------------------------------------
-- Four states, one per chunk: current, drifted, unknown, unembedded
---------------------------------------------------------------------------

-- Chunk 1 was produced by the model the vectorizer would use now.
UPDATE drift_docs_body_chunks
   SET embedding = array_fill(0.1::real, ARRAY[1536])::vector,
       embedding_provider = 'openai',
       embedding_model = 'text-embedding-3-small',
       sparse_embedding = '{1:0.5}/65536'::sparsevec
 WHERE source_id = 1;

-- Chunk 2 came from a different model of the same width, which is the case
-- nothing catches today: the vectors are the right shape and meaningless.
UPDATE drift_docs_body_chunks
   SET embedding = array_fill(0.2::real, ARRAY[1536])::vector,
       embedding_provider = 'openai',
       embedding_model = 'text-embedding-ada-002',
       sparse_embedding = '{1:0.5}/65536'::sparsevec
 WHERE source_id = 2;

-- Chunk 3 was embedded before the columns existed, so nothing is recorded.
UPDATE drift_docs_body_chunks
   SET embedding = array_fill(0.3::real, ARRAY[1536])::vector,
       sparse_embedding = '{1:0.5}/65536'::sparsevec
 WHERE source_id = 3;

-- Chunk 4 is left unembedded.

SELECT source_id, embedding IS NOT NULL AS embedded,
       embedding_provider, embedding_model
  FROM drift_docs_body_chunks
 ORDER BY source_id;

---------------------------------------------------------------------------
-- The report
---------------------------------------------------------------------------

SELECT source_table, source_column, effective_provider, effective_model,
       chunks_embedded, chunks_current, chunks_other_model,
       chunks_model_unknown, embedded_models
  FROM pgedge_vectorizer.embedding_model_status('drift_docs'::regclass);

-- Narrowing by column, and a column that is not vectorized returns nothing
-- rather than erroring.
SELECT count(*) AS rows_for_body
  FROM pgedge_vectorizer.embedding_model_status('drift_docs'::regclass, 'body');

SELECT count(*) AS rows_for_unknown_column
  FROM pgedge_vectorizer.embedding_model_status('drift_docs'::regclass, 'title');

---------------------------------------------------------------------------
-- reembed() at a matching width leaves the current row alone
---------------------------------------------------------------------------

SELECT pgedge_vectorizer.reembed(
    'drift_docs'::regclass, 'body', embedding_dimension => 1536) AS queued;

-- Chunk 1 keeps its embedding and its provenance; 2 and 3 lose both; 4 was
-- never embedded and is queued alongside them.
SELECT source_id, embedding IS NOT NULL AS embedded,
       embedding_provider, embedding_model
  FROM drift_docs_body_chunks
 ORDER BY source_id;

-- Nothing that does not depend on the embedding model was disturbed.
SELECT count(*) AS chunks,
       count(token_count) AS token_counts_kept,
       count(sparse_embedding) AS sparse_kept
  FROM drift_docs_body_chunks;

SELECT count(*) AS queued_rows
  FROM pgedge_vectorizer.queue
 WHERE chunk_table = 'drift_docs_body_chunks' AND status = 'pending';

-- The report now shows one current row and nothing drifted.
SELECT chunks_embedded, chunks_current, chunks_other_model,
       chunks_model_unknown, embedded_models
  FROM pgedge_vectorizer.embedding_model_status('drift_docs'::regclass);

---------------------------------------------------------------------------
-- A vectorizer with nothing to redo queues nothing
---------------------------------------------------------------------------

-- Give the three cleared chunks their embeddings back, as the worker would.
UPDATE drift_docs_body_chunks
   SET embedding = array_fill(0.1::real, ARRAY[1536])::vector,
       embedding_provider = 'openai',
       embedding_model = 'text-embedding-3-small'
 WHERE embedding IS NULL;

SELECT pgedge_vectorizer.reembed(
    'drift_docs'::regclass, 'body', embedding_dimension => 1536) AS queued;

SELECT count(*) AS still_embedded FROM drift_docs_body_chunks
 WHERE embedding IS NOT NULL;

---------------------------------------------------------------------------
-- A change of width takes every chunk with it, drifted or not
---------------------------------------------------------------------------

SELECT pgedge_vectorizer.reembed(
    'drift_docs'::regclass, 'body', embedding_dimension => 768) AS queued;

SELECT format_type(a.atttypid, a.atttypmod) AS embedding_type
  FROM pg_attribute a
 WHERE a.attrelid = 'drift_docs_body_chunks'::regclass
   AND a.attname = 'embedding';

SELECT count(*) AS chunks,
       count(embedding) AS embedded,
       count(token_count) AS token_counts_kept,
       count(sparse_embedding) AS sparse_kept
  FROM drift_docs_body_chunks;

---------------------------------------------------------------------------
-- A table with no vectorizer is an error
---------------------------------------------------------------------------

DO $$
BEGIN
    PERFORM pgedge_vectorizer.reembed('drift_docs'::regclass, 'nosuchcolumn');
    RAISE EXCEPTION 'expected an error, got none';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '%', SQLERRM;
END;
$$;

---------------------------------------------------------------------------
-- Cleanup
---------------------------------------------------------------------------

SELECT pgedge_vectorizer.disable_vectorization('drift_docs'::regclass,
                                               'body', TRUE);
DROP TABLE drift_docs;
DELETE FROM pgedge_vectorizer.queue;
RESET pgedge_vectorizer.provider;
RESET pgedge_vectorizer.model;

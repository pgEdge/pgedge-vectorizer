-- DELETE cleanup with a non-default primary key type
--
-- The DELETE trigger casts source_id to the source table's primary key type, so
-- a text key needs covering separately from the bigint case (issue #24).
--
-- This lives in its own test file deliberately. enable_vectorization() cannot
-- currently be called for a bigint-keyed table and a text-keyed table in the
-- same session: the second call fails with "type of parameter N (text) does not
-- match that when preparing the plan (bigint)". That is a pre-existing defect
-- unrelated to the DELETE cleanup, reproducible on the previous release, and
-- pg_regress gives each test file its own session, which avoids it.

CREATE TABLE dt_custom (doc_key TEXT PRIMARY KEY, body TEXT);
INSERT INTO dt_custom VALUES
    ('k1', repeat('nu xi omicron ', 20)),
    ('k2', repeat('pi rho sigma ', 20));

SELECT pgedge_vectorizer.enable_vectorization('dt_custom', 'body',
                                              source_pk => 'doc_key',
                                              embedding_dimension => 3);

SELECT count(*) > 0 AS custom_pk_has_chunks FROM dt_custom_body_chunks;

-- Deleting one row must remove only that key's chunks
DELETE FROM dt_custom WHERE doc_key = 'k1';
SELECT count(*) AS chunks_for_deleted_key
  FROM dt_custom_body_chunks WHERE source_id = 'k1';
SELECT count(*) > 0 AS other_key_untouched
  FROM dt_custom_body_chunks WHERE source_id = 'k2';

-- TRUNCATE with a text key
TRUNCATE dt_custom;
SELECT count(*) AS chunks_after_truncate FROM dt_custom_body_chunks;

-- Clean up
SELECT pgedge_vectorizer.disable_vectorization('dt_custom', 'body', true);
DROP TABLE dt_custom;

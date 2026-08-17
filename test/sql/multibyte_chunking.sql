-- Multibyte chunking test
--
-- Chunk boundaries are byte offsets derived from a character count, so a
-- boundary can land inside a multi-byte character. Nothing between the chunker
-- and the chunk table validates the encoding -- cstring_to_text() does not --
-- so the fragment is stored, and any later read that walks characters rather
-- than bytes fails on that row. length() is the one used below; a client
-- decoding strictly fails the same way. This is the fault fixed in
-- queue_item_note_error() for error messages, one layer up.
--
-- Only reachable with pgedge_vectorizer.strip_non_ascii off, which is why it
-- went unnoticed: the default turns every non-ASCII byte into a space, so
-- nothing multi-byte ever reaches the boundary arithmetic. Off is what you set
-- to keep non-English content.
--
-- strip_non_ascii is PGC_SIGHUP, so it is changed here with ALTER SYSTEM plus
-- a reload rather than a plain SET, and \c to pick the new value up in a fresh
-- backend -- see the longer explanation in max_retries.sql. It is reset at the
-- end because ALTER SYSTEM is cluster-wide state that must not leak into later
-- test files.
--
-- Two-, three- and four-byte characters are each covered: the overshoot is in
-- how far past the character's lead byte the cursor stops, so its size is the
-- variable. Assumes a UTF-8 database, as delete_truncate.sql does.

---------------------------------------------------------------------------
-- The default: strip_non_ascii = on
---------------------------------------------------------------------------

-- Nothing here asserted the documented default behaviour before, so pin it.

SHOW pgedge_vectorizer.strip_non_ascii;

-- A run of non-ASCII becomes a single space, not one per character. The
-- collapse tests the last byte already written, so a run that already follows
-- a space contributes nothing and the space on the far side survives: two
-- spaces here, not one.
SELECT quote_literal(c) AS run_between_words
  FROM unnest(pgedge_vectorizer.chunk_text('alpha ★★★ beta',
                                           'token_based', 100, 0)) c;

-- With no preceding output to append to, a leading run is dropped rather than
-- becoming a leading space.
SELECT quote_literal(c) AS leading_run
  FROM unnest(pgedge_vectorizer.chunk_text('★★★alpha',
                                           'token_based', 100, 0)) c;

-- A four-byte character between two ASCII ones still yields exactly one space.
SELECT quote_literal(c) AS four_byte_between_words
  FROM unnest(pgedge_vectorizer.chunk_text('a🙂b',
                                           'token_based', 100, 0)) c;

-- Text that is entirely non-ASCII strips to nothing, so there is no chunk.
SELECT count(*) AS chunks_for_all_non_ascii
  FROM unnest(pgedge_vectorizer.chunk_text('★★★',
                                           'token_based', 100, 0)) c;

---------------------------------------------------------------------------
-- strip_non_ascii = off: chunks must not split a character in half
---------------------------------------------------------------------------

ALTER SYSTEM SET pgedge_vectorizer.strip_non_ascii = off;
SELECT pg_reload_conf();
\c
SHOW pgedge_vectorizer.strip_non_ascii;

-- Three-byte characters with nothing for the break finder to latch onto, so
-- every boundary falls where the token estimate put it. length() raises on a
-- chunk that ends mid-character, so summing it both proves validity and checks
-- that no characters were lost.
SELECT count(*) AS nchunks, sum(length(c)) AS total_chars
  FROM unnest(pgedge_vectorizer.chunk_text(repeat('漢', 200),
                                           'token_based', 10, 0)) c;

-- Per chunk, so a boundary that is character-aligned but wrongly sized is
-- caught too. Three bytes per character throughout.
SELECT n, length(c) AS chars, octet_length(c) AS bytes
  FROM unnest(pgedge_vectorizer.chunk_text(repeat('漢', 200),
                                           'token_based', 10, 0))
       WITH ORDINALITY AS t(c, n)
 ORDER BY n;

-- Two-byte characters.
SELECT count(*) AS nchunks, sum(length(c)) AS total_chars
  FROM unnest(pgedge_vectorizer.chunk_text(repeat('é', 200),
                                           'token_based', 10, 0)) c;

-- Four-byte characters.
SELECT count(*) AS nchunks, sum(length(c)) AS total_chars
  FROM unnest(pgedge_vectorizer.chunk_text(repeat('🙂', 100),
                                           'token_based', 10, 0)) c;

-- Control: the same script with ASCII spaces in it already passed, because
-- find_good_break_point() returns the offset of a space and an ASCII byte
-- cannot occur inside a multi-byte sequence. Keep it, so a fix that aligns
-- boundaries by moving them cannot quietly change where the breaks land.
SELECT count(*) AS nchunks, sum(length(c)) AS total_chars
  FROM unnest(pgedge_vectorizer.chunk_text(
                  array_to_string(array_fill('漢字熟語'::text, ARRAY[50]), ' '),
                  'token_based', 10, 0)) c;

-- Overlap makes the chunker take a second byte offset inside a chunk it has
-- already cut, so cover it as well.
SELECT count(*) > 1 AS several_chunks, sum(length(c)) >= 200 AS no_chars_lost
  FROM unnest(pgedge_vectorizer.chunk_text(repeat('漢', 200),
                                           'token_based', 10, 4)) c;

-- The hybrid and markdown strategies split oversized elements through the same
-- two functions, so they inherit the fault and must inherit the fix.
SELECT sum(length(c)) > 0 AS hybrid_chunks_valid
  FROM unnest(pgedge_vectorizer.chunk_text(
                  '# 見出し' || chr(10) || chr(10) || repeat('漢', 200),
                  'hybrid', 10, 0)) c;

SELECT sum(length(c)) > 0 AS markdown_chunks_valid
  FROM unnest(pgedge_vectorizer.chunk_text(
                  '# 見出し' || chr(10) || chr(10) || repeat('漢', 200),
                  'markdown', 10, 0)) c;

-- A chunk that reaches the chunk table must survive being read back, which is
-- where this actually bites in production rather than in a scalar expression.
CREATE TABLE mb_docs (id BIGSERIAL PRIMARY KEY, body TEXT);
INSERT INTO mb_docs (body) VALUES (repeat('漢', 200));

SELECT pgedge_vectorizer.enable_vectorization('mb_docs', 'body',
                                              'token_based', 10, 0, 3);

SELECT count(*) > 1 AS stored_several_chunks,
       sum(length(content)) AS total_chars
  FROM mb_docs_body_chunks;

SELECT pgedge_vectorizer.disable_vectorization('mb_docs', 'body', true);
DROP TABLE mb_docs;

---------------------------------------------------------------------------
-- Restore the cluster-wide setting for later test files
---------------------------------------------------------------------------

ALTER SYSTEM RESET pgedge_vectorizer.strip_non_ascii;
SELECT pg_reload_conf();
\c
SHOW pgedge_vectorizer.strip_non_ascii;

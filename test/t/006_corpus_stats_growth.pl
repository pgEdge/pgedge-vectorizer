# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that the corpus statistics growth bound reaches the vectors the worker
# stores, not merely the ones a query computes.
#
# The regression tests cover the bound through bm25_query_vector(), which
# discards its result at the end of the statement. The worker runs the same
# lookup per queue item and writes the outcome into sparse_embedding, so a
# stale corpus size there is persisted rather than recomputed next time. That
# is the reason the bound exists, and it is what this test exercises.
#
# The queue rows are marked sparse_only, so no embedding is fetched and no
# network call is made. The provider is still resolved and initialised before
# that check is reached, though, so it is set to ollama, which is the one
# provider whose init needs no API key.
#
# Every chunk holds the same single term and the same token_count, so
# avg_doc_len cannot vary and doc_freq is fixed by hand. The corpus size is
# then the only input that differs between the chunks compared below, and the
# stored weights differ if and only if it was re-read.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $dbname = 'corpus_growth';

my $node = PostgreSQL::Test::Cluster->new('vectorizer_corpus_growth');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.worker_poll_interval = 200
pgedge_vectorizer.batch_size = 1
pgedge_vectorizer.provider = 'ollama'
pgedge_vectorizer.enable_hybrid = true
pgedge_vectorizer.corpus_stats_cache_ttl = 3600
pgedge_vectorizer.corpus_stats_cache_max_growth = 5
max_worker_processes = 16
));

$node->start;

$node->safe_psql('postgres', "CREATE DATABASE $dbname");
$node->safe_psql($dbname, 'CREATE EXTENSION vector');
$node->safe_psql($dbname, 'CREATE EXTENSION pgedge_vectorizer');

# A chunk table of the shape the extension creates, built by hand so that the
# corpus size is under this test's control rather than the chunker's.
$node->safe_psql(
	$dbname, q(
CREATE TABLE chunks (
    id               BIGSERIAL PRIMARY KEY,
    source_id        BIGINT,
    chunk_index      INT,
    content          TEXT,
    token_count      INT,
    embedding        vector(3),
    sparse_embedding sparsevec(65536)
);
CREATE TABLE chunks_idf_stats (
    term      TEXT PRIMARY KEY,
    doc_freq  INT NOT NULL
);
INSERT INTO chunks (source_id, chunk_index, content, token_count)
SELECT g, 0, 'alpha', 10 FROM generate_series(1, 20) g;
INSERT INTO chunks_idf_stats VALUES ('alpha', 5);
));

$node->append_conf('postgresql.conf',
	"pgedge_vectorizer.databases = '$dbname'\n");
$node->reload;

# Wait for a chunk's sparse_embedding to be written, rather than assuming the
# worker has got to it, so that startup timing cannot decide the result.
sub await_sparse
{
	my ($id) = @_;
	my $deadline = time() + 60;

	while (time() < $deadline)
	{
		my $got = $node->safe_psql($dbname,
			"SELECT sparse_embedding IS NOT NULL FROM chunks WHERE id = $id");

		return 1 if $got eq 't';
		sleep 1;
	}
	return 0;
}

# First item: nothing is cached, so the corpus is read here at N = 20.
$node->safe_psql(
	$dbname, q(
INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content, status, metadata)
VALUES (1, 'chunks', 'alpha', 'pending', '{"sparse_only": true}'::jsonb)
));

ok(await_sparse(1), 'the worker stores a sparse vector, so the rest of this test measures something');

# Grow the corpus elevenfold without queueing any of it. A time bound alone
# would hold the figure read above for the next hour.
$node->safe_psql(
	$dbname, q(
INSERT INTO chunks (source_id, chunk_index, content, token_count)
SELECT g, 0, 'alpha', 10 FROM generate_series(100, 299) g
));

# At N = 20 the budget is one cached use, so the second item is served from
# cache and the third must re-read.
$node->safe_psql(
	$dbname, q(
INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content, status, metadata)
VALUES (2, 'chunks', 'alpha', 'pending', '{"sparse_only": true}'::jsonb),
       (3, 'chunks', 'alpha', 'pending', '{"sparse_only": true}'::jsonb)
));

ok(await_sparse(2), 'the second queued chunk is indexed');
ok(await_sparse(3), 'the third queued chunk is indexed');

my $cached = $node->safe_psql($dbname,
	'SELECT (SELECT sparse_embedding FROM chunks WHERE id = 1)
          = (SELECT sparse_embedding FROM chunks WHERE id = 2)');

is($cached, 't',
	'a use inside the budget is served from the cache, so the bound is not simply disabled');

my $rereadd = $node->safe_psql($dbname,
	'SELECT (SELECT sparse_embedding FROM chunks WHERE id = 1)
         <> (SELECT sparse_embedding FROM chunks WHERE id = 3)');

is($rereadd, 't',
	'once the budget is spent the worker re-reads the corpus, and the stored vector reflects it');

# Pin down that the difference is the corpus size and nothing else: the weight
# is idf * a constant, so the ratio of the two stored weights must be the ratio
# of ln((N+1)/(df+0.5)) at N = 220 and at N = 20, with df = 5.
my $ratio = $node->safe_psql(
	$dbname, q(
WITH w AS (
    SELECT (SELECT (sparse_embedding::text)::jsonb IS NOT NULL FROM chunks WHERE id = 1) AS ignored,
           (SELECT split_part(split_part(sparse_embedding::text, ':', 2), '}', 1)::float8
              FROM chunks WHERE id = 1) AS w1,
           (SELECT split_part(split_part(sparse_embedding::text, ':', 2), '}', 1)::float8
              FROM chunks WHERE id = 3) AS w3
)
SELECT abs(w3 / w1 - ln(221.0 / 5.5) / ln(21.0 / 5.5)) < 0.01 FROM w
));

is($ratio, 't',
	'the re-read weight is exactly what the grown corpus size gives, not merely different');

done_testing();

# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that sparse-only work is neither queued nor failed while
# pgedge_vectorizer.enable_hybrid is off.
#
# The 1.0 to 1.1 upgrade used to queue a sparse_only backfill item for every
# existing chunk regardless of the setting, and the worker raised an ERROR for
# each of them, so a database with many chunks filled its log for days before
# every item ran out of attempts. The upgrade is exercised from a real 1.0
# install, once with hybrid off and once with it on, and the worker is then
# handed a sparse_only item with hybrid off and must complete it quietly.
#
# The provider is set to ollama, the one provider whose init needs no API key,
# because the worker resolves and initialises it before reaching the item.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('vectorizer_sparse_no_hybrid');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.worker_poll_interval = 200
pgedge_vectorizer.batch_size = 1
pgedge_vectorizer.provider = 'ollama'
pgedge_vectorizer.enable_hybrid = false
max_worker_processes = 16
));

$node->start;

# Build a 1.0 vectorizer with embedded chunks, then upgrade it to 1.1 with
# enable_hybrid set as given, and return the number of sparse_only items the
# upgrade queued. No worker serves these databases, so nothing is consumed.
sub upgraded_sparse_items
{
	my ($dbname, $hybrid) = @_;

	$node->safe_psql('postgres', "CREATE DATABASE $dbname");
	$node->safe_psql($dbname, 'CREATE EXTENSION vector');
	$node->safe_psql($dbname,
		"CREATE EXTENSION pgedge_vectorizer VERSION '1.0'");
	$node->safe_psql(
		$dbname, q(
CREATE TABLE docs (id INT PRIMARY KEY, body TEXT);
SELECT pgedge_vectorizer.enable_vectorization('docs', 'body',
                                              embedding_dimension => 3);
INSERT INTO docs VALUES (1, 'alpha beta'), (2, 'gamma delta');
UPDATE docs_body_chunks SET embedding = '[1,2,3]';
DELETE FROM pgedge_vectorizer.queue;
));

	return $node->safe_psql(
		$dbname, qq(
SET pgedge_vectorizer.enable_hybrid = $hybrid;
ALTER EXTENSION pgedge_vectorizer UPDATE TO '1.1';
SELECT count(*) FROM pgedge_vectorizer.queue
WHERE (metadata->>'sparse_only')::boolean;
));
}

is(upgraded_sparse_items('upgrade_hybrid_off', 'off'),
	'0', 'the 1.0 to 1.1 upgrade queues no sparse backfill with hybrid off');

is(upgraded_sparse_items('upgrade_hybrid_on', 'on'),
	'2', 'the 1.0 to 1.1 upgrade still queues the sparse backfill with hybrid on');

# Now the worker: an item already queued, for example by an earlier upgrade,
# must be completed rather than failed while hybrid is off.
my $dbname = 'worker_hybrid_off';

$node->safe_psql('postgres', "CREATE DATABASE $dbname");
$node->safe_psql($dbname, 'CREATE EXTENSION vector');
$node->safe_psql($dbname, 'CREATE EXTENSION pgedge_vectorizer');
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
INSERT INTO chunks (source_id, chunk_index, content, token_count, embedding)
VALUES (1, 0, 'alpha', 1, '[1,2,3]');
INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content, status, metadata)
VALUES (1, 'chunks', 'alpha', 'pending', '{"sparse_only": true}'::jsonb);
));

$node->append_conf('postgresql.conf',
	"pgedge_vectorizer.databases = '$dbname'\n");
$node->reload;

ok( $node->poll_query_until(
		$dbname,
		"SELECT status = 'completed' OR attempts > 0 FROM pgedge_vectorizer.queue WHERE chunk_id = 1"
	),
	'the worker picks up the sparse-only item');

is( $node->safe_psql(
		$dbname,
		"SELECT status || ':' || attempts || ':' || coalesce(error_message, '') "
		  . "FROM pgedge_vectorizer.queue WHERE chunk_id = 1"),
	'completed:0:',
	'a sparse-only item is completed, not failed, while hybrid is off');

is( $node->safe_psql(
		$dbname,
		'SELECT sparse_embedding IS NULL AND embedding IS NOT NULL FROM chunks WHERE id = 1'),
	't',
	'the chunk keeps its dense embedding and gains no sparse one');

$node->stop;
done_testing();

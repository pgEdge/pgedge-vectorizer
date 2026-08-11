# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that a queue item which cannot be processed is charged for the attempt,
# so that it backs off and is eventually retired instead of being retried
# forever.
#
# A batch is processed inside a single transaction, so an error anywhere in it
# aborts the lot. Recording the failure from inside that transaction therefore
# could not work: the statement is rejected because the transaction is already
# aborted, and would be rolled back with everything else even if it were not.
# attempts stayed at its original value however many times the item was tried,
# so max_attempts never tripped, next_retry_at was never set, and the item was
# reclaimed on every poll. Measured against an unfixed build that is of the
# order of 150 failure cycles a minute for a single bad row.
#
# The failure is now recorded after the transaction has been aborted, in one of
# its own. That restarts three mechanisms the queue already had and which were
# all gated on attempts moving: next_retry_at holds the item out of the claim,
# a non-zero attempts count makes the worker process claimed items one at a
# time, and max_attempts retires it.
#
# The fault injected here is a queue row naming a chunk table that does not
# exist. It is marked sparse_only, which skips the embedding provider
# altogether, so the test needs no API key. The failure surfaces in the probe
# that decides whether an item still needs a dense embedding, which runs before
# the per-item processing loop -- the same place the original symptom appeared.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $dbname = 'queue_accounting';

my $node = PostgreSQL::Test::Cluster->new('vectorizer_queue_accounting');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.databases = '$dbname'
pgedge_vectorizer.worker_poll_interval = 200
max_worker_processes = 16
));

$node->start;

# Create the extension before the worker's first look, so it does not fall into
# the extension-not-installed backoff and sit out the window below.
$node->safe_psql('postgres', "CREATE DATABASE $dbname");
$node->safe_psql($dbname, 'CREATE EXTENSION vector');
$node->safe_psql($dbname, 'CREATE EXTENSION pgedge_vectorizer');

my $log_offset = (-s $node->logfile) // 0;

# max_attempts is deliberately low so the whole lifecycle fits in the test.
$node->safe_psql(
	$dbname, qq(
INSERT INTO pgedge_vectorizer.queue
    (chunk_id, chunk_table, content, status, metadata, max_attempts)
VALUES (1, 'no_such_chunk_table', 'alpha beta gamma', 'pending',
        '{"sparse_only": true}'::jsonb, 2)
));

# One poll interval is 200ms, so this is many chances to try the row.
sleep 5;

my $attempts = $node->safe_psql($dbname,
	"SELECT attempts FROM pgedge_vectorizer.queue WHERE chunk_table = 'no_such_chunk_table'");

cmp_ok($attempts, '>', 0,
	'a failed attempt is recorded against the item');

my $backoff = $node->safe_psql($dbname,
	"SELECT next_retry_at > now() FROM pgedge_vectorizer.queue WHERE chunk_table = 'no_such_chunk_table'");

is($backoff, 't',
	'the item is held out of the claim until its retry time');

# The point of the backoff: without it the worker retries as fast as it polls.
# Counting the worker's own "error in processing" line is the most direct
# measure of that, and the margin is large -- an unfixed build produces of the
# order of twenty five of these in the window above, a fixed one produces one.
my $log = slurp_file($node->logfile, $log_offset);
my @cycles = ($log =~ /error in processing, continuing/g);

cmp_ok(scalar(@cycles), '<', 5,
	'the item is not retried on every poll');

# Walk it to the end of its retries. Clearing next_retry_at makes it eligible
# again immediately rather than waiting out the backoff, which would make this
# test take minutes.
my $deadline = time() + 60;
my $status = '';

while (time() < $deadline)
{
	$status = $node->safe_psql($dbname,
		"SELECT status FROM pgedge_vectorizer.queue WHERE chunk_table = 'no_such_chunk_table'");

	last if $status eq 'failed';

	$node->safe_psql($dbname,
		"UPDATE pgedge_vectorizer.queue SET next_retry_at = NULL WHERE chunk_table = 'no_such_chunk_table'");

	sleep 1;
}

is($status, 'failed',
	'the item is retired once max_attempts is reached');

my $claimable = $node->safe_psql($dbname, q(
SELECT count(*) FROM pgedge_vectorizer.queue
 WHERE status = 'pending'
   AND (next_retry_at IS NULL OR next_retry_at <= now())
));

is($claimable, '0',
	'a retired item is no longer claimed');

$node->stop;
done_testing();

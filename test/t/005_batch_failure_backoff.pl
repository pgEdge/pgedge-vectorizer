# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that a batch which fails for a reason no single queue item can be
# charged for makes the worker back off, rather than reclaiming the same rows
# and failing identically on every poll.
#
# A failure belonging to a particular item is charged to it, and the queue then
# holds it back: next_retry_at keeps it out of the claim and max_attempts
# eventually retires it (see 004_queue_failure_accounting.pl). A failure
# belonging to the batch has none of that. Nothing is charged, deliberately,
# since billing a blameless item for a misconfigured provider would work
# through the queue retiring one innocent row per max_attempts cycles. So
# before this change the same rows were reclaimed on the very next poll and
# failed the same way, indefinitely: at the 200ms poll used here that is five
# failure cycles a second, for as long as the misconfiguration lasted.
#
# The fault injected is a provider that does not exist, which makes
# get_current_provider() raise. That is deliberate on two counts: it needs no
# network and no API key, and it is the most likely way for a real deployment
# to land here, since a single mistyped pgedge_vectorizer.provider does it.
#
# The queue row points at a chunk table that genuinely exists, so that the
# probe preceding the provider lookup succeeds. Were it missing, the failure
# would be charged to the item and the queue's own backoff would cover it,
# which is the case this test is specifically not about.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $dbname = 'batch_backoff';

my $node = PostgreSQL::Test::Cluster->new('vectorizer_batch_backoff');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.worker_poll_interval = 200
pgedge_vectorizer.provider = 'no_such_provider'
max_worker_processes = 16
));

$node->start;

$node->safe_psql('postgres', "CREATE DATABASE $dbname");
$node->safe_psql($dbname, 'CREATE EXTENSION vector');
$node->safe_psql($dbname, 'CREATE EXTENSION pgedge_vectorizer');

# A real chunk table, so the dense-embedding probe succeeds and the batch gets
# as far as resolving the provider.
$node->safe_psql(
	$dbname, q(
CREATE TABLE chunks (
    id               BIGSERIAL PRIMARY KEY,
    content          TEXT,
    token_count      INT,
    embedding        vector(3),
    sparse_embedding sparsevec(100)
);
INSERT INTO chunks (content, token_count) VALUES ('alpha beta gamma', 3);
));

# Name the database only once it is ready to be serviced, so that no worker can
# arrive before the extension exists and take its five second backoff instead.
$node->append_conf('postgresql.conf',
	"pgedge_vectorizer.databases = '$dbname'\n");
$node->reload;

my $offset = (-s $node->logfile) // 0;

$node->safe_psql(
	$dbname, q(
INSERT INTO pgedge_vectorizer.queue (chunk_id, chunk_table, content, status)
VALUES (1, 'chunks', 'alpha beta gamma', 'pending')
));

# Wait for the first failure rather than assuming one has happened, so worker
# startup timing cannot decide the result.
my $deadline = time() + 30;
my $log      = '';

while (time() < $deadline)
{
	$log = slurp_file($node->logfile, $offset);

	last if $log =~ /error in processing, continuing/;

	sleep 1;
}

like($log, qr/error in processing, continuing/,
	'the batch does fail, so the rest of this test is measuring something');

# Twenty seconds covers the first three attempts of a 5s, 10s, 20s backoff.
# Unfixed, a 200ms poll manages of the order of a hundred in the same window.
sleep 20;
$log = slurp_file($node->logfile, $offset);

my @cycles = ($log =~ /error in processing, continuing/g);

cmp_ok(scalar(@cycles), '<=', 8,
	'a batch that cannot be charged to an item is retried a handful of times, not continuously');

cmp_ok(scalar(@cycles), '>=', 1,
	'the worker does keep retrying rather than giving up on the queue');

# The intervals themselves: the first backoff is the floor, and each failure
# thereafter doubles it.
my @waits = ($log =~ /waiting (\d+)s before trying again/g);

cmp_ok(scalar(@waits), '>=', 2,
	'the backoff is reported so an operator can see why the queue has gone quiet');

is($waits[0], '5', 'the first backoff is the five second floor');

cmp_ok($waits[1], '>', $waits[0],
	'each successive failure waits longer than the last');

# A reload is how a misconfigured provider gets corrected, so it must not leave
# the operator waiting out a backoff their fix has already invalidated.
my $reload_offset = (-s $node->logfile) // 0;
$node->reload;
sleep 8;

my $after_reload = slurp_file($node->logfile, $reload_offset);
my @after_waits = ($after_reload =~ /waiting (\d+)s before trying again/g);

cmp_ok(scalar(@after_waits), '>=', 1,
	'the worker tries again promptly after a reload rather than waiting out the old backoff');

is($after_waits[0], '5',
	'a reload resets the backoff to the floor');

$node->stop;
done_testing();

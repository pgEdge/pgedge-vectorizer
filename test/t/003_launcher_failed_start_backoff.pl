# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that the launcher backs off when a worker cannot start at all, instead
# of respawning it as fast as the postmaster will fork.
#
# Per-database workers are BGW_NEVER_RESTART, so the launcher owns respawn, and
# it is told a worker exited by the bgw_notify_pid notification. A worker whose
# database does not exist reaches its FATAL within a few milliseconds of being
# spawned, so that notification arrives almost immediately and sends the
# launcher straight back round to spawn a replacement. Nothing in the spawn path
# rate limits that by itself.
#
# Before the backoff, a single mistyped name in pgedge_vectorizer.databases was
# therefore enough to have the launcher fork of the order of two hundred
# doomed workers a second indefinitely, consuming PIDs and writing megabytes of
# log a minute. The launcher now treats a worker that exits within
# LAUNCHER_FAILED_START_MS of being spawned as having failed to start, and holds
# its database off for an interval that doubles from 5s to a 5 minute cap.
#
# The margin here is enormous, which is what makes the test worth having: over
# the ten second window below the unthrottled launcher manages thousands of
# attempts and the throttled one manages two.
#
# Note the log offset captured before the node starts. PostgreSQL::Test keeps
# logs in ./log when run directly, and that directory persists between runs in a
# given build tree, so counting from the top of the file would mix in the
# previous run's attempts and could pass against a binary without the fix.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $missing = 'backoff_missing_db';

my $node = PostgreSQL::Test::Cluster->new('vectorizer_backoff');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.databases = '$missing'
pgedge_vectorizer.num_workers = 2
pgedge_vectorizer.worker_poll_interval = 200
max_worker_processes = 16
));

my $log_offset = (-s $node->logfile) // 0;

$node->start;

# Long enough for the first attempt and the retry when the initial 5s backoff
# expires, and long enough that an unthrottled launcher would be well into four
# figures.
sleep 10;

my $log = slurp_file($node->logfile, $log_offset);
my @attempts = ($log =~ /database "\Q$missing\E" does not exist/g);

cmp_ok(scalar(@attempts), '>', 0,
	'the launcher does attempt to start a worker for the missing database');

cmp_ok(scalar(@attempts), '<=', 8,
	'the launcher backs off rather than respawning the failed worker in a loop');

like($log, qr/exited immediately, retrying in \d+ms/,
	'the launcher reports the backoff it applied');

# A backoff must not wedge the database permanently. Creating it removes the
# fault, and the next retry should then produce a worker that stays up. No
# CREATE EXTENSION here: a worker that connects but finds the extension missing
# waits and rechecks rather than exiting, which is exactly the "started and
# stayed up" case this needs.
$node->safe_psql('postgres', "CREATE DATABASE $missing");

my $started = 0;
my $deadline = time() + 60;

while (time() < $deadline)
{
	$log = slurp_file($node->logfile, $log_offset);

	if ($log =~ /worker started \(database: \Q$missing\E\)/)
	{
		$started = 1;
		last;
	}

	sleep 1;
}

ok($started,
	'the launcher retries after the backoff, so a database that appears later is picked up');

$node->stop;
done_testing();

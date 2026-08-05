# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that the launcher refills a slot promptly when a worker exits, rather
# than waiting for its next periodic sweep.
#
# Per-database workers are registered BGW_NEVER_RESTART, so the launcher alone
# is responsible for bringing one back. It learns that a worker exited from the
# bgw_notify_pid notification, which the postmaster delivers as SIGUSR1. That
# notification only arrives if the launcher installs a SIGUSR1 handler itself:
# BackgroundWorkerMain() points SIGUSR1 at SIG_IGN for any worker that did not
# request BGWORKER_BACKEND_DATABASE_CONNECTION, and the launcher deliberately
# takes no database connection.
#
# With the notification dropped, the only remaining mechanism is the sweep
# timeout, which is LAUNCHER_SWEEP_INTERVAL_IDLE_MS (60s) whenever every
# database has its own resident worker. This test therefore uses a
# non-oversubscribed configuration, where the brisk rotating sweep would
# otherwise mask the problem, and requires the replacement well inside 60s.
#
# Progress is judged from worker PIDs in pg_stat_activity rather than from
# counting messages in the server log. The log directory persists between runs
# in a given build tree, so a log-counting test would see the previous run's
# startup messages and pass without anything having been respawned.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Fewer databases than num_workers, so both workers are resident and the
# launcher uses its idle sweep interval.
my @dbs = qw(respawndb1 respawndb2);

my $node = PostgreSQL::Test::Cluster->new('vectorizer_respawn');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.databases = '@{[ join ',', @dbs ]}'
pgedge_vectorizer.num_workers = 4
pgedge_vectorizer.worker_poll_interval = 200
max_worker_processes = 16
));
$node->start;

for my $db (@dbs)
{
	$node->safe_psql('postgres', "CREATE DATABASE $db");
	$node->safe_psql($db,        'CREATE EXTENSION pgedge_vectorizer CASCADE');
}

# Databases created after startup need a reload before the launcher sees them.
$node->reload;

my $first = wait_for_worker_pid($node, 'respawndb1', undef, 120);
like($first, qr/^\d+$/, 'a resident worker starts for the database');

# Terminate the worker cleanly. This exits 0, so unlike a signal death it does
# not provoke a postmaster-wide crash restart, which would bring the worker
# back by restarting everything and prove nothing about the launcher.
$node->safe_psql('postgres', "SELECT pg_terminate_backend($first)");

# The launcher must notice and relaunch. 20s is far longer than the
# notification path needs and far shorter than the 60s idle sweep, so this
# fails if the notification is being dropped.
my $second = wait_for_worker_pid($node, 'respawndb1', $first, 20);
like($second, qr/^\d+$/,
	'the launcher relaunches an exited worker without waiting for its idle sweep');

$node->stop;
done_testing();

# Wait for a worker servicing $db whose PID is not $exclude, and return that
# PID. Returns the empty string if none appears within $timeout seconds.
#
# backend_type reports bgw_type, which the extension sets to its own name; the
# launcher itself has no row here, having no database connection.
sub wait_for_worker_pid
{
	my ($node, $db, $exclude, $timeout) = @_;
	my $deadline = time() + $timeout;
	my $filter = defined($exclude) ? "AND pid <> $exclude" : '';

	while (time() < $deadline)
	{
		my $pid = $node->safe_psql('postgres',
			"SELECT pid FROM pg_stat_activity
			  WHERE datname = '$db'
				AND backend_type = 'pgedge_vectorizer' $filter
			  LIMIT 1");

		return $pid if $pid =~ /^\d+$/;
		sleep 1;
	}

	return '';
}

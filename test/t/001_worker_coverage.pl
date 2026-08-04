# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that every database listed in pgedge_vectorizer.databases is serviced
# by a background worker, regardless of how many workers the concurrency cap
# allows to run at once.
#
# This cannot be expressed in pg_regress, which runs against a single database
# and cannot manipulate shared_preload_libraries.

use strict;
use warnings;

#
# These modules must be loaded at compile time with use, rather than guarded
# with a runtime require: PostgreSQL::Test::Utils contains an INIT block, and
# requiring it at runtime fails with "Too late to run INIT block". Whether the
# modules are available at all is decided in the Makefile, which only enables
# TAP tests when it can see them.

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

# Deliberately more databases than num_workers allows to run concurrently.
my @dbs = qw(vecdb1 vecdb2 vecdb3 vecdb4 vecdb5);

my $node = PostgreSQL::Test::Cluster->new('vectorizer');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.databases = '@{[ join ',', @dbs ]}'
pgedge_vectorizer.num_workers = 2
pgedge_vectorizer.worker_poll_interval = 200
pgedge_vectorizer.worker_service_quantum = 5
max_worker_processes = 16
));
$node->start;

# Create every database and install the extension in each one. A worker only
# announces itself once it can see the extension.
for my $db (@dbs)
{
	$node->safe_psql('postgres', "CREATE DATABASE $db");
	$node->safe_psql($db,        'CREATE EXTENSION pgedge_vectorizer CASCADE');
}

# Reload so that databases created after startup are picked up, then wait for
# each one to report a worker.
$node->reload;

my @unserviced = wait_for_all_databases_serviced($node, \@dbs, 120);

is_deeply(\@unserviced, [],
	'every configured database is serviced with num_workers below the database count');

# Coverage alone is not enough: a worker that always has work must still give
# up its slot, or the databases at the tail of the list would starve exactly as
# they did before the launcher existed. Confirm each database is serviced more
# than once, which can only happen if slots genuinely rotate.
my %service_counts;
my $rotate_deadline = time() + 120;

while (time() < $rotate_deadline)
{
	my $log = slurp_file($node->logfile);

	for my $db (@dbs)
	{
		my @hits = ($log =~ /worker started \(database: \Q$db\E\)/g);
		$service_counts{$db} = scalar(@hits);
	}

	last if !grep { ($service_counts{$_} // 0) < 2 } @dbs;
	sleep 1;
}

my @not_rotated = grep { ($service_counts{$_} // 0) < 2 } @dbs;

is_deeply(\@not_rotated, [],
	'every database is serviced repeatedly, so worker slots rotate');

# A database added at runtime must be picked up on reload, without a restart.
$node->safe_psql('postgres', 'CREATE DATABASE vecdb6');
$node->safe_psql('vecdb6',   'CREATE EXTENSION pgedge_vectorizer CASCADE');
$node->safe_psql('postgres',
	"ALTER SYSTEM SET pgedge_vectorizer.databases = '"
	  . join(',', @dbs, 'vecdb6') . "'");
$node->reload;

my @added = wait_for_all_databases_serviced($node, ['vecdb6'], 120);
is_deeply(\@added, [], 'a database added by SIGHUP is picked up');

# num_workers is PGC_SIGHUP now, so raising it must not need a restart.
$node->safe_psql('postgres', 'ALTER SYSTEM SET pgedge_vectorizer.num_workers = 4');
$node->reload;

my $shown = $node->safe_psql('postgres', 'SHOW pgedge_vectorizer.num_workers');
is($shown, '4', 'num_workers can be changed by reload without a restart');

$node->stop;
done_testing();

# Wait until every database in $dbs has announced a worker in the server log,
# or until $timeout seconds elapse. Returns the databases that never appeared.
sub wait_for_all_databases_serviced
{
	my ($node, $dbs, $timeout) = @_;
	my %seen;
	my $deadline = time() + $timeout;

	while (time() < $deadline)
	{
		my $log = slurp_file($node->logfile);

		for my $db (@$dbs)
		{
			$seen{$db} = 1
			  if $log =~ /extension found in database '\Q$db\E'/;
		}

		return () if keys(%seen) == scalar(@$dbs);
		sleep 1;
	}

	return grep { !$seen{$_} } @$dbs;
}

# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that one vectorizer naming a provider that does not exist does not
# stop the worker doing every other vectorizer's work.
#
# Resolving the provider used to raise, which aborted the transaction and
# returned the whole pull to pending, including items whose provider was
# perfectly fine. The next pull claimed the same oldest rows and aborted in the
# same place, so nothing drained and nothing failed: one vectorizer's typo
# stopped the database (issue #76). Before a vectorizer could name its own
# provider this could not discriminate, since a bad one meant nothing could
# proceed anyway.
#
# The group is now put back and skipped instead. What must not change is that
# its items are never charged for it: 005_batch_failure_backoff.pl covers that
# for the case where every vectorizer is affected, and it is asserted here too
# for the case where only one is.
#
# As in 014, the poll interval is long and everything is queued before the
# database is named, so that the healthy work has to be done by the same pull
# that met the bad provider rather than by a later one.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use IO::Socket::INET;

my $dbname = 'unavailable_isolation';
my $rows = 3;

# The socket is created before the fork, so the port is known without guessing
# one or waiting for the child to report it.
my $listener = IO::Socket::INET->new(
	LocalAddr => '127.0.0.1',
	LocalPort => 0,
	Proto     => 'tcp',
	Listen    => 16,
	ReuseAddr => 1) or die "could not listen: $!";

my $port = $listener->sockport;
my $tempdir = PostgreSQL::Test::Utils::tempdir;

my $server_pid = fork();
die "fork failed: $!" unless defined $server_pid;

if ($server_pid == 0)
{
	fake_provider($listener);
	exit 0;
}

$listener->close;

# Kill the provider however this test ends. Without it a failed assertion
# leaves the child holding the pipe and prove waits on it for ever, which turns
# a clear failure into a hung run.
END { kill 'TERM', $server_pid if $server_pid; }

# Never checked by the socket above, but the provider will not start without it.
my $keyfile = "$tempdir/api_key";
open my $kf, '>', $keyfile or die "could not write $keyfile: $!";
print $kf "not-a-real-key\n";
close $kf;
chmod 0600, $keyfile;

my $node = PostgreSQL::Test::Cluster->new('vectorizer_unavailable_isolation');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.worker_poll_interval = 20000
pgedge_vectorizer.provider = 'voyage'
pgedge_vectorizer.model = 'healthy-model'
pgedge_vectorizer.api_url = 'http://127.0.0.1:$port/v1'
pgedge_vectorizer.api_key_file = '$keyfile'
pgedge_vectorizer.batch_size = 25
max_worker_processes = 16
));

$node->start;

$node->safe_psql('postgres', "CREATE DATABASE $dbname");
$node->safe_psql($dbname, 'CREATE EXTENSION vector');
$node->safe_psql($dbname, 'CREATE EXTENSION pgedge_vectorizer');

$node->safe_psql($dbname,
	'CREATE TABLE broken (id BIGSERIAL PRIMARY KEY, body TEXT)');
$node->safe_psql($dbname,
	'CREATE TABLE healthy (id BIGSERIAL PRIMARY KEY, body TEXT)');

# 'no_such_provider' sorts before 'voyage', so the unusable group is reached
# first within the pull, which is the arrangement the raise used to ruin.
$node->safe_psql($dbname,
	q(SELECT pgedge_vectorizer.enable_vectorization('broken', 'body',
													embedding_dimension => 3,
													provider => 'no_such_provider',
													model => 'whatever')));
$node->safe_psql($dbname,
	q(SELECT pgedge_vectorizer.enable_vectorization('healthy', 'body',
													embedding_dimension => 3,
													provider => 'voyage',
													model => 'healthy-model')));

$node->safe_psql($dbname, qq(
BEGIN;
INSERT INTO broken (body)
	SELECT 'broken chunk ' || g FROM generate_series(1, $rows) g;
INSERT INTO healthy (body)
	SELECT 'healthy chunk ' || g FROM generate_series(1, $rows) g;
COMMIT;
));

my $offset = (-s $node->logfile) // 0;

# Now let a worker have it, so the clock below runs from a known point.
$node->append_conf('postgresql.conf',
	"pgedge_vectorizer.databases = '$dbname'\n");
$node->reload;

# Half the poll interval: a pass means the same pull carried on past the
# unusable provider rather than a later poll picking the work up.
my $deadline = time() + 10;
my $healthy = 0;

while (time() < $deadline)
{
	$healthy = $node->safe_psql($dbname,
		"SELECT count(*) FROM pgedge_vectorizer.queue
		  WHERE chunk_table = 'healthy_body_chunks' AND status = 'completed'");

	last if $healthy == $rows;

	sleep 1;
}

is($healthy, $rows,
	'the same pull that met the unusable provider goes on to the healthy one');

# The misconfigured vectorizer's items are left exactly as they were: still
# queued, no attempt spent, so correcting the provider is all that is needed.
is($node->safe_psql($dbname,
		q(SELECT count(*) || ' ' || COALESCE(max(attempts), 0) || ' ' ||
				 COALESCE(string_agg(DISTINCT status, ','), '')
			FROM pgedge_vectorizer.queue
		   WHERE chunk_table = 'broken_body_chunks')),
	"$rows 0 pending",
	'the misconfigured vectorizer\'s items wait, uncharged');

# And an operator is told which provider and which table, rather than being
# left to infer it from a queue that is not moving.
my $log = slurp_file($node->logfile, $offset);

like($log,
	qr/provider "no_such_provider" for broken_body_chunks is unavailable/,
	'the log names the provider and the table it belongs to');

# Correcting it is enough on its own: nothing needs retrying, because nothing
# was ever charged.
$node->safe_psql($dbname,
	q(SELECT pgedge_vectorizer.set_embedding_model('broken', 'body',
												   'healthy-model',
												   provider => 'voyage',
												   embedding_dimension => 3)));

$deadline = time() + 30;
my $broken = 0;

while (time() < $deadline)
{
	$broken = $node->safe_psql($dbname,
		"SELECT count(*) FROM pgedge_vectorizer.queue
		  WHERE chunk_table = 'broken_body_chunks' AND status = 'completed'");

	last if $broken == $rows;

	sleep 1;
}

is($broken, $rows, 'correcting the provider is enough to drain the queue');

$node->stop;

kill 'TERM', $server_pid;
waitpid $server_pid, 0;

done_testing();

# Answer everything. The fault under test is on this side of the network: the
# provider named by one vectorizer does not exist, so no request is ever made
# for it.
sub fake_provider
{
	my ($socket) = @_;

	while (my $conn = $socket->accept())
	{
		my $headers = '';
		my $body    = '';
		my $length;
		my $inputs  = 0;
		my $texts;
		my $payload;

		$conn->autoflush(1);

		while (my $line = <$conn>)
		{
			$headers .= $line;
			last if $line =~ /^\r?\n\z/;
		}

		# read() can come back short of Content-Length on a socket, and a
		# partial body would count the wrong number of inputs.
		($length) = $headers =~ /^content-length:\s*(\d+)/im;
		while ($length && length($body) < $length)
		{
			my $chunk = '';
			my $got = read $conn, $chunk, $length - length($body);

			die 'truncated request body' unless $got;
			$body .= $chunk;
		}

		# {"input":["...","..."],"model":"..."}. The chunk text is ours and
		# has no quotes in it, so counting quoted strings counts the items.
		($texts) = $body =~ /"input"\s*:\s*\[(.*?)\]/s;
		$inputs++ while defined $texts && $texts =~ /"(?:[^"\\]|\\.)*"/g;

		$payload = '{"data":['
			. join(',', ('{"embedding":[0.1,0.2,0.3]}') x $inputs)
			. ']}';
		$conn->print("HTTP/1.1 200 OK\r\n"
				. "Content-Type: application/json\r\n"
				. "Content-Length: " . length($payload) . "\r\n"
				. "Connection: close\r\n\r\n"
				. $payload);

		$conn->close;
	}
}

# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that each vectorizer's chunks are embedded with its own model, and
# that no single request ever carries two.
#
# The model used to come straight from pgedge_vectorizer.model inside each
# provider, so every table in a database was embedded with the same one. A
# vectorizer may now pin its own, with NULL in the registry meaning inherit,
# which puts two demands on the worker: the right model has to reach the
# request, and a batch that spans two vectorizers has to be split, because a
# request carries one model for every text in it.
#
# The second is the one worth a test with a real worker. A batch is selected
# by age across every vectorizer at once, so the two tables' items interleave
# in the queue; the worker groups them before issuing anything. Both tables are
# populated in one transaction so that a single poll is guaranteed to see all
# six items, which is the case that would otherwise send one model's text under
# the other's name.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use IO::Socket::INET;

my $dbname = 'per_table_model';
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
my $requestlog = "$tempdir/requests.log";

my $server_pid = fork();
die "fork failed: $!" unless defined $server_pid;

if ($server_pid == 0)
{
	fake_provider($listener, $requestlog);
	exit 0;
}

$listener->close;

# Never checked by the socket above, but the provider will not start without it.
my $keyfile = "$tempdir/api_key";
open my $kf, '>', $keyfile or die "could not write $keyfile: $!";
print $kf "not-a-real-key\n";
close $kf;
chmod 0600, $keyfile;

my $node = PostgreSQL::Test::Cluster->new('vectorizer_per_table_model');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.worker_poll_interval = 500
pgedge_vectorizer.provider = 'voyage'
pgedge_vectorizer.model = 'aaa-inherited-model'
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
	'CREATE TABLE inherits (id BIGSERIAL PRIMARY KEY, body TEXT)');
$node->safe_psql($dbname,
	'CREATE TABLE pinned (id BIGSERIAL PRIMARY KEY, body TEXT)');

# One inherits the GUC, the other pins its own. The names sort in the order the
# worker groups them, so the request log below is deterministic.
$node->safe_psql($dbname,
	q(SELECT pgedge_vectorizer.enable_vectorization('inherits', 'body',
													embedding_dimension => 3)));
$node->safe_psql($dbname,
	q(SELECT pgedge_vectorizer.enable_vectorization('pinned', 'body',
													embedding_dimension => 3,
													model => 'zzz-pinned-model')));

my $registry = $node->safe_psql($dbname,
	q(SELECT string_agg(source_table || '=' || COALESCE(model, 'NULL'), ' '
						ORDER BY source_table)
		FROM pgedge_vectorizer.vectorizers));

is($registry, 'inherits=NULL pinned=zzz-pinned-model',
	'a vectorizer records its own model, and NULL where it inherits');

# Name the database only once it is ready to be serviced, so that no worker can
# arrive before the extension exists and take its five second backoff instead.
$node->append_conf('postgresql.conf',
	"pgedge_vectorizer.databases = '$dbname'\n");
$node->reload;

# One transaction, so a single poll is guaranteed to see both tables' items.
# That is the case being tested: a batch holding two models at once.
$node->safe_psql($dbname, qq(
BEGIN;
INSERT INTO inherits (body)
	SELECT 'inherited chunk ' || g FROM generate_series(1, $rows) g;
INSERT INTO pinned (body)
	SELECT 'pinned chunk ' || g FROM generate_series(1, $rows) g;
COMMIT;
));

my $wanted = $rows * 2;
my $deadline = time() + 30;
my $completed = 0;

while (time() < $deadline)
{
	$completed = $node->safe_psql($dbname,
		"SELECT count(*) FROM pgedge_vectorizer.queue WHERE status = 'completed'");

	last if $completed == $wanted;

	sleep 1;
}

is($completed, $wanted, 'both vectorizers drain');

# Each line is one request: the model it named and how many texts it carried.
my @requests = split /\n/, slurp_file($requestlog);

is(scalar(@requests), 2,
	'a batch spanning two models is split into one request per model');

is($requests[0], "aaa-inherited-model $rows",
	'the inheriting table is embedded with the GUC\'s model, all in one request');
is($requests[1], "zzz-pinned-model $rows",
	'the pinned table is embedded with its own model, all in one request');

# Nothing failed, which is what a request carrying the wrong model would have
# risked once the dimensions differed.
my $failed = $node->safe_psql($dbname,
	"SELECT count(*) FROM pgedge_vectorizer.queue WHERE status = 'failed'");

is($failed, '0', 'no item fails on the way');

$node->stop;

kill 'TERM', $server_pid;
waitpid $server_pid, 0;

done_testing();

# Answer every request, logging the model it named and the number of texts it
# carried. Those two together are what the assertions above read: a request
# naming one model but carrying another table's text would show up as a count
# that does not match, and a request mixing the two cannot be represented at
# all, because the provider API takes one model per request.
sub fake_provider
{
	my ($socket, $logfile) = @_;

	open my $log, '>', $logfile or die "could not write $logfile: $!";
	$log->autoflush(1);

	while (my $conn = $socket->accept())
	{
		my $headers = '';
		my $body    = '';
		my $length;
		my $inputs  = 0;
		my $texts;
		my $model;
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

		($model) = $body =~ /"model"\s*:\s*"([^"]*)"/;
		$model = '(none)' unless defined $model;

		$log->print("$model $inputs\n");

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

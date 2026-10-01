# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that the worker records the provider and model it actually embedded
# with, per chunk.
#
# The regression tests write embedding_provider and embedding_model by hand,
# because a real embedding needs a provider, so they check what
# embedding_model_status() and reembed() make of those columns but never that
# anything fills them in. That is the half worth a running worker: the columns
# are written in the same statement as the vector, in update_embedding(), and
# the value has to be the one that request actually carried rather than
# whatever the GUC happens to say.
#
# Two vectorizers on different models make the difference visible. Recording
# the GUC instead of the per-request value would put the same model on both.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use IO::Socket::INET;

my $dbname = 'model_recorded';
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

# Never checked by the socket above, but the provider will not start without it.
my $keyfile = "$tempdir/api_key";
open my $kf, '>', $keyfile or die "could not write $keyfile: $!";
print $kf "not-a-real-key\n";
close $kf;
chmod 0600, $keyfile;

my $node = PostgreSQL::Test::Cluster->new('vectorizer_model_recorded');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.worker_poll_interval = 500
pgedge_vectorizer.provider = 'voyage'
pgedge_vectorizer.model = 'inherited-model'
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

$node->safe_psql($dbname,
	q(SELECT pgedge_vectorizer.enable_vectorization('inherits', 'body',
													embedding_dimension => 3)));
$node->safe_psql($dbname,
	q(SELECT pgedge_vectorizer.enable_vectorization('pinned', 'body',
													embedding_dimension => 3,
													model => 'pinned-model')));

# Name the database only once it is ready to be serviced, so that no worker can
# arrive before the extension exists and take its five second backoff instead.
$node->append_conf('postgresql.conf',
	"pgedge_vectorizer.databases = '$dbname'\n");
$node->reload;

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

# What each table's rows say produced them.
is($node->safe_psql($dbname,
		q(SELECT string_agg(DISTINCT embedding_provider || '/' ||
							embedding_model, ' ')
			FROM inherits_body_chunks WHERE embedding IS NOT NULL)),
	'voyage/inherited-model',
	'the inheriting table records the GUC model it was embedded with');

is($node->safe_psql($dbname,
		q(SELECT string_agg(DISTINCT embedding_provider || '/' ||
							embedding_model, ' ')
			FROM pinned_body_chunks WHERE embedding IS NOT NULL)),
	'voyage/pinned-model',
	'the pinned table records its own model, not the GUC');

# Every row, not merely some: a missed write would show as a NULL here.
is($node->safe_psql($dbname,
		q(SELECT count(*) FROM inherits_body_chunks
		   WHERE embedding IS NOT NULL AND embedding_model IS NULL)
	   ),
	'0', 'no embedded chunk is left without a recorded model');

# And what the report makes of it: everything current, nothing drifted, and
# nothing unknown, since every row was written by this worker.
is($node->safe_psql($dbname,
		q(SELECT string_agg(source_table || ' ' || chunks_embedded || ' ' ||
							chunks_current || ' ' || chunks_other_model ||
							' ' || chunks_model_unknown, E'\n'
							ORDER BY source_table)
			FROM pgedge_vectorizer.embedding_model_status())),
	"inherits $rows $rows 0 0\npinned $rows $rows 0 0",
	'the report sees every chunk as current');

# Nothing to redo, so reembed() queues nothing and disturbs nothing.
is($node->safe_psql($dbname,
		q(SELECT pgedge_vectorizer.reembed('pinned', 'body',
										   embedding_dimension => 3))),
	'0', 'reembed() queues nothing when every chunk is already current');

$node->stop;

kill 'TERM', $server_pid;
waitpid $server_pid, 0;

done_testing();

# Answer every request with an embedding per input. The model each request
# names does not matter here; what is being checked is what the worker writes
# to the chunk table afterwards.
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

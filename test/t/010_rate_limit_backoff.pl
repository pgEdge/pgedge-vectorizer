# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that a provider rate limit is retried as a rate limit: the items go
# back together, they wait as long as the provider asked, and none of them
# spends a retry on it.
#
# A 429 is ordinary traffic against any provider worth using, and it says
# nothing about the text in the request. Treating it as an item failure went
# wrong three ways at once, each multiplying the next: a retried item was sent
# on its own, so one 429 reduced every later request to a single chunk and hit
# the request limit immediately; the wait grew a minute per attempt with
# nothing bounding it, the Retry-After having been discarded with the status
# code; and the attempt was charged to the item, spending the retry budget of
# work that was fine. Against a free tier this turned a couple of minutes of
# queue into tens of minutes with nothing ever failing (issue #69).
#
# The provider here refuses the first request with 429 and a three second
# Retry-After, then answers. What matters is the shape of the second request:
# one request carrying every item, three seconds later, attempts still zero.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use IO::Socket::INET;

my $dbname = 'rate_limit';
my $chunks = 5;

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

my $node = PostgreSQL::Test::Cluster->new('vectorizer_rate_limit');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.worker_poll_interval = 500
pgedge_vectorizer.provider = 'voyage'
pgedge_vectorizer.api_url = 'http://127.0.0.1:$port/v1'
pgedge_vectorizer.api_key_file = '$keyfile'
pgedge_vectorizer.batch_size = 25
pgedge_vectorizer.max_retries = 10
max_worker_processes = 16
));

$node->start;

$node->safe_psql('postgres', "CREATE DATABASE $dbname");
$node->safe_psql($dbname, 'CREATE EXTENSION vector');
$node->safe_psql($dbname, 'CREATE EXTENSION pgedge_vectorizer');
$node->safe_psql($dbname,
	'CREATE TABLE docs (id BIGSERIAL PRIMARY KEY, body TEXT)');
$node->safe_psql($dbname,
	q(SELECT pgedge_vectorizer.enable_vectorization('docs', 'body',
													embedding_dimension => 3)));

# Name the database only once it is ready to be serviced, so that no worker can
# arrive before the extension exists and take its five second backoff instead.
$node->append_conf('postgresql.conf',
	"pgedge_vectorizer.databases = '$dbname'\n");
$node->reload;

my $offset = (-s $node->logfile) // 0;

# One chunk per row: the bodies are far shorter than a chunk.
$node->safe_psql($dbname,
	"INSERT INTO docs (body) SELECT 'chunk number ' || g FROM generate_series(1, $chunks) g");

# Thirty seconds is many times the provider's three, and still short of the
# minute the first retry used to take on its own.
my $deadline = time() + 30;
my $completed = 0;

while (time() < $deadline)
{
	$completed = $node->safe_psql($dbname,
		"SELECT count(*) FROM pgedge_vectorizer.queue WHERE status = 'completed'");

	last if $completed == $chunks;

	sleep 1;
}

is($completed, $chunks,
	'a rate limited queue drains once the provider is ready, not minutes later');

# The retry has to be one request carrying every item. Sending them one at a
# time is what walks the queue back into a request-per-minute limit.
my @requests = split /\n/, slurp_file($requestlog);

is(scalar(@requests), 2,
	'the refused items are retried in a single request, not one request each');

is($requests[0], "429 $chunks", 'the first request is refused for all items');
is($requests[1], "200 $chunks",
	'the retry carries the same batch rather than one chunk at a time');

# Nothing charged for being told to wait, and the deferral is visible.
my $spent = $node->safe_psql($dbname,
	"SELECT count(*) FROM pgedge_vectorizer.queue WHERE attempts > 0");

is($spent, '0', 'a rate limit does not spend an item\'s retry budget');

my $deferred = $node->safe_psql($dbname,
	'SELECT count(*) FROM pgedge_vectorizer.queue WHERE rate_limit_deferrals = 1');

is($deferred, $chunks, 'the deferral is counted separately from the attempts');

# Three seconds, where the attempt-counted backoff would have said sixty.
my $log = slurp_file($node->logfile, $offset);

like($log,
	qr/provider rate limited \(HTTP 429\), deferring $chunks queue items, next attempt in 3s/,
	'the wait honours the provider\'s Retry-After and says so');

$node->stop;

kill 'TERM', $server_pid;
waitpid $server_pid, 0;

done_testing();

# Refuse the first request with a 429 naming a three second wait, then answer
# everything after it. Each request is logged as its status and the number of
# texts it carried, which is what the batching assertions read.
sub fake_provider
{
	my ($socket, $logfile) = @_;
	my $seen = 0;

	open my $log, '>', $logfile or die "could not write $logfile: $!";
	$log->autoflush(1);

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

		$seen++;

		if ($seen == 1)
		{
			$log->print("429 $inputs\n");
			$payload = '{"detail":"rate limit exceeded"}';
			$conn->print("HTTP/1.1 429 Too Many Requests\r\n"
					. "Retry-After: 3\r\n"
					. "Content-Type: application/json\r\n"
					. "Content-Length: " . length($payload) . "\r\n"
					. "Connection: close\r\n\r\n"
					. $payload);
		}
		else
		{
			$log->print("200 $inputs\n");
			$payload = '{"data":['
				. join(',', ('{"embedding":[0.1,0.2,0.3]}') x $inputs)
				. ']}';
			$conn->print("HTTP/1.1 200 OK\r\n"
					. "Content-Type: application/json\r\n"
					. "Content-Length: " . length($payload) . "\r\n"
					. "Connection: close\r\n\r\n"
					. $payload);
		}

		$conn->close;
	}
}

# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that one provider being rate limited does not stop the worker doing
# another provider's work.
#
# The cooldown taken after a 429 was a single deadline checked before the pull,
# so it held off every provider at once, and the 429 handler broke out of the
# request loop so nothing else in that pull was attempted either. That was
# right when a database had one provider. Since a vectorizer can name its own,
# a hosted provider on a free tier could hold up a local model with no rate
# limit at all, which is the fault this measures (issue #76).
#
# Both vectorizers share one fake provider socket, because api_url is still a
# single setting: what a vectorizer picks is the provider and the model, not
# where the provider points. The server therefore decides by the model named in
# the request, refusing one and answering the other, which keeps the test to
# what the extension actually supports.
#
# The Retry-After is deliberately far longer than the test's patience: the
# healthy vectorizer has to drain whilst the other is still cooling, or the
# result would say nothing.
#
# The poll interval is deliberately longer still. Excluding a cooling provider
# from the claim is only half the fix; the other half is that a 429 stops
# ending the whole pull, and that half is invisible if the healthy work may
# simply be picked up on the next poll. So everything is queued before the
# database is named for servicing, and the healthy chunks have to be embedded
# well inside one poll interval, which they can only be if the same pull that
# met the 429 carried on to them.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

use IO::Socket::INET;

my $dbname = 'rate_limit_isolation';
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
# leaves the child holding the inherited pipe and the bound port, so prove
# waits on it instead of reporting the failure.
END { kill 'TERM', $server_pid if $server_pid; }

# Never checked by the socket above, but the providers will not start without it.
my $keyfile = "$tempdir/api_key";
open my $kf, '>', $keyfile or die "could not write $keyfile: $!";
print $kf "not-a-real-key\n";
close $kf;
chmod 0600, $keyfile;

my $node = PostgreSQL::Test::Cluster->new('vectorizer_rate_limit_isolation');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.worker_poll_interval = 20000
pgedge_vectorizer.provider = 'openai'
pgedge_vectorizer.model = 'unused-default'
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
	'CREATE TABLE limited (id BIGSERIAL PRIMARY KEY, body TEXT)');
$node->safe_psql($dbname,
	'CREATE TABLE healthy (id BIGSERIAL PRIMARY KEY, body TEXT)');

# 'limited' sorts before 'healthy' on (provider, model) because openai sorts
# before voyage, so the refused provider is reached first within a pull. That
# is the arrangement in which breaking out of the loop loses the healthy work.
$node->safe_psql($dbname,
	q(SELECT pgedge_vectorizer.enable_vectorization('limited', 'body',
													embedding_dimension => 3,
													provider => 'openai',
													model => 'limited-model')));
$node->safe_psql($dbname,
	q(SELECT pgedge_vectorizer.enable_vectorization('healthy', 'body',
													embedding_dimension => 3,
													provider => 'voyage',
													model => 'healthy-model')));

# Queued before the database is named, so that the worker's very first pull
# holds both tables' items, with the refused provider's sorting first.
$node->safe_psql($dbname, qq(
BEGIN;
INSERT INTO limited (body)
	SELECT 'limited chunk ' || g FROM generate_series(1, $rows) g;
INSERT INTO healthy (body)
	SELECT 'healthy chunk ' || g FROM generate_series(1, $rows) g;
COMMIT;
));

# Now let a worker have it. The reload is what starts the servicing, so the
# clock below runs from a known point.
$node->append_conf('postgresql.conf',
	"pgedge_vectorizer.databases = '$dbname'\n");
$node->reload;

# Ten seconds is half the poll interval, so a pass means the healthy chunks
# were embedded by the same pull that met the 429 rather than by a later one.
# It is also far short of the provider's three hundred second Retry-After, so
# a pass cannot come from the cooldown quietly expiring either.
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
	'the same pull that met the 429 goes on to the healthy provider');

# And the refused one is deferred rather than failed or forgotten: its items
# are waiting on the Retry-After with no attempt charged.
is($node->safe_psql($dbname,
		q(SELECT count(*) || ' ' || COALESCE(max(attempts), 0) || ' ' ||
				 COALESCE(string_agg(DISTINCT status, ','), '')
			FROM pgedge_vectorizer.queue
		   WHERE chunk_table = 'limited_body_chunks')),
	"$rows 0 pending",
	'the rate limited provider\'s items wait, uncharged');

is($node->safe_psql($dbname,
		q(SELECT count(*) FROM pgedge_vectorizer.queue
		   WHERE chunk_table = 'limited_body_chunks'
			 AND rate_limit_deferrals = 1)),
	"$rows", 'the deferral is counted against them, once');

$node->stop;

kill 'TERM', $server_pid;
waitpid $server_pid, 0;

done_testing();

# Refuse anything asking for limited-model, with a Retry-After far beyond the
# test's patience, and answer everything else. Both providers post the same
# body shape to the same path, so the model is what tells them apart.
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

		if ($body =~ /"model"\s*:\s*"limited-model"/)
		{
			$payload = '{"detail":"rate limit exceeded"}';
			$conn->print("HTTP/1.1 429 Too Many Requests\r\n"
					. "Retry-After: 300\r\n"
					. "Content-Type: application/json\r\n"
					. "Content-Length: " . length($payload) . "\r\n"
					. "Connection: close\r\n\r\n"
					. $payload);
			$conn->close;
			next;
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

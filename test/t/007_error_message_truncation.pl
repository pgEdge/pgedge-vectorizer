# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that an over-long error message is clipped on a character boundary, so
# that the failure can still be recorded against the item.
#
# The worker keeps a failed item's message in a fixed 1024 byte buffer and
# quotes it into the UPDATE that charges the attempt. Clipping that buffer by
# bytes left a partial character behind whenever the cut fell inside a multi-byte
# one, and that partial character was then stored: SPI does not cross the
# protocol boundary at which input from a client is checked, so nothing on the
# way in validates the encoding. queue.error_message was left holding text that
# is invalid in the server encoding, and reading such a row back with anything
# that walks characters rather than bytes -- length(), or a client decoding
# strictly -- fails.
#
# The failure itself is still recorded, so this is not the runaway that 004 rules
# out; the damage is confined to the stored message.
#
# The fault injected here is a trigger on the chunk table that raises a message
# of 1022 single-byte characters followed by one three-byte character, so the
# 1023rd byte of the buffer is the first byte of a character whose other two do
# not fit.
#
# The item is marked sparse_only, so no embedding is ever requested, but the
# worker resolves and initialises the provider for every batch before it reaches
# that decision. The provider is therefore set to ollama, whose init needs
# neither an API key nor a network round trip; nothing here ever calls it to
# generate anything.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $dbname = 'message_truncation';

# Deliberately no pgedge_vectorizer.databases yet; see the comment in 004 about
# why the database is named only once its extension exists.
my $node = PostgreSQL::Test::Cluster->new('vectorizer_message_truncation');

# The encoding is pinned rather than inherited from whatever locale the developer
# happens to be running under, because this test counts bytes: it relies on
# U+4E16 occupying three of them, which is true of UTF-8 and not of everything
# else. The fix under test is encoding-agnostic, since pg_mbcliplen() reads the
# server encoding, but the arithmetic in the fixture below is not.
$node->init(extra => [ '--locale=C', '--encoding=UTF8' ]);
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.worker_poll_interval = 200
pgedge_vectorizer.provider = 'ollama'
pgedge_vectorizer.enable_hybrid = on
max_worker_processes = 16
));

$node->start;

$node->safe_psql('postgres', "CREATE DATABASE $dbname");
$node->safe_psql($dbname, 'CREATE EXTENSION vector');
$node->safe_psql($dbname, 'CREATE EXTENSION pgedge_vectorizer');

$node->append_conf('postgresql.conf',
	"pgedge_vectorizer.databases = '$dbname'\n");
$node->reload;

# The chunk table carries the columns the worker touches on this path: embedding,
# which the probe deciding whether a dense vector is still needed reads for every
# claimed item, and token_count and sparse_embedding, which the sparse path reads
# and writes. embedding is left NULL, so it is the queue row's own sparse_only
# flag that keeps the embedding provider out of this test. The _idf_stats sidecar
# is deliberately absent, which bm25_load_idf_stats() handles on its own.
#
# 1022 'x' followed by U+4E16, whose UTF-8 encoding is three bytes. The message
# is therefore 1025 bytes, and a byte-wise clip to fit a 1024 byte buffer keeps
# 1023 of them: the last is the first byte of a character on its own.
$node->safe_psql(
	$dbname, q(
CREATE TABLE long_message_chunks (
    id               bigint PRIMARY KEY,
    token_count      int,
    embedding        vector(3),
    sparse_embedding sparsevec
);

INSERT INTO long_message_chunks (id, token_count) VALUES (1, 3);

CREATE FUNCTION raise_long_message() RETURNS trigger AS $$
BEGIN
    RAISE EXCEPTION '%', repeat('x', 1022) || U&'\4E16';
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER raise_long_message
    BEFORE UPDATE ON long_message_chunks
    FOR EACH ROW EXECUTE FUNCTION raise_long_message();
));

my $log_offset = (-s $node->logfile) // 0;

$node->safe_psql(
	$dbname, qq(
INSERT INTO pgedge_vectorizer.queue
    (chunk_id, chunk_table, content, status, metadata, max_attempts)
VALUES (1, 'long_message_chunks', 'alpha beta gamma', 'pending',
        '{"sparse_only": true}'::jsonb, 2)
));

# Wait for the attempt rather than assuming one has happened by now. An unfixed
# build never records one, so this waits out the timeout and the assertion below
# fails on the value it did see.
my $attempts = 0;
my $deadline = time() + 30;

while (time() < $deadline)
{
	$attempts = $node->safe_psql($dbname,
		"SELECT attempts FROM pgedge_vectorizer.queue WHERE chunk_table = 'long_message_chunks'");

	last if $attempts > 0;

	sleep 1;
}

# A guard rather than the point of the test: recording the failure works either
# way, since the invalid sequence is stored rather than rejected, and both of
# these hold on an unfixed build too.
cmp_ok($attempts, '>', 0,
	'an over-long message does not stop the attempt being charged');

my $log = slurp_file($node->logfile, $log_offset);

unlike($log, qr/could not record failure for queue item/,
	'the failure is recorded rather than being reported as unrecordable');

# This is the point of the test. length() walks characters, so it raises on a
# stored message ending in half of one; an unfixed build fails here rather than
# returning a number.
my ($rc, $stdout, $stderr) = $node->psql($dbname, q(
SELECT length(error_message) FROM pgedge_vectorizer.queue
 WHERE chunk_table = 'long_message_chunks'
));

is($rc, 0,
	'the recorded message is valid in the server encoding');

is($stdout, '1022',
	'every character of the recorded message is whole');

# The message is kept as far as it fits and no further: 1022 bytes, because the
# three-byte character that follows cannot fit in the 1023 available and is
# therefore dropped whole rather than in part.
my $stored = $node->safe_psql($dbname, q(
SELECT octet_length(error_message) FROM pgedge_vectorizer.queue
 WHERE chunk_table = 'long_message_chunks'
));

is($stored, '1022',
	'the message is clipped to the last character that fits entirely');

my $intact = $node->safe_psql($dbname, q(
SELECT error_message = repeat('x', 1022) FROM pgedge_vectorizer.queue
 WHERE chunk_table = 'long_message_chunks'
));

is($intact, 't',
	'what is kept is the head of the message, unaltered');

# Prove the fixture is what the test claims, so that the assertions above cannot
# pass because the error was something shorter than the buffer all along. The
# length is measured by the server, which is the only thing that agrees with the
# worker on how many bytes the message runs to.
my $fixture_bytes = $node->safe_psql($dbname,
	q(SELECT octet_length(repeat('x', 1022) || U&'\4E16')));

is($fixture_bytes, '1025',
	'the injected message is longer than the buffer that has to hold it');

# And that this is the error the worker actually hit: it reports the original in
# full before recording it.
like($log, qr/x{1022}/,
	'the over-long message is the failure being recorded');

$node->stop;
done_testing();

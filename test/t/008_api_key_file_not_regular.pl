# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that pgedge_vectorizer.api_key_file refuses a path that is not a plain
# file instead of waiting on it.
#
# provider_load_api_key() used to stat() the path and then fopen() it. stat()
# opens nothing, so a FIFO passed every check made of it and the fopen() waited
# for a writer. That wait happens in libc, so CHECK_FOR_INTERRUPTS() is never
# reached: the backend showed as active with no wait event and ignored both
# statement_timeout and query cancellation. /dev/zero failed differently, never
# reaching end of file, so the read loop grew until the 1GB allocation limit.
#
# Each case runs under a timeout, so an unfixed build fails an assertion rather
# than hanging the suite. The regular-file cases are refused for their contents
# after the read, which is what shows ordinary files are still opened; none of
# them reaches the network.

use strict;
use warnings;

use POSIX qw(mkfifo);

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $dbname = 'api_key_file';

my $node = PostgreSQL::Test::Cluster->new('vectorizer_api_key_file');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.provider = 'openai'
));

$node->start;

$node->safe_psql('postgres', "CREATE DATABASE $dbname");
$node->safe_psql($dbname, 'CREATE EXTENSION vector');
$node->safe_psql($dbname, 'CREATE EXTENSION pgedge_vectorizer');

my $keydir = PostgreSQL::Test::Utils::tempdir;

# 0600 keeps the permissive-permissions warning out of stderr; it is not what is
# under test here.
sub write_key_file
{
	my ($name, $contents) = @_;
	my $path = "$keydir/$name";

	open my $fh, '>:raw', $path or die "could not create $path: $!";
	print $fh $contents;
	close $fh;
	chmod 0600, $path or die "could not chmod $path: $!";

	return $path;
}

# Ask for one embedding with api_key_file set to $path, under a timeout. The
# provider is never reached; every case is refused while the key is loaded.
sub check_key_file
{
	my ($label, $path, $expected) = @_;
	my ($stdout, $stderr, $timed_out);

	$node->psql(
		$dbname,
		"SET pgedge_vectorizer.provider = 'openai';\n"
		  . "SET pgedge_vectorizer.api_key_file = '$path';\n"
		  . "SELECT pgedge_vectorizer.generate_embedding('test');",
		stdout => \$stdout,
		stderr => \$stderr,
		timeout => $PostgreSQL::Test::Utils::timeout_default,
		timed_out => \$timed_out);

	ok(!$timed_out, "$label: answered rather than waited");
	like($stderr, $expected, "$label: reported the reason");

	return;
}

# The reported failure.
my $fifo = "$keydir/fifo-key";
mkfifo($fifo, 0600) or die "could not create $fifo: $!";
check_key_file('FIFO', $fifo, qr/is not a regular file/);

# Used to be read as zero bytes and reported as an empty key.
check_key_file('directory', $keydir, qr/is not a regular file/);

# Endless input rather than none: used to grow the buffer until the allocator
# refused it.
check_key_file('character device', '/dev/zero', qr/is not a regular file/);

# Regular files from here down: these pass S_ISREG() and are refused later.
check_key_file('empty file', write_key_file('empty-key', ''),
	qr/API key file is empty/);

check_key_file('whitespace only', write_key_file('blank-key', " \t\r\n\n"),
	qr/API key file is empty/);

# One byte past MAX_API_KEY_FILE_SIZE.
check_key_file('oversized file', write_key_file('big-key', 'x' x 4097),
	qr/is too large \(4097 bytes; limit 4096\)/);

# A null byte would cut the key short and look like a wrong credential.
check_key_file('embedded null', write_key_file('nul-key', "sk-\0secret\n"),
	qr/contains a null byte/);

done_testing();

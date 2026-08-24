# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that `~` in pgedge_vectorizer.api_key_file expands to the home
# directory of the OS user the backend runs as, and not to whatever HOME says.
#
# provider_expand_tilde() used to expand `~` with getenv("HOME"). HOME is set by
# whatever starts the server -- a systemd unit, a container entrypoint, a shell
# -- so a value pointing somewhere else silently redirected the key path to a
# file the server was never meant to read, and the key found there was sent to
# the provider (CWE-807). getpwuid(geteuid()) answers from the passwd database
# instead, which the environment cannot influence.
#
# The cluster is started with HOME pointing at a directory holding a key file,
# and the test asks for `~/<that file>`. A fixed build resolves past it to the
# real home directory and reports the key file missing there; an unfixed build
# finds the planted key and gets as far as the network.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use File::Spec;

use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $dbname = 'api_key_tilde';

# The home directory the fix must resolve to, straight from the passwd entry --
# the same source provider_expand_tilde() now reads.
my $real_home = (getpwuid($>))[7];
plan skip_all => 'no passwd home directory for the current user'
  unless defined $real_home && $real_home ne '';

# The planted home directory, and a key file name unlikely to exist in the real
# one -- the test turns on the real home NOT having it.
#
# rel2abs matters: tempdir is relative unless TESTDATADIR is absolute, and the
# backend resolves a relative path against its data directory rather than the
# directory prove was run from. A relative HOME would fail to find the planted
# key for that reason instead of because of the fix, which would let an unfixed
# build look like it had passed.
my $fake_home = File::Spec->rel2abs(PostgreSQL::Test::Utils::tempdir);
my $key_name = '.pgedge-vectorizer-tilde-home-test-key';

plan skip_all => "$real_home/$key_name exists; cannot test the missing case"
  if -e "$real_home/$key_name";

open my $fh, '>:raw', "$fake_home/$key_name"
  or die "could not create $fake_home/$key_name: $!";
print $fh "sk-planted-key-must-not-be-read\n";
close $fh;
chmod 0600, "$fake_home/$key_name"
  or die "could not chmod $fake_home/$key_name: $!";

my $node = PostgreSQL::Test::Cluster->new('vectorizer_api_key_tilde');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
pgedge_vectorizer.provider = 'openai'
));

# The postmaster inherits HOME here and backends fork from it, so this is what
# the unfixed getenv("HOME") would have read.
{
	local $ENV{HOME} = $fake_home;
	$node->start;
}

$node->safe_psql('postgres', "CREATE DATABASE $dbname");
$node->safe_psql($dbname, 'CREATE EXTENSION vector');
$node->safe_psql($dbname, 'CREATE EXTENSION pgedge_vectorizer');

# Control: confirm the planted HOME really did reach the backend. Without this
# the main assertion below would also pass on an unfixed build that simply never
# saw the variable. COPY FROM PROGRAM runs with the backend's environment.
my $backend_home = $node->safe_psql(
	$dbname, q(
CREATE TEMP TABLE env_probe(v text);
COPY env_probe FROM PROGRAM 'printf "%s" "$HOME"';
SELECT v FROM env_probe;
));
is($backend_home, $fake_home, 'the planted HOME reached the backend');

# The actual test: `~` must ignore that HOME.
my ($stdout, $stderr, $timed_out);
$node->psql(
	$dbname,
	"SET pgedge_vectorizer.provider = 'openai';\n"
	  . "SET pgedge_vectorizer.api_key_file = '~/$key_name';\n"
	  . "SELECT pgedge_vectorizer.generate_embedding('test');",
	stdout => \$stdout,
	stderr => \$stderr,
	timeout => $PostgreSQL::Test::Utils::timeout_default,
	timed_out => \$timed_out);

ok(!$timed_out, 'tilde expansion answered rather than waited');

# Resolved through the passwd entry: the key file is absent there, and the
# reported path names the real home rather than the planted one.
like(
	$stderr,
	qr/API key file not found: \Q$real_home\E\/\Q$key_name\E/,
	'`~` expanded to the passwd home directory');

# Secondary guard: the planted directory must not appear in the message either.
unlike($stderr, qr/\Q$fake_home\E/,
	'`~` did not expand to the directory HOME named');

# The independent check, and the one that speaks to the consequence: reaching
# the provider at all means a key was found and sent. An unfixed build gets an
# authentication failure back from the planted key here, which is how the
# original report surfaced; a fixed build never leaves the key-loading step.
unlike($stderr, qr/API returned HTTP|Incorrect API key/,
	'the planted key was never sent to the provider');

done_testing();

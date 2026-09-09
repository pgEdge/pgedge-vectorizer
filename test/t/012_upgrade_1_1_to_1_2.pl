# Copyright (c) 2025 - 2026, pgEdge, Inc.
#
# Verify that an installation created at 1.1 upgrades to 1.2 and ends up with
# the same objects a fresh 1.2 install has.
#
# pg_regress cannot check this. Its database installs whatever the control
# file's default_version says, so every regression test only ever exercises a
# fresh install, and the upgrade script goes untested however wrong it is. That
# is not hypothetical: adding a defaulted parameter to enable_vectorization()
# with CREATE OR REPLACE defined a second function rather than replacing the
# old one, leaving two overloads behind, an eight-argument call reaching a body
# that knew nothing of the registry's new columns, and COMMENT ON FUNCTION
# failing outright as ambiguous. A fresh install was perfect throughout.
#
# The comparison below is deliberately structural rather than a list of names
# to keep in step: whatever a fresh 1.2 install has, an upgraded one must have
# too.

use strict;
use warnings;

# See the comment in 001_worker_coverage.pl about loading these at compile time.
use PostgreSQL::Test::Cluster;
use PostgreSQL::Test::Utils;
use Test::More;

my $node = PostgreSQL::Test::Cluster->new('vectorizer_upgrade');
$node->init;
$node->append_conf(
	'postgresql.conf', qq(
shared_preload_libraries = 'pgedge_vectorizer'
max_worker_processes = 16
));
$node->start;

# No databases are named, so no worker ever runs against either of these and
# nothing tries to reach a provider.
for my $db ('upgraded', 'fresh')
{
	$node->safe_psql('postgres', "CREATE DATABASE $db");
	$node->safe_psql($db, 'CREATE EXTENSION vector');
}

$node->safe_psql('upgraded',
	"CREATE EXTENSION pgedge_vectorizer VERSION '1.1'");

is($node->safe_psql('upgraded',
		"SELECT extversion FROM pg_extension WHERE extname = 'pgedge_vectorizer'"),
	'1.1', 'the extension installs at 1.1');

# Real state before the upgrade, so the script runs against a populated
# registry and a chunk table rather than an empty schema.
$node->safe_psql('upgraded', q(
CREATE TABLE docs (id BIGSERIAL PRIMARY KEY, body TEXT);
INSERT INTO docs (body) VALUES ('Written while the extension was at 1.1.');
));
$node->safe_psql('upgraded',
	q(SELECT pgedge_vectorizer.enable_vectorization('docs', 'body',
													'token_based', 100, 10, 1536)));

$node->safe_psql('upgraded',
	"ALTER EXTENSION pgedge_vectorizer UPDATE TO '1.2'");

is($node->safe_psql('upgraded',
		"SELECT extversion FROM pg_extension WHERE extname = 'pgedge_vectorizer'"),
	'1.2', 'the extension upgrades to 1.2');

$node->safe_psql('fresh', 'CREATE EXTENSION pgedge_vectorizer');

is($node->safe_psql('fresh',
		"SELECT extversion FROM pg_extension WHERE extname = 'pgedge_vectorizer'"),
	'1.2', 'a fresh install is 1.2, so the two are comparable');

# Every function, by name and argument list. An overload left behind by a
# CREATE OR REPLACE that should have been a DROP shows up here as an extra row.
my $signatures = q(
	SELECT string_agg(p.proname || '(' || pg_get_function_arguments(p.oid) || ')',
					  E'\n' ORDER BY p.proname, pg_get_function_arguments(p.oid))
	  FROM pg_proc p
	 WHERE p.pronamespace = 'pgedge_vectorizer'::regnamespace
);

is($node->safe_psql('upgraded', $signatures),
	$node->safe_psql('fresh', $signatures),
	'an upgraded install has exactly the functions a fresh one has');

# Columns of the extension's own tables, so a missed ALTER TABLE is caught.
my $columns = q(
	SELECT string_agg(c.relname || '.' || a.attname || ' ' ||
					  format_type(a.atttypid, a.atttypmod),
					  E'\n' ORDER BY c.relname, a.attname)
	  FROM pg_class c
	  JOIN pg_attribute a ON a.attrelid = c.oid
	 WHERE c.relnamespace = 'pgedge_vectorizer'::regnamespace
	   AND c.relkind = 'r'
	   AND a.attnum > 0
	   AND NOT a.attisdropped
);

is($node->safe_psql('upgraded', $columns),
	$node->safe_psql('fresh', $columns),
	'an upgraded install has the same table columns as a fresh one');

# Views too, since those are replaced rather than altered.
my $views = q(
	SELECT string_agg(c.relname, E'\n' ORDER BY c.relname)
	  FROM pg_class c
	 WHERE c.relnamespace = 'pgedge_vectorizer'::regnamespace
	   AND c.relkind = 'v'
);

is($node->safe_psql('upgraded', $views),
	$node->safe_psql('fresh', $views),
	'an upgraded install has the same views as a fresh one');

# Chunk tables too, which is a separate trap: enable_vectorization() adds
# columns to a chunk table it finds without them, but nothing re-runs it on
# upgrade, so anything the worker writes has to be added by the upgrade script
# itself. Compare a chunk table created at 1.1 and upgraded against one created
# fresh at 1.2.
$node->safe_psql('fresh', q(
CREATE TABLE docs (id BIGSERIAL PRIMARY KEY, body TEXT);
INSERT INTO docs (body) VALUES ('Written on a fresh 1.2 install.');
));
$node->safe_psql('fresh',
	q(SELECT pgedge_vectorizer.enable_vectorization('docs', 'body',
													'token_based', 100, 10, 1536)));

my $chunk_columns = q(
	SELECT string_agg(a.attname || ' ' || format_type(a.atttypid, a.atttypmod),
					  E'\n' ORDER BY a.attname)
	  FROM pg_attribute a
	 WHERE a.attrelid = 'docs_body_chunks'::regclass
	   AND a.attnum > 0
	   AND NOT a.attisdropped
);

is($node->safe_psql('upgraded', $chunk_columns),
	$node->safe_psql('fresh', $chunk_columns),
	'an upgraded chunk table has the same columns as a freshly created one');

# The data that was there before the upgrade is still there, and the new
# columns default to inheriting.
is($node->safe_psql('upgraded',
		q(SELECT source_table || ' ' || COALESCE(provider, 'NULL') || ' ' ||
				 COALESCE(model, 'NULL')
			FROM pgedge_vectorizer.vectorizers)),
	'docs NULL NULL',
	'a vectorizer registered before the upgrade survives it, inheriting');

is($node->safe_psql('upgraded', 'SELECT count(*) FROM docs_body_chunks'),
	'1', 'the chunks written before the upgrade survive it');

$node->stop;

done_testing();

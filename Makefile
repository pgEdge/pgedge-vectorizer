# pgedge_vectorizer PostgreSQL Extension Makefile
# Supports PostgreSQL 14-17

EXTENSION = pgedge_vectorizer
EXTVERSION = 1.1

# Extension module and data files
MODULE_big = $(EXTENSION)
OBJS = src/pgedge_vectorizer.o \
       src/guc.o \
       src/bm25.o \
       src/chunking.o \
       src/hybrid_chunking.o \
       src/tokenizer.o \
       src/provider.o \
       src/provider_common.o \
       src/provider_openai.o \
       src/provider_voyage.o \
       src/provider_ollama.o \
       src/provider_gemini.o \
       src/worker.o \
       src/queue.o \
       src/embed.o

DATA = sql/$(EXTENSION)--$(EXTVERSION).sql \
       sql/$(EXTENSION)--1.0.sql \
       sql/$(EXTENSION)--1.0--1.1.sql \
       sql/$(EXTENSION)--1.0-beta2.sql \
       sql/$(EXTENSION)--1.0-beta3.sql \
       sql/$(EXTENSION)--1.0-beta1--1.0-beta2.sql \
       sql/$(EXTENSION)--1.0-beta2--1.0-beta3.sql \
       sql/$(EXTENSION)--1.0-beta3--1.0.sql

# Test configuration for pg_regress
REGRESS = setup chunking hybrid_chunking queue delete_truncate delete_truncate_pk pk_type_session max_retries vectorization multi_column maintenance edge_cases providers worker cleanup embedding pk_types stale_embeddings hybrid_test
REGRESS_OPTS = --inputdir=test --outputdir=test

# Documentation files (if any)
# DOCS = README.md

# Compiler and linker flags
PG_CPPFLAGS = -I$(srcdir)/src
SHLIB_LINK = -lcurl -lm

# For systems with libcurl in non-standard locations
# Uncomment and adjust if needed:
# PG_CPPFLAGS += -I/usr/local/include
# SHLIB_LINK += -L/usr/local/lib

# Check for required PostgreSQL version (14+)
# This will be evaluated at build time
PG_MIN_VERSION = 140000

# Use PGXS for building
PG_CONFIG ?= pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)

# Check if pg_config is available
ifeq ($(PGXS),)
$(error pg_config not found. Please install PostgreSQL development packages or set PG_CONFIG)
endif

# TAP tests
#
# Multi-database worker coverage cannot be expressed in pg_regress, which runs
# against a single database and cannot set shared_preload_libraries, so those
# properties are tested with TAP instead.
#
# Only enable them when this installation can actually run them, so that an
# environment lacking the plumbing simply does not run them rather than failing
# the whole suite. Two things are needed:
#
#   - The PostgreSQL Perl test modules. Homebrew builds on macOS do not ship
#     these at all.
#   - IPC::Run, which PostgreSQL::Test::Cluster requires at compile time. It is
#     a separate package (libipc-run-perl on Debian and Ubuntu) and is not
#     pulled in by the server development package, so the modules being present
#     does not imply it is.
#
# CI installs IPC::Run explicitly so that these tests really do run there; a
# silent skip everywhere would be worse than useless, because it would look like
# the coverage property was being verified when it was not.
PG_PERL_TEST_DIR := $(dir $(PGXS))../../src/test/perl
ifneq ($(wildcard $(PG_PERL_TEST_DIR)/PostgreSQL/Test/Cluster.pm),)
ifeq ($(shell perl -MIPC::Run -e 'print "yes"' 2>/dev/null),yes)
TAP_TESTS = 1
PROVE_TESTS = test/t/*.pl
endif
endif

include $(PGXS)

# Version compatibility check
# Extract only the leading major version integer. This must cope with
# pre-release strings such as "PostgreSQL 19beta1 (Ubuntu 19~beta1-1.noble)"
# where there is no MAJOR.MINOR dot; a dotted regex would leave the whole
# descriptive string (including the "(...)" suffix) in place and break the
# shell test below under dash (/bin/sh on Debian/Ubuntu).
pg_version_num := $(shell $(PG_CONFIG) --version | sed -E 's/^PostgreSQL ([0-9]+).*/\1/')

# Ensure we're building for PostgreSQL 14+
check-pg-version:
	@echo "Building for PostgreSQL version: $(shell $(PG_CONFIG) --version)"
	@if [ "$(pg_version_num)" -lt 14 ]; then \
		echo "Error: PostgreSQL 14 or later is required"; \
		exit 1; \
	fi

# Make sure version check runs before build
all: check-pg-version

# Installation verification
installcheck: check-pg-version

# Custom targets
.PHONY: check-pg-version

# Help target
help:
	@echo "pgedge_vectorizer - PostgreSQL Vectorization Extension"
	@echo ""
	@echo "Targets:"
	@echo "  all          - Build the extension (requires PostgreSQL 14+)"
	@echo "  install      - Install the extension"
	@echo "  installcheck - Run tests against installed extension"
	@echo "  clean        - Remove build artifacts"
	@echo ""
	@echo "Requirements:"
	@echo "  - PostgreSQL 14 or later"
	@echo "  - pgvector extension installed"
	@echo "  - libcurl development files"
	@echo ""
	@echo "Configuration:"
	@echo "  PG_CONFIG    - Path to pg_config (default: pg_config in PATH)"

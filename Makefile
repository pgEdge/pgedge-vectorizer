# pgedge_vectorizer PostgreSQL Extension Makefile
# Supports PostgreSQL 14-17

EXTENSION = pgedge_vectorizer
EXTVERSION = 1.0-alpha1

# Extension module and data files
MODULE_big = $(EXTENSION)
OBJS = src/pgedge_vectorizer.o \
       src/guc.o \
       src/chunking.o \
       src/tokenizer.o \
       src/provider.o \
       src/provider_openai.o \
       src/provider_voyage.o \
       src/provider_ollama.o \
       src/worker.o \
       src/queue.o \
       src/embed.o

DATA = sql/$(EXTENSION)--$(EXTVERSION).sql

# Test configuration for pg_regress
REGRESS = setup chunking queue vectorization multi_column maintenance edge_cases providers worker cleanup
REGRESS_OPTS = --inputdir=test --outputdir=test

# Documentation files (if any)
# DOCS = README.md

# Compiler and linker flags
PG_CPPFLAGS = -I$(srcdir)/src
SHLIB_LINK = -lcurl

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

include $(PGXS)

# Version compatibility check
pg_version_num := $(shell $(PG_CONFIG) --version | sed 's/^PostgreSQL *//' | \
	sed 's/\([0-9]*\)\.\([0-9]*\).*/\1\2/')

# Ensure we're building for PostgreSQL 14+
check-pg-version:
	@echo "Building for PostgreSQL version: $(shell $(PG_CONFIG) --version)"
	@if [ $(pg_version_num) -lt 14 ]; then \
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

# Testing

## Running Tests

The extension includes a comprehensive test suite using PostgreSQL's pg_regress framework:

```bash
# Build and install the extension first
make
make install

# Run all tests
make installcheck
```

## Test Coverage

The test suite includes 9 test files covering all functionality:

1. **setup** - Extension installation and configuration
2. **chunking** - Text chunking with various content sizes
3. **queue** - Queue table and monitoring views
4. **vectorization** - Basic enable/disable functionality
5. **multi_column** - Multiple columns on the same table
6. **maintenance** - reprocess_chunks() and recreate_chunks() functions
7. **edge_cases** - Empty, NULL, and whitespace handling
8. **worker** - Background worker configuration
9. **cleanup** - Queue cleanup functions

## Test Requirements

- PostgreSQL 14+ (tests run on installed version)
- `vector` extension must be installed
- Extension must be built and installed before running tests

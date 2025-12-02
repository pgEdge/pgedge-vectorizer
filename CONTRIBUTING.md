# Contributing to pgEdge Vectorizer

Thank you for your interest in contributing to pgEdge Vectorizer! This document provides guidelines and instructions for contributing.

## Development Setup

### Prerequisites

- PostgreSQL 14 or later (14, 15, 16, 17, or 18)
- pgvector extension
- libcurl development files
- Git
- Make

### Setting Up Development Environment

1. **Clone the repository**
   ```bash
   git clone https://github.com/pgEdge/pgedge-vectorizer.git
   cd pgedge-vectorizer
   ```

2. **Install dependencies**

   **Ubuntu/Debian:**
   ```bash
   sudo apt-get install postgresql-server-dev-all libcurl4-openssl-dev
   ```

   **macOS:**
   ```bash
   brew install postgresql curl
   ```

3. **Install pgvector**
   ```bash
   git clone https://github.com/pgvector/pgvector.git
   cd pgvector
   make
   sudo make install
   ```

4. **Build the extension**
   ```bash
   make
   sudo make install
   ```

5. **Run tests**
   ```bash
   make installcheck
   ```

## Making Changes

### Workflow

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/my-feature`)
3. Make your changes
4. Add tests for new functionality
5. Ensure all tests pass (`make installcheck`)
6. Commit your changes with clear commit messages
7. Push to your fork
8. Create a Pull Request

### Code Style

- **C Code**: Follow PostgreSQL coding conventions
  - Use tabs for indentation (not spaces)
  - Keep lines under 80 characters where reasonable
  - Use PostgreSQL's error reporting macros (`elog`, `ereport`)
  - Add comments for non-obvious code

- **SQL Code**:
  - Use spaces for indentation (not tabs)
  - Use uppercase for SQL keywords
  - Add comments for complex queries

- **Commit Messages**:
  - Use clear, descriptive commit messages
  - Start with a verb in imperative mood (e.g., "Add", "Fix", "Update")
  - Reference issue numbers when applicable

### Testing Requirements

All contributions must include tests and pass the full test suite:

```bash
make installcheck
```

#### Test Coverage

Tests should cover:
- New functionality
- Edge cases
- Error handling
- Integration with existing features

#### Adding New Tests

1. Create a new test file in `test/sql/` or add to existing file
2. Run the test to generate output: `make installcheck`
3. Review the output in `test/results/`
4. If correct, copy to `test/expected/`: `cp test/results/mytest.out test/expected/mytest.out`
5. Add test to `REGRESS` in Makefile if it's a new file

### Continuous Integration

All pull requests must pass CI checks on:
- PostgreSQL 14, 15, 16, 17, and 18 (Ubuntu)
- PostgreSQL 17 (macOS)
- Code quality checks (no trailing whitespace, etc.)

CI runs automatically on all pull requests. Check the status at the bottom of your PR.

## Submitting Pull Requests

### Before Submitting

- [ ] All tests pass locally (`make installcheck`)
- [ ] Code follows style guidelines
- [ ] New functionality includes tests
- [ ] Documentation is updated (README.md, docs/index.md)
- [ ] Commit messages are clear and descriptive
- [ ] No trailing whitespace or tabs in SQL files
- [ ] Build completes without warnings

### Pull Request Process

1. **Create PR** with a clear title and description
2. **Reference issues** if fixing a bug or implementing a feature request
3. **Respond to reviews** promptly and make requested changes
4. **Squash commits** if requested before merging
5. **Wait for CI** - all checks must pass before merge

### PR Description Template

```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
Describe testing performed

## Checklist
- [ ] Tests pass locally
- [ ] Documentation updated
- [ ] No trailing whitespace
- [ ] Commit messages are clear
```

## Reporting Issues

### Bug Reports

Include:
- PostgreSQL version
- pgEdge Vectorizer version
- Steps to reproduce
- Expected vs actual behavior
- Error messages and logs
- Configuration settings (redact sensitive data)

### Feature Requests

Include:
- Use case description
- Proposed solution
- Alternative solutions considered
- Impact on existing functionality

## Getting Help

- **GitHub**: https://github.com/pgEdge/pgedge-vectorizer
- **Issues**: https://github.com/pgEdge/pgedge-vectorizer/issues
- **Documentation**: https://github.com/pgEdge/pgedge-vectorizer/blob/main/docs/index.md

## License

By contributing to pgEdge Vectorizer, you agree that your contributions will be licensed under the PostgreSQL License.

## Code of Conduct

- Be respectful and inclusive
- Provide constructive feedback
- Focus on what is best for the community
- Show empathy towards other community members

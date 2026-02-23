# Contributing to Just Database

Thank you for taking the time to contribute! Every bug report, feature
suggestion, documentation fix, and code improvement makes **just_database**
better for the entire Flutter community.

Please read this guide before opening issues or submitting pull requests.

---

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [Reporting Bugs](#reporting-bugs)
- [Suggesting Features](#suggesting-features)
- [Development Setup](#development-setup)
- [Project Structure](#project-structure)
- [Making Changes](#making-changes)
- [Commit Messages](#commit-messages)
- [Code Style](#code-style)
- [Testing](#testing)
- [Pull Request Checklist](#pull-request-checklist)
- [Versioning](#versioning)
- [License](#license)

---

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md).
By participating you agree to uphold it. Please report unacceptable behaviour to
the maintainers via GitHub issues.

---

## Reporting Bugs

Before filing a bug please:

1. Check [existing issues](https://github.com/just-unknown-dev/just-database/issues)
   to avoid duplicates.
2. Reproduce the problem on the **latest** published version.

When opening an issue, include:

| Field | What to include |
|---|---|
| **Package version** | e.g. `1.0.0` |
| **Flutter / Dart version** | Output of `flutter --version` |
| **Platform** | Android / iOS / Web / Windows / macOS / Linux |
| **Minimal reproduction** | The smallest possible code that shows the bug |
| **Expected behaviour** | What you expected to happen |
| **Actual behaviour** | What actually happened (stack trace, screenshots) |

---

## Suggesting Features

Open a [GitHub Discussion](https://github.com/just-unknown-dev/just-database/discussions)
or an issue labelled **enhancement**. Describe:

- The problem you are trying to solve.
- Your proposed API / behaviour.
- Any alternatives you considered.

---

## Development Setup

### Prerequisites

| Tool | Recommended version |
|---|---|
| Flutter SDK | ≥ 3.0.0 |
| Dart SDK | ≥ 3.11.0 |
| Git | any recent version |

### Clone and bootstrap

```bash
git clone https://github.com/just-unknown-dev/just-database.git
cd just-database

# Install dependencies for the library
flutter pub get

# Install dependencies for the admin demo app  (optional)
cd ../../   # repo root / just_database_admin
flutter pub get
```

### Run the demo app

```bash
cd just_database_admin
flutter run
```

### Run the tests

```bash
cd packages/just_database
flutter test
```

---

## Project Structure

```
packages/just_database/
  lib/
    just_database.dart          # Public barrel export
    src/
      benchmark/                # DatabaseBenchmark, BenchmarkSuite, QueryStats
      concurrency/              # Mutex, ReadWriteLock
      core/                     # Database, DatabaseMode, SecureKeyManager, backup, migrations
      orm/                      # DbTable, DbRecord, DbColumn
      sql/                      # Lexer, parser, executor, query planner
      storage/                  # DatabaseRow, Table, Index, persistence
      ui/                       # Admin UI (DatabaseProvider, tabs, pages)
      widgets/                  # Reusable Flutter widgets
  test/                         # Unit & widget tests
  example/                      # Standalone runnable example
  CHANGELOG.md
  README.md
  DOCS.md
  API.md
  MIGRATION.md
```

---

## Making Changes

1. **Fork** the repository and create a branch off `main`:

   ```bash
   git checkout -b fix/describe-your-change
   # or
   git checkout -b feat/describe-your-feature
   ```

2. Make your changes in small, focused commits (see [Commit Messages](#commit-messages)).

3. Add or update **tests** for any behaviour you change.

4. Run `flutter analyze` and `flutter test` — both must pass with zero errors.

5. Update **CHANGELOG.md** under the `Unreleased` heading.

6. Open a pull request against `main`. Fill in the PR template completely.

### Branch naming conventions

| Prefix | Use for |
|---|---|
| `feat/` | New features |
| `fix/` | Bug fixes |
| `docs/` | Documentation-only changes |
| `refactor/` | Code restructuring without behaviour change |
| `test/` | Adding or updating tests |
| `chore/` | Tooling, CI, dependency updates |

---

## Commit Messages

Follow the [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>(<scope>): <short summary>

[optional body]

[optional footer]
```

**Examples:**

```
feat(orm): add support for composite primary keys
fix(sql): handle NULL in GROUP BY aggregations
docs(readme): add secure-mode migration guide
test(storage): cover edge case in index rebuild
```

- Use the **imperative mood** in the summary ("add", not "added" / "adds").
- Keep the summary line under **72 characters**.
- Reference related issues in the footer: `Closes #42`.

---

## Code Style

- Format all Dart files with `dart format .` before committing.
- Follow the rules in [analysis_options.yaml](analysis_options.yaml).  
  Run `flutter analyze` — **zero warnings and errors**.
- Prefer explicit types over `var`/`dynamic` in public APIs.
- Document all public symbols with `///` doc comments.
- Keep classes focused; avoid large files.

---

## Testing

| Test type | Location | Command |
|---|---|---|
| Unit tests | `test/` | `flutter test` |
| Integration / demo | `example/` | `flutter run` (manual) |

Guidelines:

- Every public API change must be accompanied by tests.
- Use descriptive test group / test names:  
  `group('Executor', () { test('returns empty list for empty table', ...) })`.
- Avoid relying on real file I/O in unit tests — use the in-memory path
  provider (`PathProviderPlatform.instance = FakePathProviderPlatform()`).
- Target ≥ 80 % line coverage for new code.

---

## Pull Request Checklist

Before requesting a review, confirm all items below:

- [ ] `flutter analyze` passes with zero issues
- [ ] `flutter test` passes with all tests green
- [ ] New behaviour is covered by tests
- [ ] Public API changes are documented with `///` comments
- [ ] `CHANGELOG.md` updated under `Unreleased`
- [ ] README / DOCS updated if the public API or behaviour changed
- [ ] Branch is rebased (or merged) on top of the latest `main`

---

## Versioning

This package follows [Semantic Versioning](https://semver.org/):

| Change type | Version bump |
|---|---|
| Breaking public API change | MAJOR (`X.0.0`) |
| New backwards-compatible feature | MINOR (`0.X.0`) |
| Bug fix, internal refactor | PATCH (`0.0.X`) |

Only maintainers publish releases. If your PR warrants a version bump, note
the suggested kind in the PR description.

---

## License

By contributing to just_database you agree that your contributions will be
licensed under the [BSD 3-Clause License](LICENSE) that covers this project.

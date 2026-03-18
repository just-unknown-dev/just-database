# Just Database — Architecture

> Version 1.2.0 · Last updated 2026-03-14

---

## Table of Contents

1. [Overview](#overview)
2. [Layer Map](#layer-map)
3. [Source Tree](#source-tree)
4. [Layer Details](#layer-details)
   - [Public API Surface](#public-api-surface)
   - [SQL Pipeline](#sql-pipeline)
   - [Storage Engine](#storage-engine)
   - [Core Layer](#core-layer)
   - [Concurrency Layer](#concurrency-layer)
   - [ORM Layer](#orm-layer)
   - [Persistence Layer](#persistence-layer)
   - [Benchmark Layer](#benchmark-layer)
   - [UI / Admin Layer](#ui--admin-layer)
5. [Data Flow](#data-flow)
6. [Concurrency Model](#concurrency-model)
7. [Persistence & Encryption](#persistence--encryption)
8. [Platform Portability](#platform-portability)
9. [Index Strategy](#index-strategy)
10. [Spatial Support](#spatial-support)
11. [Transaction Model](#transaction-model)
12. [Migration System](#migration-system)
13. [Dependency Graph](#dependency-graph)

---

## Overview

`just_database` is a **pure-Dart, in-memory relational database engine** built for Flutter. It implements a full SQL dialect — DDL, DML, JOINs, aggregates, views, triggers, transactions, and spatial queries — entirely in Dart without any native plugins or FFI. Optional JSON-serialised persistence is provided via `path_provider` on native platforms and browser `localStorage`/`sessionStorage` on web/WASM through `just_storage`.

Key design decisions:

| Decision | Rationale |
|---|---|
| In-memory row store | Zero native dependencies; works on all Flutter targets |
| Handwritten Lexer/Parser | Full control over the SQL dialect; no codegen needed |
| Pluggable `LockManager` | One concurrency strategy per `DatabaseMode` |
| Conditional export for persistence | `dart.library.js_interop` guard routes to web stubs |
| `ChangeNotifier` admin UI | Drop-in Flutter widget with zero routing changes |

---

## Layer Map

```
┌──────────────────────────────────────────────────────────────────────────┐
│                         Public API (just_database.dart)                  │
├───────────────┬──────────────────────┬──────────────┬────────────────────┤
│   Core        │   SQL Pipeline       │   ORM        │   Admin UI         │
│  ─────────    │  ──────────────      │  ─────────   │  ───────────────── │
│  JustDatabase │  Lexer               │  DbTable<T>  │  DatabaseProvider  │
│  DatabaseMgr  │  Parser              │  DbRecord    │  AdminWidget       │
│  BackupMgr    │  AST (nodes)         │  DbColumn    │  Tabs / Pages      │
│  Migration    │  Executor            │              │                    │
│  SecureKeyMgr │                      │              │                    │
├───────────────┴──────────────────────┴──────────────┴────────────────────┤
│                         Storage Engine                                   │
│          Table · TableSchema · DatabaseRow · TableIndex · RTree          │
│                  QueryTracker · SpatialTypes (Point, BBox)               │
├──────────────────────────────────────────────────────────────────────────┤
│                      Concurrency Layer                                   │
│             LockManager (Standard | ReadFast | WriteFast)                │
├──────────────────────────────────────────────────────────────────────────┤
│                       Persistence Layer                                  │
│       PersistenceManager (native: dart:io + encrypt) / (web: no-op)      │
│                  BackupManager (native) / (web stubs)                    │
│                       SecureKeyManager (just_storage)                    │
└──────────────────────────────────────────────────────────────────────────┘
```

---

## Source Tree

```
lib/
├── just_database.dart         ← core barrel export
├── ui.dart                    ← UI barrel export
└── src/
    ├── version.dart
    ├── sql/
    │   ├── lexer.dart         ← tokeniser
    │   ├── ast.dart           ← token enum + AST node types
    │   ├── parser.dart        ← recursive-descent parser
    │   └── executor.dart      ← AST interpreter + QueryResult
    ├── storage/
    │   ├── schema.dart        ← DataType, ColumnDef, TableSchema
    │   ├── table.dart         ← Table (row store + index manager)
    │   ├── database_row.dart  ← DatabaseRow value type
    │   ├── index.dart         ← TableIndex (hash buckets), IndexMetadata
    │   ├── query_tracker.dart ← usage counters for auto-indexing
    │   ├── spatial.dart       ← Point, BoundingBox, Polygon, Circle
    │   ├── rtree.dart         ← R-tree spatial index
    │   ├── persistence.dart           ← conditional export gateway
    │   ├── persistence_native.dart    ← dart:io + encrypt implementation
    │   └── persistence_web.dart       ← no-op web/WASM stubs
    ├── core/
    │   ├── database_mode.dart         ← DatabaseMode enum
    │   ├── database.dart              ← JustDatabase + QueryBuilder
    │   ├── database_manager.dart      ← DatabaseManager + DatabaseInfo
    │   ├── migration.dart             ← Migration, SqlMigration, MigrationRunner
    │   ├── secure_key_manager.dart    ← AES key lifecycle via just_storage
    │   ├── backup.dart                ← conditional export gateway
    │   ├── backup_native.dart         ← full BackupManager implementation
    │   └── backup_web.dart            ← partial stubs + in-memory methods
    ├── concurrency/
    │   └── lock_manager.dart          ← abstract + Standard/ReadFast/WriteFast
    ├── orm/
    │   └── db_table.dart              ← DbTable<T>, DbRecord, DbColumn
    ├── benchmark/
    │   └── benchmark.dart             ← BenchmarkRunner, QueryStats
    ├── widgets/
    │   └── admin_widget.dart          ← JustDatabaseAdminWidget
    └── ui/
        ├── database_provider.dart     ← ChangeNotifier state manager
        ├── ju_database_admin_screen.dart
        ├── tabs/
        │   ├── databases_tab.dart
        │   ├── query_editor_tab.dart
        │   ├── schema_tab.dart
        │   └── settings_tab.dart
        └── pages/
            ├── benchmark_page.dart
            └── insert_page.dart
```

---

## Layer Details

### Public API Surface

Two barrel files expose different concerns:

- **`just_database.dart`** — exports every non-UI type: `JustDatabase`, `DatabaseManager`, `DatabaseMode`, `QueryResult`, `BackupManager`, `Migration`, `SecureKeyManager`, `Table`, `TableSchema`, `TableIndex`, `Executor`, `Parser`, all AST nodes, `LockManager`, `BenchmarkRunner`, `DbTable`, `DbRecord`, `DbColumn`, `PersistenceManager`, spatial types, and version info.
- **`ui.dart`** — exports the admin UI surface: `DatabaseProvider`, `JustDatabaseAdminWidget`, and the admin screen.

---

### SQL Pipeline

The SQL engine consists of four sequential stages.

#### 1. Lexer (`lexer.dart`)

A single-pass character scanner that converts a raw SQL string into a flat `List<Token>`. Each token carries a `TokenType` (e.g. `kwSelect`, `opEquals`, `integer`, `string`) and its literal string value. The lexer handles:

- SQL keywords (DDL, DML, aggregate functions, data types, constraint keywords)
- String literals with single-quote escaping
- Numeric literals (integer and real)
- Operators and punctuation
- SQL comments (`--` single-line)
- Identifier quoting with backticks and double-quotes

#### 2. AST (`ast.dart`)

A hierarchy of plain Dart classes representing every statement type. Each node carries exactly the fields needed by the executor — nothing more. Key node families:

| Family | Nodes |
|---|---|
| DML | `SelectStatement`, `InsertStatement`, `UpdateStatement`, `DeleteStatement` |
| DDL | `CreateTableStatement`, `DropTableStatement`, `AlterTableStatement` |
| Index | `CreateIndexStatement`, `DropIndexStatement` |
| View | `CreateViewStatement`, `DropViewStatement` |
| Trigger | `CreateTriggerStatement`, `DropTriggerStatement` |
| Transaction | `BeginStatement`, `CommitStatement`, `RollbackStatement`, `SavepointStatement`, `ReleaseStatement` |
| Expression | `BinaryExpression`, `UnaryExpression`, `FunctionCall`, `ColumnRef`, `Literal`, `CaseExpression`, `SubqueryExpression` |

#### 3. Parser (`parser.dart`)

A recursive-descent parser that consumes the token list produced by the Lexer and returns a single `Statement` (or a list of statements for multi-statement input via `Parser.parseSQLStatements`). It throws `ParseException` on syntax errors.

Notable capabilities:

- `SELECT` with aliases, DISTINCT, all JOIN types (INNER, LEFT, RIGHT), GROUP BY, HAVING, ORDER BY, LIMIT / OFFSET, subqueries
- `INSERT` with column list, `VALUES`, multi-row values, and `INSERT OR REPLACE`
- `UPDATE` / `DELETE` with `WHERE` and sub-expressions
- `CREATE TABLE` with all constraint types (PK, FK, UNIQUE, NOT NULL, DEFAULT, AUTOINCREMENT), table-level constraints
- `ALTER TABLE` (ADD COLUMN, DROP COLUMN, RENAME COLUMN, RENAME TO)
- Views, triggers (BEFORE/AFTER, INSERT/UPDATE/DELETE, `FOR EACH ROW`)
- Named savepoints
- Query optimisation hints: `/*+ INDEX(table col) */` and `/*+ COMPOSITE_INDEX(table col1 col2) */`

#### 4. Executor (`executor.dart`)

An AST interpreter that mutates the shared `Map<String, Table>` owned by `JustDatabase`. Every `execute(Statement)` call dispatches to a private handler method (`_executeSelect`, `_executeInsert`, etc.).

The executor also owns:

- **Transaction / WAL state** — a snapshot of all tables taken at `BEGIN`; rolled back atomically on `ROLLBACK`. Named savepoints are additional snapshots within a transaction.
- **View store** — `Map<String, SelectStatement>` mapping view name to its stored query. Views are resolved transparently during `SELECT`.
- **Trigger store** — `Map<String, List<CreateTriggerStatement>>` per table. Triggers fire before or after the DML statement, with `NEW`/`OLD` row context exposed to the trigger body.
- **`QueryTracker`** — receives column-usage events during `WHERE` evaluation and can request automatic index creation after a threshold is reached.

---

### Storage Engine

#### `Table`

The central mutable data structure. Each `Table` holds:

- `TableSchema` — column definitions, constraints, primary key columns
- `List<DatabaseRow>` — ordered row list
- `Map<int, int> _rowIdToIndex` — O(1) rowId → list position lookup
- `Map<String, TableIndex> _indices` — named hash indexes (auto-created for PK, UNIQUE, FK, and auto-index candidates)
- `int _nextRowId` / `int _autoIncrementValue` — internal counters

On construction, `Table` auto-creates indexes for every PK, UNIQUE, and FK column defined in the schema.

#### `DatabaseRow`

An immutable value type wrapping `Map<String, dynamic>`. Carries the internal `rowId`, the column map, and an optional spatial `BoundingBox` for geometry columns.

#### `TableSchema`

Carries the list of `ColumnDefinition` objects (name, `DataType`, `ConstraintDefinition`) and the list of table-level constraints (`TableConstraint` for composite PK / UNIQUE / FK).

#### `TableIndex`

A hash-bucket index mapping column values (or composite key tuples for multi-column indexes) to `List<int>` row IDs. Supports insert, update, and delete maintenance, plus range and equality lookup. Carries `IndexMetadata` (type, usage count, creation time, last-used time).

`IndexType` values: `primary`, `unique`, `foreign`, `auto`, `spatial`, `manual`.

#### `QueryTracker`

Observes WHERE-clause column usage across every SELECT. When a single column or multi-column combination exceeds `autoIndexThreshold` (default 100), the tracker signals the executor to create an `auto`-type index. Already-indexed columns are tracked to avoid duplicates.

---

### Core Layer

#### `JustDatabase`

The entry point for all database operations. Created via `JustDatabase.open(name, ...)`.

Public methods:

| Method | Description |
|---|---|
| `query(sql)` | Executes SELECT; acquires read lock |
| `execute(sql)` | Executes DDL/DML; acquires write lock |
| `from(table)` | Returns a `QueryBuilder` for fluent API |
| `beginTransaction()` / `commit()` / `rollback()` | Transaction management |
| `savepoint(name)` / `release(name)` / `rollbackTo(name)` | Savepoint management |
| `close()` | Persists to disk (if `persist: true`) and releases resources |

`JustDatabase` owns a `LockManager`, a `QueryTracker`, and an `Executor`. The `_tables` map is shared by reference between `JustDatabase` and `Executor`.

#### `QueryBuilder`

A fluent builder that accumulates `SELECT`, `WHERE`, `ORDER BY`, `LIMIT`, and `OFFSET` clauses and renders them to a SQL string before delegating to `JustDatabase.query` or `execute`. It also exposes `.insert()`, `.update()`, and `.delete()` for DML via the same fluent chain.

#### `DatabaseManager`

A static registry of all open `JustDatabase` instances keyed by name. Prevents opening the same database twice. Exposes:

- `DatabaseManager.open(name, ...)` — opens/creates and registers a database
- `DatabaseManager.close(name)` — persists and deregisters
- `DatabaseManager.listDatabases()` — returns `List<DatabaseInfo>` for all known databases (open + persisted)
- `DatabaseManager.getOpenDatabase(name)` — looks up a live instance

#### `DatabaseInfo`

An immutable snapshot of database metadata (name, mode, table count, row count, file size, open state), used by the admin UI.

---

### Concurrency Layer

`LockManager` is an abstract interface with four operations: `acquireRead`, `releaseRead`, `acquireWrite`, `releaseWrite`. The concrete implementation is selected by `LockManager.forMode(DatabaseMode)` at database open time.

See the [Concurrency Model](#concurrency-model) section for full details.

---

### ORM Layer

`DbTable<T extends DbRecord>` provides an Active-Record–style API over a `JustDatabase` table.

- **`DbRecord`** — abstract base class; subclasses implement `toMap()` and a factory `fromMap()`.
- **`DbColumn`** — describes a column: name, SQL type, NOT NULL, UNIQUE, default value. Named factories (`DbColumn.text`, `.integer`, `.real`, `.boolean`, `.datetime`, `.blob`) produce correct SQL type strings.
- **`DbTable<T>`** — manages `CREATE TABLE`, single/batch insert, update, delete, and typed `findAll` / `findById` / `findWhere` using a caller-supplied `T Function(Map<String, dynamic>)` factory.

The ORM emits raw SQL and delegates to `JustDatabase.execute` / `query`, so all ORM operations go through the same SQL pipeline and benefit from indexes, locks, and persistence.

---

### Persistence Layer

Persistence is split into a platform-conditional export pair.

#### `persistence.dart` (gateway)

```dart
export 'persistence_native.dart'
    if (dart.library.js_interop) 'persistence_web.dart';
```

- `dart.library.js_interop` is `true` on JS-web **and** WASM.
- `dart.library.html` (the old guard) is `false` on WASM, so it was replaced.

#### `persistence_native.dart`

Full implementation for Android, iOS, macOS, Linux, Windows:

- **Storage format** — JSON-serialised `DatabaseSnapshot` containing table schemas and row data. Written to `<app_documents>/<name>.jdb`.
- **Encryption** — When `DatabaseMode.secure` is used, the JSON bytes are AES-256-GCM encrypted before writing. The IV is prepended to the ciphertext and stored together.
- **API** — `save(snapshot, name, key)`, `load(name, key)`, `delete(name)`, `listPersistedNames()`, `getFileSize(name)`, `peekMode(name)`.

#### `persistence_web.dart`

No-op stubs with matching signatures. Returns empty data on load; `save` and `delete` silently succeed. Allows the rest of the codebase to compile and run on web/WASM without conditional imports scattered everywhere.

#### `BackupManager` / `backup_native.dart` / `backup_web.dart`

Same conditional export pattern as persistence. On native:

- `exportSql(db)` — generates a SQL dump (CREATE TABLE + INSERT statements)
- `importSql(db, sql)` — executes the dump against a database
- `exportJson(db)` — serialises all tables to JSON
- `importJson(db, json)` — restores tables from JSON
- `backupToFile(db, path)` / `restoreFromFile(db, path)` — file I/O wrappers
- `backupToJsonFile(db, path)` / `restoreFromJsonFile(db, path)` — JSON file wrappers

On web: in-memory methods (`exportSql`, `importSql`, `exportJson`, `importJson`) are fully implemented; file methods throw `UnsupportedError`.

#### `SecureKeyManager`

Manages AES-256 key material using `just_storage` (which itself uses browser storage on web and `flutter_secure_storage` / `shared_preferences` on native):

- `resolveKey({dbName, password})` — derives a key from a password via PBKDF2 using a per-database salt stored in `just_storage`.
- `resolveAutoKey({dbName})` — generates and persists a random 256-bit key (no password needed); used by the admin UI for one-click secure databases.
- `clearSalt` / `clearAutoKey` — remove stored key material.

---

### Benchmark Layer

`BenchmarkRunner` runs arbitrary SQL or executor operations for a configurable number of iterations and collects per-iteration `Duration` values. `QueryStats` computes mean, median, min, max, p95, p99, and throughput (ops/sec). Used by the admin UI's benchmark page and available to application developers for profiling.

---

### UI / Admin Layer

The admin UI is an optional Flutter widget that can be embedded anywhere in an app's widget tree.

#### `JustDatabaseAdminWidget`

A thin wrapper that creates a `ChangeNotifierProvider<DatabaseProvider>` and renders `JustDatabaseAdminScreen`. Consuming it requires no routing changes — it is just a widget.

#### `DatabaseProvider` (`ChangeNotifier`)

The single source of truth for all admin UI state:

- `databases` — list of `DatabaseInfo` for the sidebar
- `currentDatabase` — the currently selected `JustDatabase`
- `lastQueryResult` / `lastError` — result and error from the most recent operation
- `isLoading` — activity indicator flag
- `queryHistory` — recent SQL strings

All async operations call `notifyListeners()` on completion. The provider handles secure database creation transparently by calling `SecureKeyManager.resolveAutoKey` before `DatabaseManager.open`.

#### Screen & Tabs

`JustDatabaseAdminScreen` renders a tab bar with four tabs:

| Tab | Responsibility |
|---|---|
| **Databases** | List, create, open, close, delete databases |
| **Query Editor** | Type and execute raw SQL; display results in a table |
| **Schema** | Browse table schemas, column types, and index definitions |
| **Settings** | Default mode, persist toggle |

Two additional pages are navigated to from within the tabs:

| Page | Trigger |
|---|---|
| **Benchmark** | Launched from the Query Editor or Databases tab |
| **Insert** | Row-insertion form launched from the Schema tab |

---

## Data Flow

### SQL Query (SELECT)

```
app code
  │
  ▼
JustDatabase.query(sql)
  │  acquires read lock via LockManager
  │
  ▼
Executor.executeSQL(sql)
  │
  ├─► Lexer.tokenize(sql)  →  List<Token>
  │
  ├─► Parser.parseSQL(tokens)  →  SelectStatement
  │
  └─► Executor._executeSelect(stmt)
        │
        ├── resolve view? → recurse with stored SelectStatement
        ├── scan base Table rows
        ├── apply JOINs (nested loop, index-accelerated if available)
        ├── evaluate WHERE (check TableIndex; record usage in QueryTracker)
        ├── GROUP BY + HAVING
        ├── ORDER BY
        ├── LIMIT / OFFSET
        └── project columns (functions, aliases, DISTINCT)
              │
              ▼
          QueryResult { columns, rows, affectedRows, success }
  │
  ▼ releases read lock
```

### Write Statement (INSERT / UPDATE / DELETE)

```
JustDatabase.execute(sql)
  │  acquires write lock
  │
  ▼
Executor executes DML statement
  │
  ├── fire BEFORE triggers (if registered)
  ├── mutate Table rows
  ├── update all TableIndex buckets
  ├── fire AFTER triggers
  └── (if in transaction) changes are staged in live tables;
      snapshot at BEGIN is kept for ROLLBACK
  │
  ▼ releases write lock
  │
  ▼ auto-persist (if persist: true and not in transaction)
```

---

## Concurrency Model

The concurrency model is selected once at `JustDatabase.open` time and cannot be changed. `LockManager.forMode` instantiates the correct implementation.

### `DatabaseMode.standard` / `DatabaseMode.secure`

`StandardLockManager` — simple async mutex per table. Both reads and writes acquire the same exclusive lock. Correct and low-overhead for general use. `secure` mode shares this implementation (encryption is a storage concern, not a concurrency one).

### `DatabaseMode.readFast`

`ReadFastLockManager` — readers-writer lock per table. Multiple concurrent readers are allowed. Writers are exclusive. Writer-preference prevents reader starvation of writers.

### `DatabaseMode.writeFast`

`WriteFastLockManager` — writes are buffered in a per-table queue and flushed on a 100ms timer. A read that targets a buffered table flushes it first. Best for write-heavy workloads where durable per-write consistency is not required.

---

## Persistence & Encryption

```
JustDatabase.close()
      │
      ▼
PersistenceManager.save(snapshot, name, encryptionKey)
      │
      ├── serialize to DatabaseSnapshot JSON
      │
      ├── [secure mode] AES-256-GCM encrypt
      │     key  → supplied at open() / auto-managed by SecureKeyManager
      │     IV   → 16 random bytes prepended to ciphertext
      │
      └── write to <app_documents>/<name>.jdb
```

On load (`JustDatabase.open` with `persist: true`):

```
PersistenceManager.load(name, encryptionKey)
      │
      ├── read .jdb file bytes
      ├── [secure mode] strip IV + AES-256-GCM decrypt
      ├── JSON-decode → DatabaseSnapshot
      └── reconstruct Table objects + re-instantiate indices
```

**Key management** for `DatabaseMode.secure`:

- Password-based: `SecureKeyManager.resolveKey(dbName, password)` derives a key via PBKDF2 (SHA-256, 100 000 iterations) using a per-database random salt stored in `just_storage`.
- Auto-key: `SecureKeyManager.resolveAutoKey(dbName)` generates a random 256-bit key on first call and stores it in `just_storage`. Subsequent calls retrieve the stored key. Used by the admin UI's one-click secure-database flow.

---

## Platform Portability

| Platform | Persistence | Encryption key storage | Backup files |
|---|---|---|---|
| Android | ✅ `dart:io` + `path_provider` | ✅ `just_storage` (secure storage) | ✅ |
| iOS | ✅ | ✅ | ✅ |
| macOS | ✅ | ✅ | ✅ |
| Linux | ✅ | ✅ | ✅ |
| Windows | ✅ | ✅ | ✅ |
| Web (JS) | ⚠️ no-op (in-memory only) | ✅ `just_storage` (localStorage) | ⚠️ in-memory only |
| Web (WASM) | ⚠️ no-op (in-memory only) | ✅ `just_storage` (localStorage) | ⚠️ in-memory only |

The conditional export guard `if (dart.library.js_interop)` covers both JS-web and WASM. `dart.library.html` is not used because it evaluates to `false` under WASM.

---

## Index Strategy

Every `Table` maintains a `Map<String, TableIndex>` of hash-bucket indexes. Indexes are created in three ways:

| Trigger | Type | Notes |
|---|---|---|
| Schema declaration (PK, UNIQUE, FK) | `primary`, `unique`, `foreign` | Created automatically at table construction |
| `CREATE INDEX` statement | `manual` | User-controlled; can be composite |
| `QueryTracker` threshold | `auto` | Created after a column appears in > 100 WHERE clauses |

The executor checks for an applicable index before performing a full table scan. Composite indexes are used when the WHERE clause references all indexed columns. The query hint `/*+ INDEX(table col) */` forces index use; `/*+ COMPOSITE_INDEX(table col1 col2) */` forces a composite index.

---

## Spatial Support

`spatial.dart` defines the geometric primitives: `Point`, `BoundingBox`, `Polygon`, `Circle`.

`rtree.dart` implements an in-memory **R-tree** spatial index over `BoundingBox` entries backed by `DatabaseRow` references. Supported spatial queries via SQL functions:

- `ST_MAKEPOINT(x, y)` — construct a Point
- `ST_DISTANCE(a, b)` — Euclidean distance between two Points
- `ST_CONTAINS(bbox, point)` — containment test
- `ST_INTERSECTS(a, b)` — bounding box intersection
- `ST_WITHIN(point, bbox)` — point-in-box test
- `ST_DWITHIN(point, centre, radius)` — radius search via R-tree

The `spatial` index type in `IndexType` links a `TableIndex` with an `RTree` for geometry-typed columns.

---

## Transaction Model

Transactions are WAL-lite: the executor takes a **deep copy of all tables** at `BEGIN` and stores it as `_txSnapshot`. All mutations during the transaction operate on the live tables directly. On `COMMIT` the snapshot is discarded. On `ROLLBACK` the live tables are replaced with the snapshot, restoring the prior state atomically.

**Savepoints** work the same way — each `SAVEPOINT name` stores an additional snapshot. `ROLLBACK TO name` restores that snapshot without ending the transaction. `RELEASE name` discards the savepoint snapshot.

Persistence is deferred while a transaction is active; `close()` or an explicit flush after `COMMIT` triggers the disk write.

---

## Migration System

`Migration` is an abstract class with `version`, `name`, `up(Executor)`, and optional `down(Executor)`. `SqlMigration` is a concrete subclass backed by raw SQL strings (supports `downSql` for rollback).

`MigrationRunner` applies a list of migrations in version order:

1. Ensures a `_migrations` meta-table exists.
2. Skips any migration whose version is already recorded in `_migrations`.
3. Optionally validates a `checksum` field (SHA-256 of the SQL) to detect tampering.
4. Executes `up(executor)` inside a transaction; records the migration on success.
5. Returns a `List<MigrationResult>` with per-step status (`applied`, `skipped`, `failed`).

---

## Dependency Graph

```
just_database
├── flutter/foundation (ChangeNotifier for UI layer)
├── provider ^6.1.2 (admin widget DI)
├── path_provider ^2.1.4 (native persistence only — excluded on web/WASM)
├── encrypt ^5.0.3 (AES-256-GCM — native only)
├── crypto ^3.0.3 (PBKDF2 key derivation, migration checksums)
└── just_storage ^1.1.2 (SecureKeyManager — cross-platform, WASM-ready)
```

Internal layers only depend downward:

```
UI  →  Core  →  SQL Pipeline  →  Storage Engine
             →  Concurrency
             →  Persistence   →  just_storage (cross-platform)
                              →  dart:io (native only)
```

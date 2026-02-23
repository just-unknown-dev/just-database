# Changelog

## [1.1.0] - 2026-02-23

### Added — Secure Mode (AES-256-GCM encryption at rest)

- `DatabaseMode.secure` — new database mode that encrypts every page written to
  disk with AES-256-GCM and a per-save random IV.  In-memory access is
  unaffected; encryption is applied only during persistence.
- **`SecureKeyManager`** — new public class in `lib/src/core/secure_key_manager.dart`
  (re-exported from the barrel) that manages the AES-256 key lifecycle:
  - `resolveKey({dbName, password})` — derives a 256-bit key from a user
    password via **PBKDF2-HMAC-SHA256** (100 000 iterations, 16-byte random
    salt). The salt is generated once, stored in `JustSecureStorage`, and
    retrieved on every subsequent call. The password is never written to disk.
  - `clearSalt({dbName})` — deletes the persisted salt for a database (use
    before deleting or resetting an encrypted database).
  - `resolveAutoKey({dbName})` — generates a cryptographically random 32-byte
    key with `Random.secure()`, stores it in `JustSecureStorage`, and returns
    it on every subsequent call. No user interaction required.
  - `clearAutoKey({dbName})` — deletes the auto-managed key for a database.
- `just_storage` companion package added as a dependency — provides
  `JustSecureStorage` (AES-256-GCM encrypted key-value store) used by
  `SecureKeyManager`.
- `encrypt ^5.0.3` and `crypto ^3.0.3` added as direct dependencies.

### Changed — Internal

- `class Row` (in `lib/src/storage/row.dart`) renamed to `DatabaseRow` to avoid
  shadowing Flutter's `Row` widget. All internal references updated across
  `table.dart`, `index.dart`, `executor.dart`, and `backup.dart`.
- All UI import sites that previously had `hide Row` directives have been
  cleaned up.
---

## [1.0.0] - 2026-02-20

### Added — Core Engine

- **Triggers** — `BEFORE`/`AFTER` `INSERT`, `UPDATE`, `DELETE`; `INSTEAD OF` on views;
  `NEW`/`OLD` row references; `WHEN` clause; multi-statement `BEGIN  END` bodies
- **Views** — `CREATE VIEW`, `DROP VIEW`, `SELECT` against views,
  `INSTEAD OF` triggers on views
- **Transactions (WAL)** — `BEGIN [DEFERRED|IMMEDIATE]`, `COMMIT`, `ROLLBACK`,
  `SAVEPOINT`, `RELEASE SAVEPOINT`, `ROLLBACK TO SAVEPOINT`;
  `transaction()` helper with automatic rollback on error
- **Spatial / R-tree indexes** — `Point`, `BoundingBox`, `Polygon` geometry types;
  `ST_MAKEPOINT`, `ST_X`, `ST_Y`, `ST_DISTANCE`, `ST_WITHIN`, `ST_INTERSECTS`,
  `ST_CONTAINS`, `ST_BBOX`; `CREATE SPATIAL INDEX`; quadratic-split R-tree
- **Query-optimization hints** — inline comment hints: `/*+ INDEX(t idx) */`,
  `/*+ NO_INDEX */`, `/*+ FULL_SCAN */`, `/*+ FORCE_INDEX(idx) */`
- **Backup & Restore** — `exportSql()` full SQL dump; `importSql()` restore;
  `exportJson()` / `importJson()` JSON snapshot; `backupToFile` / `restoreFromFile`
- **Schema Migrations** — `SqlMigration` (up/down SQL), `CallbackMigration` (Dart callbacks),
  `MigrationRunner` with versioned apply/rollback, SHA-256 checksum validation,
  `status()` report, persistent `_migrations` tracking table
- **Performance Benchmarking** — `DatabaseBenchmark` (8-op standard suite),
  `BenchmarkSuite` (custom suites), `QueryStats` (avg/min/max/p95/p99/ops-per-sec),
  configurable warm-up + seed-row count

### Added — ORM Layer

- `DbRecord` — abstract base class; holds auto-managed `id`; forces `toMap()`
- `DbColumn` — typed column builder: `.integer()`, `.text()`, `.real()`,
  `.boolean()`, `.datetime()`, `.blob()` with `notNull`, `unique`, `defaultValue`
- `DbTable<T>` — generic type-safe table accessor; override `tableName`,
  `columns`, `fromRow()` to get full CRUD:
  - DDL: `createTable()`, `dropTable()`, `createTableSql()`
  - Insert: `insert()` (returns saved record with `id`), `insertAll()` (transactional)
  - Select: `findAll()`, `findById()`, `findWhere()`, `findFirst()`, `count()`
  - Update: `update()`, `updateWhere()`
  - Delete: `deleteById()`, `deleteWhere()`, `deleteAll()`
  - Raw: `rawQuery()`
- `DbTableException` — typed error for all ORM failures

### Added — Admin UI

- **Benchmark tab** — standard suite runner + custom single-query benchmark;
  throughput bars, p95/p99 stat cards, copy-to-clipboard results
- **Insert Row tab** — dynamic form driven by the live table schema;
  per-column input types (text, number, boolean switch, date picker);
  inline validation; success/error feedback
- **Settings tab** redesigned — live DB stats grid (tables/views/rows/triggers/indexes/size),
  engine-feature reference tiles, About card with version + license + repo

### Added — public API on `JustDatabase`

- `runStandardBenchmark({rowCount, warmup, iterations})`  `Future<BenchmarkSuiteResult>`
- `benchmarkQuery(label, sql, {warmup, iterations})`  `Future<QueryStats>`
- `triggerNames` getter — `List<String>`
- `viewNames` getter — `List<String>`
- `indexNamesForTable(String)` — `List<String>`
- `totalRows` getter — `int`
- `estimatedSizeBytes` getter — `int`

### Added — version constant

- `kJustDatabaseVersion` constant in `lib/src/version.dart`

### Fixed (from 0.0.1)

- `HAVING` clause with aggregate functions now works correctly
- `ALTER TABLE RENAME COLUMN` fully removes old column references
- Subqueries now support correlated patterns and `IN` clauses
- R-tree spatial index quadratic split algorithm correctness

### Changed

- 141 tests passing (69 original + 72 new feature tests)
- Admin UI tabs: Databases  Schema  **Insert**  Query  **Benchmark**  Settings

### Known Limitations

- No `FULL OUTER JOIN` (INNER, LEFT, RIGHT are supported)
- No `CHECK` constraints
- No recursive CTEs (`WITH RECURSIVE`)
- `BLOB` columns accept hex-string values in the Insert UI

---

## [0.0.1] - 2026-02-20

### Added

- Initial release of just_database
- Pure Dart SQL database engine with in-memory storage
- Optional file persistence (path_provider)
- `CREATE`, `SELECT`, `INSERT`, `UPDATE`, `DELETE` statements
- `PRIMARY KEY`, `UNIQUE`, `FOREIGN KEY`, `NOT NULL`, `DEFAULT` constraints
- Composite indexes for multi-column queries
- Automatic query-based indexing (creates indexes after 100+ queries)
- Three concurrency modes: `standard`, `readFast`, `writeFast`
- Query tracking and performance monitoring
- Index metadata with hit ratios and usage statistics
- `DatabaseManager` for managing multiple databases
- Flutter admin UI: Database management, Schema inspector, SQL query editor, Settings
- `DatabaseProvider` ChangeNotifier for state management
- `INTEGER`, `REAL`, `TEXT`, `BOOLEAN`, `BLOB`, `DATETIME` data types
- `AUTOINCREMENT` support for primary keys
- `JOIN` operations: `INNER JOIN`, `LEFT JOIN`, `RIGHT JOIN`
- Aggregate functions: `COUNT`, `SUM`, `AVG`, `MIN`, `MAX`
- `GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`, `OFFSET`
- `DISTINCT`
- `ALTER TABLE`: `ADD COLUMN`, `DROP COLUMN`, `RENAME COLUMN`
- Scalar subqueries in `SELECT` and `WHERE`
- Nested subqueries

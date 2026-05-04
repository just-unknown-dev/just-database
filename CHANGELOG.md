# Changelog

## [1.4.1] - 2026-05-05

### Fixed

- **Web / WASM platform compatibility** — `SecureKeyManager.resolveKey()` now
  uses Flutter's `compute()` instead of `Isolate.run()` to offload the
  PBKDF2-HMAC-SHA256 derivation. `dart:isolate` is unavailable on web and WASM,
  causing the entire `ui.dart` import chain to be flagged as incompatible on
  pub.dev. `compute` provides identical off-thread behaviour on native (isolate)
  and web/WASM (web worker).
- **pub.dev description length** — package description expanded to meet the
  pub.dev requirement of 50–180 characters (was 34).

## [1.4.0] - 2026-05-04

### Added

- **`DatabaseDetailPage`** — new admin UI page for inspecting a single
  database: table list, row counts, schema viewer, and live query runner.
  Exported from `lib/ui.dart` and linked from `DatabasesTab` via tap-through
  navigation. (`66afd4eb`)
- **Async web introspection** — `tableNamesAsync()`, `viewNamesAsync()`,
  `triggerNamesAsync()`, `indexNamesForTableAsync()`, `getTableSchemaAsync()`,
  `totalRowsAsync()`, and `estimatedSizeBytesAsync()` added to the web
  `JustDatabase`. These delegate to the OPFS worker via the existing
  `WorkerClient` introspect protocol; the old sync getters still work for
  IndexedDB and in-memory backends.
- **`JustDatabase.onStorageDowngrade`** — static callback invoked when
  `persist: true` is requested on web but neither OPFS nor IndexedDB is
  available. Lets callers surface the warning in their own logging stack
  instead of silently running in-memory.

### Changed

- **State management** — admin UI widgets migrated from `provider` to
  `just_signals` (`^1.0.1`). `provider` is no longer a dependency.
  (`28a9d1db`)
- **PBKDF2 iterations raised to 310 000** (was 100 000) to meet NIST SP
  800-132 (2023) recommendation for PBKDF2-HMAC-SHA256.
  **⚠ Breaking for encrypted databases**: any `.jdb` file encrypted with a
  password under v1.3.x will be unreadable after this upgrade because the
  derived key changes. Migrate by exporting with `BackupManager.exportSql()`
  before upgrading, then re-importing after. Auto-key databases (`resolveAutoKey`)
  are unaffected — the raw key is stored directly and not re-derived.
- **PBKDF2 runs in a background isolate** — `SecureKeyManager.resolveKey()`
  now executes the CPU-heavy derivation via `Isolate.run()`, so the Flutter
  UI thread is never blocked even on low-end devices.

### Fixed

- **Version constant** — `kJustDatabaseVersion` in `version.dart` now matches
  `pubspec.yaml` (`1.4.0`).
- **Hex encoding performance** — BLOB SQL literals (`_sqlLiteral` in
  `db_table.dart`) and encryption key serialisation (`secure_key_manager.dart`)
  now use a `StringBuffer` + lookup-table approach instead of
  `map(...).join()`, eliminating N intermediate `String` allocations per byte.

### Documentation

- Clarified **best-effort durability** semantics: persistence after each write
  is fire-and-forget (`unawaited`). A process crash between query return and
  disk flush loses at most one committed write. See code comments in
  `database_native.dart` and `database_web.dart`.
- `WriteFastLockManager` now documents its 100 ms volatile write window and
  recommends `DatabaseMode.standard` when per-write durability is required.

## [1.3.0] - 2026-03-19

### Added — Web Persistence (OPFS + IndexedDB)

- **OPFS Web Worker persistence** — databases opened with `persist: true` on web
  now survive page reloads. A dedicated Web Worker runs the SQL engine against
  the Origin Private File System using synchronous `FileSystemSyncAccessHandle`,
  keeping the main thread free.
- **Write-Ahead Log (WAL)** — all mutations are journalled to a separate OPFS
  file before being applied, providing crash-safe durability. Auto-checkpoint
  triggers at 1 MB or 1 000 entries.
- **IndexedDB fallback** — when OPFS or Web Workers are unavailable (older
  browsers, cross-origin iframes), the engine automatically falls back to
  IndexedDB snapshot persistence on the main thread.
- **In-memory last resort** — if neither OPFS nor IndexedDB is available, the
  database runs in memory only (same as 1.2.0 behaviour).
- `WebStorageBackend` enum — `opfsWorker`, `indexedDb`, `memory`. Indicates
  which backend was selected at runtime.
- `storageBackend` getter on `JustDatabase` (web only) — returns the active
  `WebStorageBackend`.
- `DatabaseSerializer` utility (`lib/src/serialization.dart`) — extracted
  encode / decode helpers shared by native file persistence and the web layer.
- 8 new files under `lib/src/web/`: `opfs_support.dart`, `opfs_storage.dart`,
  `wal_manager.dart`, `opfs_persistence.dart`, `idb_persistence.dart`,
  `worker_protocol.dart`, `database_worker.dart`, `worker_client.dart`.
- `database_native.dart` / `database_web.dart` — `database.dart` is now a
  conditional export gateway (`dart.library.js_interop`), matching the existing
  pattern used by persistence and backup.

### Changed

- `web` package promoted from transitive to direct dependency (`^1.1.0`).
- `persistence_web.dart` now delegates to `OpfsPersistence` or
  `IdbPersistence` instead of being a no-op stub.

## [1.2.0] - 2026-03-14

### Added — Web & WASM Support

- **Web (JS) and Web (WASM) platform targets** — `just_database` now compiles and
  runs on all Flutter web targets without modification.
- `persistence_native.dart` / `persistence_web.dart` — persistence implementation
  split into a native file (`dart:io` + `path_provider` + `encrypt`) and a
  web/WASM no-op stub. The public `persistence.dart` is now a conditional export
  gateway: `dart.library.js_interop` selects the stub on both JS-web and WASM.
- `backup_native.dart` / `backup_web.dart` — same conditional export pattern for
  `BackupManager`. In-memory methods (`exportSql`, `importSql`, `exportJson`,
  `importJson`) are fully functional on web. File helpers (`backupToFile`,
  `restoreFromFile`, `backupToJsonFile`, `restoreFromJsonFile`) throw
  `UnsupportedError` on web/WASM with a clear message.
- `platforms:` declarations added to `pubspec.yaml` — explicitly lists
  `android`, `ios`, `linux`, `macos`, `web`, and `windows` so pub.dev renders
  the platform badge matrix correctly.
- `SecureKeyManager` works transparently on web/WASM — key material is stored
  via `just_storage ^1.1.2` which uses browser `localStorage` on web.

### Changed

- Conditional export guard changed from `dart.library.html` to
  `dart.library.js_interop`. `dart.library.html` evaluates to `false` under
  WASM, causing the native (dart:io) implementation to be selected incorrectly.
  `dart.library.js_interop` is `true` on both JS-web and WASM.
- `just_storage` dependency bumped to `^1.1.2` (WASM-ready; uses `package:web`).

---

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

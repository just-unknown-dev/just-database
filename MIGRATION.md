# Migrating from just_database 1.x to 2.0

2.0 replaces the SQL engine with one that follows SQLite, moves the files,
changes the file format, and tidies the API. It reads every 1.x database
file. This guide lists what you may have to change, most common first.

## 1. Dependencies

```yaml
dependencies:
  just_database: ^2.0.0
```

2.0 needs Flutter 3.47.1 or newer, `just_signals` 2.x and `just_storage`
2.x. It no longer depends on `encrypt`.

## 2. Encryption is not a mode

```dart
// 1.x
JustDatabase.open('vault', mode: DatabaseMode.secure, encryptionKey: key);
// 2.0
JustDatabase.open('vault', encryptionKey: key);
```

`DatabaseMode` is now `standard`, `readFast` or `writeFast`; any of them can
be encrypted. An empty key is rejected, and so is a key with
`persist: false`.

The passphrase now goes through PBKDF2-HMAC-SHA256 (600 000 iterations, a
salt per file); 1.x used a single SHA-256. A 1.x encrypted file opens with
the same `encryptionKey` and is re-encrypted the 2.0 way on the next save.
Opening an encrypted file without its key, or a plain file with a key,
throws `StateError`; `db.changeEncryptionKey()` encrypts, re-keys or
decrypts an open database.

`SecureKeyManager.resolveKey` and `resolveAutoKey` work as before and return
the same keys for databases created with them. New salts made by
`resolveKey` derive the key from the password's UTF-8 bytes; 1.x salts keep
the 1.x derivation.

## 3. Files moved

1.x saved to `<documents>/just_database/`, which on desktop every app shares.
2.0 saves to `<application support>/just_database/`. When you open a
database that only exists in the old place, it is copied (moved on Android
and iOS) the first time. Files other apps left in the shared documents
folder are not touched, and `DatabaseManager.deleteAll()` only deletes this
app's databases.

On the web, the OPFS/Web Worker backend (which never activated) is gone;
databases stay in IndexedDB, and an encrypted database is now really
encrypted there.

## 4. The file format

The first save rewrites a 1.x file in format 2, which 1.x cannot read: after
upgrading, do not go back without a backup. Format 2 keeps views,
triggers, CREATE INDEX indexes, rowids and AUTOINCREMENT counters (1.x
silently lost the first three).

1.x did not enforce some keys, so a 1.x file can hold duplicates in a
UNIQUE or PRIMARY KEY column. 2.0 keeps those rows, drops that constraint
and prints a warning; recreate the constraint once the data is clean.

## 5. SQL now behaves like SQLite

Most code keeps working. These differences can change results:

| | 1.x | 2.0 |
|---|---|---|
| `NULL = NULL`, `x != 1` on NULL | true / matched | NULL: not matched (use `IS`, `IS NOT`) |
| `'a' + 'b'` | `'ab'` | `0` (use `'a' \|\| 'b'`) |
| `BOOLEAN` values | Dart `bool` | `1` / `0` (`WHERE active = 1` now works) |
| `DATETIME` values | Dart `DateTime` | ISO-8601 text (UTC when bound from a `DateTime`) |
| unknown column in `WHERE`/`SET` | NULL / silently stored | error |
| `DELETE FROM t WHRE id = 1` | deleted every row | syntax error |
| two statements in one `execute` | ran the first | error; use `executeScript` |
| `SELECT UPPER(name) FROM t` | one row | every row |
| `SELECT a+1, a+2` | one column | two columns (`a+1`, `a+2`) |
| table-level `PRIMARY KEY (id)`, `CREATE UNIQUE INDEX` | not enforced | enforced |
| `id INTEGER PRIMARY KEY` | a counter | the rowid (`INT PRIMARY KEY` is a plain key) |
| `TINYINT`, `NVARCHAR`, … | text | SQLite affinity (`TINYINT` is integer) |
| `3.7` into `INTEGER` | `3` | `3.7` (as SQLite) |
| `LIKE`, `lower()`, `upper()` | Unicode case | ASCII case only |
| a failing multi-row statement | kept the rows before the failure | changes nothing |
| foreign keys | partly checked | enforced, with actions (`PRAGMA foreign_keys = OFF` to stop) |
| triggers' `NEW.id` for an auto id | NULL | the new id (in `AFTER` triggers) |
| `CREATE OR REPLACE VIEW` | replaced the view | syntax error (`DROP VIEW` then `CREATE VIEW`) |
| `DROP INDEX name ON table` | accepted | syntax error (`DROP INDEX name`) |

Result column names follow SQLite: `SELECT COUNT(*)` is `COUNT(*)` even on
an empty table, and repeated names get `:1`, `:2`.

## 6. Statements and results

```dart
// 1.x: values pasted into SQL
db.execute("INSERT INTO t (name) VALUES ('${name.replaceAll("'", "''")}')");
// 2.0: bound
db.execute('INSERT INTO t (name) VALUES (?)', [name]);
```

* `query()` only runs `SELECT`; a write there fails (it used to run without
  being saved). Use `execute()`.
* `QueryResult` adds `values`, `error` (a `SqlException`), `scalar`,
  `lastInsertRowId` and `orThrow()`. Its `rows` are unmodifiable.

## 7. Transactions

```dart
// 1.x: the callback got the database; failures returned results
await db.transaction((db) async { await db.execute(...); });
// 2.0: the callback gets a Transaction whose statements throw
await db.transaction((tx) async { await tx.execute(...); });
```

A failing statement inside now rolls the transaction back (1.x committed
it). Other callers wait until the transaction ends.

## 8. Opening, closing, saving

* Opening an open name returns the same instance; call `close()` once per
  `open()`. Opening it with other settings throws.
* `close()` waits for running statements, rolls back an open transaction,
  saves, and throws if that save fails. Closing twice is harmless.
* Nothing uncommitted is ever saved; `close()` inside a transaction no
  longer saves half of it.
* `onSaveError` reports background save failures; `flush()` throws them.
* Database names are now checked: 1–128 letters, digits, `_`, `.` or `-`.

## 9. Removed APIs

| 1.x | 2.0 |
|---|---|
| `Executor`, `Parser`, the AST classes, `Table`, `TableIndex`, `DatabaseRow`, `LockManager`, `QueryTracker`, `PersistenceManager`, `RTreeIndex`, `BoundingBox`, `Point` | internal; use `JustDatabase` |
| `BackupManager` | `db.exportSql()`, `exportJson()`, `importSql()`, `importJson()` |
| `JustDatabaseAdminWidget` | `JustDatabaseAdminScreen` |
| `JUDatabaseAdminScreen` | `JustDatabaseAdminScreen({theme, onSeedDatabase, provider, title})` |
| `DatabaseProvider` actions returning `void` | `Future<bool>`; on failure `lastError` (queries: `lastQueryError`) |
| UI exports in `just_database.dart` | `import 'package:just_database/ui.dart';` |
| `DataType`, `ConstraintDefinition` | `ColumnDefinition` (`type`, `affinity`, `notNull`, …), `TableConstraint`, `ForeignKeyDefinition` |
| `TableSchema.tableName` | `TableSchema.name` |
| `DatabaseManager.openDatabases` as a mutable map | read-only |
| `MigrationStatus.skipped` (rollback) | `MigrationStatus.rolledBack` |
| `MigrationGuard` | not needed: migrations run on `JustDatabase` |
| automatic query-pattern indexes | gone; create indexes yourself |

## 10. Migrations

`Migration.up`/`down` receive a `Transaction` (it was an `Executor`):

```dart
CallbackMigration(
  version: 2,
  name: 'add email',
  upCallback: (tx) => tx.execute('ALTER TABLE users ADD COLUMN email TEXT'),
);
```

Each migration runs in its own transaction. Duplicate versions or versions
below 1 throw `ArgumentError`; a changed applied migration or a pending one
older than the newest applied throws `MigrationException`. The `_migrations`
table is unchanged, so existing history carries over.

## 11. ORM

* `fromRow` receives `Map<String, Object?>`; booleans and dates come back as
  `1`/`0` and text. Use the row helpers: `row.boolValue('active')`,
  `row.dateTimeValue('at')`, `row.intValue('id')`, …
* `findAll`, `findWhere`, `findFirst`, `count`, `updateWhere` and
  `deleteWhere` take `whereArgs` for `?` placeholders.
* `insert` returns the row it inserted even when others insert at the same
  time; `insertAll` runs in one transaction.

## 12. Query builder and benchmarks

* `db.from(t).where(condition, [params])` binds values; `whereEquals`
  added; names are quoted.
* `runStandardBenchmark` runs on a private in-memory database (1.x created
  and dropped `_bench_t` in yours); `benchmarkQuery` only runs reads.
  `DatabaseBenchmark` is replaced by these and `runStandardDatabaseBenchmark`.

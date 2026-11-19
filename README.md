# just_database

A SQL database for Flutter written in pure Dart: SQLite-style SQL over an
in-memory engine, saved to a file (IndexedDB on the web) after every
committed change, with optional AES-256-GCM encryption, migrations, backups,
a typed ORM and an admin UI.

[![pub.dev](https://img.shields.io/pub/v/just_database.svg)](https://pub.dev/packages/just_database)
[![License: BSD 3-Clause](https://img.shields.io/badge/License-BSD-blue.svg)](LICENSE)

* **SQL that behaves like SQLite**: joins of every kind, correlated
  subqueries, `IN`/`EXISTS`, `UNION`/`INTERSECT`/`EXCEPT`, `CASE`, `CAST`,
  aggregates with `DISTINCT`, upserts, triggers (including `INSTEAD OF`),
  views, `CHECK`, foreign keys with `CASCADE`/`SET NULL`/…, savepoints,
  three-valued `NULL` logic and SQLite's type affinity.
* **Bound parameters** (`?`, `?NNN`, `:name`, `@name`, `$name`) on every
  statement, so values never have to be pasted into SQL.
* **Atomic statements and isolated transactions**: a failing statement
  changes nothing; `transaction()` holds the database until it ends.
* **Durable saves**: every committed change is written atomically (temp
  file + rename); nothing uncommitted ever reaches the file.
* **Encryption**: AES-256-GCM with a PBKDF2-HMAC-SHA256 key (600 000
  iterations, random salt per file).
* Runs everywhere Flutter does: Android, iOS, macOS, Windows, Linux and the
  web (JS and WASM). No native code.

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [Statements and results](#statements-and-results)
- [Transactions](#transactions)
- [Saving, files and modes](#saving-files-and-modes)
- [Encryption](#encryption)
- [The SQL dialect](#the-sql-dialect)
- [Spatial data](#spatial-data)
- [Migrations](#migrations)
- [Backup and restore](#backup-and-restore)
- [ORM](#orm)
- [Query builder](#query-builder)
- [Admin UI](#admin-ui)
- [Benchmarks](#benchmarks)
- [Errors](#errors)
- [Limits](#limits)

## Install

```yaml
dependencies:
  just_database: ^2.0.0
```

Requires Flutter 3.47.1 or newer. Coming from 1.x? Read
[MIGRATION.md](MIGRATION.md): 2.0 changes the SQL semantics, the file
location and several APIs, and reads every 1.x file.

## Quick start

```dart
import 'package:just_database/just_database.dart';

Future<void> main() async {
  final db = await JustDatabase.open('app');

  await db.execute('''
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      email TEXT UNIQUE,
      joined DATETIME DEFAULT CURRENT_TIMESTAMP
    )''');

  final added = await db.execute(
    'INSERT INTO users (name, email) VALUES (?, ?)',
    ["Ann O'Brien", 'ann@example.com'],
  );
  print(added.lastInsertRowId); // 1

  final result = await db.query(
    'SELECT id, name FROM users WHERE email = :email',
    {'email': 'ann@example.com'},
  );
  for (final row in result.rows) {
    print('${row['id']}: ${row['name']}');
  }

  await db.close();
}
```

## Statements and results

| Method | Runs | On failure |
|---|---|---|
| `execute(sql, [params])` | any one statement | returns a result with `success == false` |
| `query(sql, [params])` | one `SELECT` (or reading `PRAGMA`); anything else fails | same |
| `executeScript(sql)` | every statement, in order, until one fails | the last result is the failure |
| `tx.execute` / `tx.query` (in `transaction`) | one statement | **throws** `SqlException` |

`params` is a `List` (by position) or a `Map` (by name, with or without the
`:`/`@`/`$` prefix). Values may be `null`, `int`, `double`, `String`,
`Uint8List`, `bool` (stored as `1`/`0`) or `DateTime` (stored as ISO-8601
UTC text). A wrong number of parameters is an error.

A `QueryResult` has:

| Member | |
|---|---|
| `success`, `error`, `errorMessage` | whether it worked; the `SqlException` when not |
| `columns` | result column names, unique (`SELECT a.id, b.id` gives `id`, `id:1`) |
| `rows` | rows as `Map<String, Object?>` |
| `values` | rows as lists, in column order |
| `scalar` | first column of the first row (`SELECT COUNT(*) …`) |
| `affectedRows`, `lastInsertRowId` | for `INSERT`/`UPDATE`/`DELETE` |
| `orThrow()` | the result, or throws its error |

Values come back as SQL stores them: `int`, `double`, `String`,
`Uint8List` or `null`. A `BOOLEAN` column holds `1`/`0`; a `DATETIME` column
holds text. The ORM's [row helpers](#orm) convert them.

Introspection: `tableNames`, `viewNames`, `triggerNames`,
`getTableSchema(table)`, `indexesForTable(table)`, `rowCount(table)`,
`totalRows`, `estimatedSizeBytes`.

## Transactions

```dart
await db.transaction((tx) async {
  await tx.execute('UPDATE accounts SET balance = balance - ? WHERE id = ?', [100, 1]);
  await tx.execute('UPDATE accounts SET balance = balance + ? WHERE id = ?', [100, 2]);
});
```

* If the callback throws (a failing `tx` statement throws `SqlException`),
  everything it did is rolled back and the error is rethrown; otherwise
  the transaction commits.
* The transaction holds the database: statements from other callers wait
  until it ends, so they never see or interleave with its changes.
* `tx.transaction(...)` (or `db.transaction` inside one) nests as a
  savepoint.
* `BEGIN`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`, `RELEASE` and
  `ROLLBACK TO` also work through `execute`, but such a transaction is
  shared by every caller of the database until it ends. Prefer
  `transaction()`.

Every statement is atomic on its own: if any row of a multi-row
`INSERT`/`UPDATE`/`DELETE` fails (or a trigger it fires fails), none of its
changes remain. `INSERT OR IGNORE/REPLACE/FAIL/ROLLBACK` choose otherwise,
as in SQLite.

## Saving, files and modes

`JustDatabase.open(name)` keeps the database in memory and saves it to
`<application support>/just_database/<name>.jdb` (IndexedDB on the web).
Pass `persist: false` for a database that is never saved.

* Each committed change starts a save in the background; saves that pile
  up merge into one. A save never happens in the middle of a transaction.
* Files are written to a temporary file and renamed over the old one, so a
  crash leaves the old file or the new one, never a mix.
* `await db.flush()` waits until everything so far is saved and throws if
  the last save failed. Failed background saves are also reported to
  `db.onSaveError`.
* `await db.close()` waits for running statements, rolls back a
  transaction left open, saves, and releases the file. It throws if that
  final save fails.
* Opening a name that is already open returns the same instance; `close()`
  closes it when every opener has closed it. Another process (or browser
  tab) cannot open it at the same time.
* `JustDatabase.open` throws `StateError` for a file it cannot read
  (damaged, written by a newer version, wrong key) and leaves the file
  alone.
* Names are 1–128 letters, digits, `_`, `.` or `-`.

`mode` changes ordering and saving:

| Mode | |
|---|---|
| `DatabaseMode.standard` | statements run in call order; each commit is saved |
| `DatabaseMode.readFast` | a `SELECT` does not queue behind writes called before it |
| `DatabaseMode.writeFast` | saves are batched (at most one per `JustDatabase.writeFastDelay`, 250 ms); `flush()` to save now |

`DatabaseManager` opens, lists (`listDatabases()`), closes and deletes
databases by name; the admin UI uses it.

## Encryption

```dart
final db = await JustDatabase.open('vault', encryptionKey: userPassphrase);
```

* The file is encrypted with AES-256-GCM. The key is derived from the
  passphrase with PBKDF2-HMAC-SHA256 (600 000 iterations) and a random
  16-byte salt stored in the file's header; every save uses a new 12-byte
  nonce. The header is authenticated, so a changed file or a wrong
  passphrase fails to open with a `StateError`.
* Deriving the key costs about a second on a phone. It runs on a background
  isolate (WebCrypto on the web), so the UI does not freeze, but `open`
  takes that long.
* `db.changeEncryptionKey(newPassphrase)` re-encrypts; `null` decrypts.
* 1.x encrypted files open with their old key and are rewritten in the new
  format on the next save.

Without a passphrase from the user, `SecureKeyManager.resolveAutoKey(dbName:)`
returns a random key generated once and stored by `just_storage` in the
app's private storage. That protects a copied database file, not a device
where someone can read the app's private data: the stored key is there too.

## The SQL dialect

The engine follows SQLite. Supported:

* `SELECT` with `DISTINCT`, `*`, `t.*`, joins (`INNER`, `LEFT`, `RIGHT`,
  `FULL`, `CROSS`, comma, `NATURAL`, `USING`), `WHERE`, `GROUP BY`,
  `HAVING`, `ORDER BY … [ASC|DESC] [NULLS FIRST|LAST]` (by expression,
  alias or position), `LIMIT … OFFSET …` / `LIMIT o, n`, subqueries in
  `FROM`, scalar and correlated subqueries, `IN (SELECT …)`, `EXISTS`,
  `UNION [ALL]`, `INTERSECT`, `EXCEPT`, `VALUES (…), (…)`.
* `INSERT [OR …] INTO … VALUES | SELECT | DEFAULT VALUES`,
  `REPLACE INTO`, `ON CONFLICT (cols) DO NOTHING | DO UPDATE SET … [WHERE …]`
  (with `excluded.col`), `UPDATE [OR …] … SET … WHERE …`, `DELETE`.
* `CREATE TABLE [IF NOT EXISTS] … (…)` and `… AS SELECT`, column and table
  constraints (`PRIMARY KEY`, `AUTOINCREMENT`, `NOT NULL`, `UNIQUE`,
  `CHECK`, `DEFAULT` (constants, signed numbers, `CURRENT_TIMESTAMP`,
  `(expr)`), `COLLATE`, `REFERENCES … ON DELETE/UPDATE …`), `DROP TABLE`,
  `ALTER TABLE … RENAME TO | RENAME COLUMN | ADD COLUMN | DROP COLUMN`
  (with SQLite's restrictions), `CREATE [UNIQUE] INDEX`, `DROP INDEX`,
  `CREATE VIEW`, `DROP VIEW`, `CREATE TRIGGER` (`BEFORE`/`AFTER`/
  `INSTEAD OF`, `INSERT`/`UPDATE [OF cols]`/`DELETE`, `WHEN`, `NEW`/`OLD`,
  `RAISE(IGNORE | ABORT | FAIL | ROLLBACK, msg)`), `DROP TRIGGER`.
* `BEGIN`, `COMMIT`/`END`, `ROLLBACK [TO]`, `SAVEPOINT`, `RELEASE`.
* `PRAGMA foreign_keys`, `user_version`, `table_info(t)`, `index_list(t)`.
* Quoted identifiers (`"x"`, `` `x` ``, `[x]`), blob literals (`X'0A1B'`),
  hex integers (`0x1F`), `--` and `/* */` comments.

Semantics worth knowing:

* `NULL` follows three-valued logic: `NULL = NULL` is `NULL`, `x IN (…,
  NULL)` can be `NULL`, `NOT IN` with a `NULL` matches nothing.
* Type affinity comes from the declared type (`INT…` integer;
  `CHAR`/`CLOB`/`TEXT` text; `BLOB` or none: as given; `REAL`/`FLOA`/`DOUB`
  real; anything else numeric), and comparisons convert like SQLite: in an
  `INTEGER` column `'5'` is stored as `5`, but `1 = '1'` between two
  untyped values is false. `BOOLEAN` and `DATETIME` columns are numeric:
  `TRUE`/`FALSE` are `1`/`0`; dates are text.
* A column declared exactly `INTEGER PRIMARY KEY` is the rowid; a new row
  gets the largest rowid + 1 (with `AUTOINCREMENT`: never reused). Every
  table has a `rowid` column.
* `+` is numeric (`'10' + 5` is `15`); use `||` to join text. Integer
  overflow becomes a real; division by zero is `NULL`.
* `LIKE` and `NOCASE` ignore case for ASCII letters only; `GLOB` is case
  sensitive.
* Foreign keys are enforced (`PRAGMA foreign_keys = OFF` turns them off),
  unlike SQLite's default. `NO ACTION` is checked when the statement ends,
  `RESTRICT` at once; `DEFERRABLE` is accepted but checked immediately.
* Triggers do not fire recursively (SQLite's default); nested trigger
  chains stop at 1000 levels.
* Result columns are named like SQLite names them: a column's name, an
  alias, otherwise the expression's text.

Functions: `abs char coalesce concat concat_ws format glob hex ifnull iif
instr last_insert_rowid length like likelihood likely lower ltrim max min
nullif octet_length printf quote random randomblob replace round rtrim sign
substr substring changes total_changes trim typeof unhex unicode unlikely
upper zeroblob`; math `acos asin atan atan2 ceil ceiling cos cosh degrees
exp floor ln log log10 log2 mod pi pow power radians sin sinh sqrt tan tanh
trunc`; dates `date time datetime julianday unixepoch strftime` (with
SQLite's modifiers: `±N days/hours/…`, `start of day/month/year`,
`weekday N`, `unixepoch`, `localtime`, `utc`, `subsec`); aggregates `count
sum total avg min max group_concat string_agg`, with `DISTINCT`.

Indexes speed up equality lookups (`col = ?`, `col IN (…)`, `rowid = ?`) on
the first table of a query, and joins on equal keys (other joins use a hash
table). Query hints choose: `SELECT /*+ INDEX(t idx) */ …` (or
`FORCE_INDEX`),
`/*+ NO_INDEX(t) */`, `/*+ FULL_SCAN */` (`JOIN_ORDER` is accepted and
ignored).

Not supported: `WITH` (CTEs), window functions, `RETURNING`, partial and
expression indexes, `WITHOUT ROWID`/`STRICT`/`TEMP`/virtual tables,
`REGEXP`/`MATCH`, JSON functions, `UPDATE … FROM`, `ORDER BY`/`LIMIT` on
`UPDATE`/`DELETE`, row values outside `VALUES`, collations other than
`BINARY`, `NOCASE`, `RTRIM`.

## Spatial data

Geometries are WKT text: `POINT(x y)` and single-ring
`POLYGON((x y, …, x y))`.

```dart
await db.execute('CREATE TABLE places (name TEXT, lng REAL, lat REAL)');
await db.execute('CREATE SPATIAL INDEX places_pos ON places (lng, lat)');
final near = await db.query(
  'SELECT name FROM places '
  'WHERE ST_WITHIN(ST_MAKEPOINT(lng, lat), ST_MAKEENVELOPE(?, ?, ?, ?))',
  [2.2, 48.8, 2.5, 48.9],
);
```

Functions: `ST_MAKEPOINT`/`ST_POINT`, `ST_X`, `ST_Y`, `ST_MAKEENVELOPE`
(`ST_BBOX`), `ST_ENVELOPE`, `ST_GEOMFROMTEXT`, `ST_ASTEXT`, `ST_ISVALID`,
`ST_WITHIN`, `ST_CONTAINS`, `ST_INTERSECTS`, `ST_DWITHIN`, `ST_DISTANCE`
(planar, in the coordinates' units) and `ST_DISTANCE_SPHERE` (metres,
x = longitude and y = latitude in degrees). A spatial index (an R-tree over
two numeric columns) answers `ST_WITHIN`/`ST_INTERSECTS`/`ST_CONTAINS`/
`ST_DWITHIN` on `ST_MAKEPOINT(x, y)` of its columns.

## Migrations

```dart
final results = await db.migrate([
  SqlMigration(
    version: 1,
    name: 'create users',
    upSql: 'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)',
    downSql: 'DROP TABLE users',
  ),
  CallbackMigration(
    version: 2,
    name: 'add email',
    upCallback: (tx) => tx.execute('ALTER TABLE users ADD COLUMN email TEXT'),
  ),
]);
```

Applied versions live in a `_migrations` table. Each migration runs in its
own transaction with its bookkeeping, so a failed one leaves nothing
behind; `migrate` stops there and reports it. `migrate` saves before it
returns. It throws `MigrationException` when an applied `SqlMigration`
changed (its checksum differs) or when a pending migration has a lower
version than one already applied. `db.migrationRunner(list)` also offers
`rollback(targetVersion:)`, `status()` and `currentVersion()`.

## Backup and restore

```dart
final sql = await db.exportSql();     // a script that recreates everything
final json = await db.exportJson();   // the file format, as JSON
await other.importSql(sql);           // replaces the whole database
await other.importJson(json);
```

Exports include tables (with rowids), indexes, views, triggers and
`user_version`; the JSON export also keeps `AUTOINCREMENT` high-water
marks. An import runs against an empty database first and only replaces
the current one when every statement succeeded.

## ORM

```dart
class User extends DbRecord {
  const User({super.id, required this.name, this.active = true});
  final String name;
  final bool active;

  @override
  Map<String, Object?> toMap() => {'name': name, 'active': active};
}

class Users extends DbTable<User> {
  @override
  String get tableName => 'users';

  @override
  List<DbColumn> get columns => [
    DbColumn.text('name', notNull: true),
    DbColumn.boolean('active', defaultValue: true),
  ];

  @override
  User fromRow(Map<String, Object?> row) => User(
    id: row.intValue('id'),
    name: row.stringValue('name')!,
    active: row.boolValue('active') ?? true,
  );
}

final users = Users();
await users.createTable(db);
final ann = await users.insert(db, const User(name: 'Ann'));
final active = await users.findAll(db, where: 'active = ?', whereArgs: [true]);
```

`DbTable` adds `id INTEGER PRIMARY KEY AUTOINCREMENT` and offers `insert`,
`insertAll` (one transaction), `findAll`, `findById`, `findWhere`,
`findFirst`, `count`, `update`, `updateWhere`, `deleteById`,
`deleteWhere`, `deleteAll` and `rawQuery`. Names are quoted and values
bound; `where` is SQL you write, so quote reserved words there. The
`intValue`, `doubleValue`, `stringValue`, `boolValue`, `dateTimeValue` and
`bytesValue` row helpers convert stored values.

## Query builder

```dart
final page = await db.from('users')
    .select(['id', 'name'])
    .where('name LIKE ?', ['A%'])
    .orderBy('name')
    .limit(20)
    .offset(40)
    .get();
await db.from('users').whereEquals('id', 3).update({'name': 'Bo'});
```

## Admin UI

```dart
import 'package:just_database/ui.dart';

MaterialApp(home: const JustDatabaseAdminScreen());
```

A screen to create, open, browse (paged), edit, insert into, query,
benchmark and delete databases. Databases your app already opened appear
there and are used as they are, never opened twice. Rows are edited and
deleted by rowid with bound values. It is only in
`package:just_database/ui.dart`; the main library has no UI.

`JustDatabaseAdminScreen({theme, onSeedDatabase, provider, title})` takes a
theme for the screen and every page it opens, an optional seeding callback
(adds a "Seed sample data" action), and a `DatabaseProvider` when you want
to drive it yourself. `DatabaseDetailPage`, `InsertPage`, `BenchmarkPage`
and the four tabs are exported too.

Name new databases with `JustDatabase.nameProblem(name)` to check them
first (null means the name is fine).

## Benchmarks

```dart
final suite = await db.runStandardBenchmark(rowCount: 1000);
print(suite.formatTable());
final stats = await db.benchmarkQuery('by name', 'SELECT * FROM users WHERE name = ?', parameters: ['Ann']);
print(stats.format());
```

The standard suite runs on a private in-memory database; `benchmarkQuery`
only runs read-only statements.

## Errors

Failures carry a `SqlException` with a `kind`: `syntax`, `schema` (no such
table/column, name in use), `constraint` (NOT NULL, UNIQUE, CHECK, FOREIGN
KEY), `raised` (a trigger's `RAISE`), `misuse` (wrong parameters, a write
passed to `query`, …) or `error`. `JustDatabase.open`, `flush` and `close`
throw `StateError`/`ArgumentError` for problems with the file, the name or
the key.

## Limits

* The whole database lives in memory, and each save rewrites the whole
  file (about 40 ms per MB, plus encryption). It suits app data up to tens
  of megabytes, not hundreds.
* Indexes are hash indexes: they help equality, not ranges or `ORDER BY`.
* On the web, integers are JavaScript numbers: exact up to 2^53.
* Two isolates of one process opening the same database are only kept
  apart on Windows; use one isolate per database.

## Links

* [MIGRATION.md](MIGRATION.md): upgrading from 1.x
* [ARCHITECTURE.md](ARCHITECTURE.md): how it works
* [CHANGELOG.md](CHANGELOG.md)
* [Issues](https://github.com/just-unknown-dev/just-database/issues)

BSD 3-Clause licence.

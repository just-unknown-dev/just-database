# Just Database

A pure-Dart SQL database engine for Flutter — in-memory storage, optional file
persistence, a rich SQL dialect, an ORM layer, and an embeddable admin UI.

[![pub.dev](https://img.shields.io/pub/v/just_database.svg)](https://pub.dev/packages/just_database)
[![License: BSD 3-Clause License](https://img.shields.io/badge/License-BSD-blue.svg)](LICENSE)
---

## Features

| Capability | Details |
|---|---|
| Pure Dart | No native code — runs on Android, iOS, Web, Desktop |
| SQL dialect | SELECT/INSERT/UPDATE/DELETE/CREATE/DROP/ALTER, JOINs, subqueries, GROUP BY/HAVING |
| Views | CREATE VIEW, DROP VIEW, INSTEAD OF triggers |
| Triggers | BEFORE/AFTER INSERT/UPDATE/DELETE, NEW/OLD, WHEN clause |
| Transactions | BEGIN/COMMIT/ROLLBACK, SAVEPOINT, WAL mode |
| Spatial | R-tree index, ST_* functions, Point/BoundingBox/Polygon |
| Indexes | AUTO-INDEX, CREATE [UNIQUE/SPATIAL] INDEX, composite, query hints |
| Backup | SQL dump + JSON snapshot, file helpers |
| Migrations | SqlMigration, CallbackMigration, MigrationRunner, checksum |
| Benchmarking | DatabaseBenchmark, BenchmarkSuite, QueryStats (p95/p99) |
| ORM | DbTable<T> / DbRecord / DbColumn — type-safe CRUD with zero boilerplate |
| **Secure mode** | **AES-256-GCM encryption at rest, SHA-256 key derivation, per-save random IV** |
| Admin UI | 4-tab Flutter admin screen embeddable in any app |

---

## Installation

```yaml
dependencies:
  just_database: ^1.0.0
```

```bash
flutter pub get
```

---

## Quick Start

### Raw SQL

```dart
import 'package:just_database/just_database.dart';

void main() async {
  // Persistence is ON by default. Pass persist: false to keep in-memory only.
  final db = await JustDatabase.open('mydb');

  await db.execute('''
    CREATE TABLE users (
      id    INTEGER PRIMARY KEY AUTOINCREMENT,
      name  TEXT    NOT NULL,
      email TEXT    UNIQUE NOT NULL,
      age   INTEGER
    )
  ''');

  await db.execute(
    "INSERT INTO users (name, email, age) VALUES ('Alice', 'alice@example.com', 28)",
  );

  final result = await db.query('SELECT * FROM users WHERE age > 25');
  debugPrint(result.rows); // [{id: 1, name: Alice, ...}]

  await db.close();
}
```

### ORM Layer

```dart
// 1. Define your model
class User extends DbRecord {
  final String name;
  final String email;
  final int    age;

  const User({super.id, required this.name, required this.email, required this.age});

  @override
  Map<String, dynamic> toMap() => {'name': name, 'email': email, 'age': age};

  User copyWith({int? id, String? name, String? email, int? age}) => User(
    id: id ?? this.id, name: name ?? this.name,
    email: email ?? this.email, age: age ?? this.age,
  );
}

// 2. Define the table
class UserTable extends DbTable<User> {
  @override String get tableName => 'users';

  @override
  List<DbColumn> get columns => [
    DbColumn.text('name',  notNull: true),
    DbColumn.text('email', notNull: true, unique: true),
    DbColumn.integer('age', defaultValue: 0),
  ];

  @override
  User fromRow(Map<String, dynamic> row) => User(
    id:    row['id']    as int?,
    name:  row['name']  as String,
    email: row['email'] as String,
    age:   row['age']   as int? ?? 0,
  );
}

// 3. Use it
void main() async {
  final db    = await JustDatabase.open('mydb');
  final users = UserTable();

  await users.createTable(db);

  final alice = await users.insert(db, const User(name: 'Alice', email: 'a@x.com', age: 30));
  debugPrint(alice.id); // auto-assigned

  final all   = await users.findAll(db, where: 'age > 18', orderBy: 'name');
  final total = await users.count(db);
  await users.update(db, alice.copyWith(age: 31));
  await users.deleteById(db, alice.id!);
}
```

---

## Database Modes

```dart
// Balanced read/write (default) — persisted to disk by default
final db = await JustDatabase.open('db', mode: DatabaseMode.standard);

// Many concurrent readers, exclusive writers
final db = await JustDatabase.open('db', mode: DatabaseMode.readFast);

// Buffered writes with 100 ms batch commits
final db = await JustDatabase.open('db', mode: DatabaseMode.writeFast);

// Explicit in-memory only (no file written)
final db = await JustDatabase.open('db', persist: false);

// AES-256-GCM encrypted at rest (requires passphrase)
final db = await JustDatabase.open(
  'vault',
  mode: DatabaseMode.secure,
  encryptionKey: 'my-secret-passphrase',
);
```

---

## Secure Database

`DatabaseMode.secure` encrypts the persisted `.jdb` file using **AES-256-GCM**
before writing to disk and decrypts it on load.

### How it works

1. The `encryptionKey` string is hashed with **SHA-256** to produce a 32-byte AES key.
2. A fresh random **16-byte IV** is generated on every `save()` — so two saves of identical
   data produce different ciphertext.
3. GCM provides **authenticated encryption**: if the key is wrong or the file is tampered
   with, decryption throws a `StateError`.

### Usage

```dart
// Create a new encrypted database
final db = await JustDatabase.open(
  'vault',
  mode: DatabaseMode.secure,
  encryptionKey: 'my-secret-passphrase',
);
await db.execute('CREATE TABLE secrets (id INTEGER PRIMARY KEY, value TEXT)');
await db.execute("INSERT INTO secrets VALUES (1, 'top secret')");
await db.close(); // encrypts and writes the .jdb file

// Reopen later — must supply the same passphrase
final db2 = await JustDatabase.open(
  'vault',
  mode: DatabaseMode.secure,
  encryptionKey: 'my-secret-passphrase',
);
final result = await db2.query('SELECT * FROM secrets');
debugPrint(result.rows); // [{id: 1, value: top secret}]
```

### Rules

| Rule | Detail |
|---|---|
| `mode: DatabaseMode.secure` requires `encryptionKey` | Omitting the key throws `ArgumentError` |
| Non-secure modes reject `encryptionKey` | An extra key throws `ArgumentError` |
| Wrong key on reopen | Throws `StateError` — start with a fresh database |
| Key is never stored | Your app must supply it on every `open()` call |
| In-memory only (`persist: false`) | No encryption I/O, but secure mode is still valid |

> **Key management**: the package does not store or derive any default key.
> For production apps derive the key from a user password (e.g. PBKDF2) and store
> *only* the salt (not the key) using [`just_storage`](https://pub.dev/packages/just_storage) —
> a companion package that provides AES-256-GCM encrypted key-value storage with no
> third-party storage wrappers required.

The built-in `SecureKeyManager` handles all of this automatically:

```dart
import 'package:just_database/just_database.dart';

// Derives an AES-256 key from the user's password via PBKDF2-HMAC-SHA256.
// The random salt is generated once and persisted in JustSecureStorage;
// only the salt is stored — the password and key are never written to disk.
final key = await SecureKeyManager.resolveKey(
  dbName:   'vault',
  password: 'user-entered-password',
);

final db = await JustDatabase.open(
  'vault',
  mode: DatabaseMode.secure,
  encryptionKey: key,
);

// To reset (e.g. on password change or database deletion):
await SecureKeyManager.clearSalt(dbName: 'vault');
```

`SecureKeyManager` API:

| Method | Description |
|---|---|
| `resolveKey({dbName, password})` | Returns the hex key; generates and persists a salt on first run |
| `clearSalt({dbName})` | Deletes the stored salt — old key becomes irrecoverable |

---

## ORM Layer

### DbRecord

Extend `DbRecord` for each entity. Implement `toMap()` — do **not** include `id` there.

```dart
class Product extends DbRecord {
  final String name;
  final double price;
  final int    stock;

  const Product({super.id, required this.name, required this.price, this.stock = 0});

  @override
  Map<String, dynamic> toMap() => {'name': name, 'price': price, 'stock': stock};

  Product copyWith({int? id, String? name, double? price, int? stock}) => Product(
    id: id ?? this.id, name: name ?? this.name,
    price: price ?? this.price, stock: stock ?? this.stock,
  );
}
```

### DbColumn

| Factory | SQL type | Options |
|---|---|---|
| `DbColumn.integer(name)` | INTEGER | `notNull`, `unique`, `defaultValue` |
| `DbColumn.text(name)` | TEXT | `notNull`, `unique`, `defaultValue` |
| `DbColumn.real(name)` | REAL | `notNull`, `defaultValue` |
| `DbColumn.boolean(name)` | BOOLEAN | `notNull`, `defaultValue` |
| `DbColumn.datetime(name)` | DATETIME | `notNull`, `defaultValue` |
| `DbColumn.blob(name)` | BLOB | `notNull` |

### DbTable<T> API

```
createTable(db)           — executes CREATE TABLE
dropTable(db)             — executes DROP TABLE
insert(db, record)        — inserts and returns record with id
insertAll(db, records)    — transactional bulk insert
findAll(db, {where, orderBy, descending, limit, offset})
findById(db, id)          — nullable
findWhere(db, where)
findFirst(db, {where, orderBy, descending})
count(db, {where})
update(db, record)        — requires record.id != null
updateWhere(db, values, where)
deleteById(db, id)
deleteWhere(db, where)
deleteAll(db)
rawQuery(db, sql)         — arbitrary SELECT  List<T>
```

---

## Triggers

```dart
await db.execute('''
  CREATE TRIGGER log_insert
  AFTER INSERT ON products
  BEGIN
    INSERT INTO audit_log (action, table_name, row_id)
    VALUES ('INSERT', 'products', NEW.id);
  END
''');

// BEFORE trigger to normalise data
await db.execute('''
  CREATE TRIGGER normalise_email
  BEFORE INSERT ON users
  WHEN NEW.email IS NOT NULL
  BEGIN
    UPDATE users SET email = LOWER(NEW.email) WHERE id = NEW.id;
  END
''');
```

---

## Views

```dart
await db.execute('''
  CREATE VIEW active_users AS
  SELECT id, name, email FROM users WHERE active = 1
''');

final r = await db.query('SELECT * FROM active_users ORDER BY name');
```

---

## Transactions

```dart
// transaction() helper — auto-rollback on exception
await db.transaction((tx) async {
  await tx.execute("INSERT INTO accounts (owner, balance) VALUES ('Alice', 1000)");
  await tx.execute("INSERT INTO accounts (owner, balance) VALUES ('Bob', 500)");
  return null;
});

// Manual control
await db.beginTransaction();
try {
  await db.execute("UPDATE accounts SET balance = balance - 100 WHERE owner = 'Alice'");
  await db.execute("UPDATE accounts SET balance = balance + 100 WHERE owner = 'Bob'");
  await db.commit();
} catch (_) {
  await db.rollback();
}

// Savepoints
await db.beginTransaction();
await db.execute("INSERT INTO items (name) VALUES ('Widget')");
await db.savepoint('sp1');
await db.execute("INSERT INTO items (name) VALUES ('Gadget')");
await db.rollback(savepoint: 'sp1'); // undo only 'Gadget'
await db.commit();                   // 'Widget' is kept
```

---

## Spatial / R-tree

```dart
await db.execute('''
  CREATE TABLE locations (
    id    INTEGER PRIMARY KEY AUTOINCREMENT,
    name  TEXT,
    lat   REAL,
    lng   REAL
  )
''');

await db.execute('CREATE SPATIAL INDEX ON locations (lat, lng)');

await db.execute(
  "INSERT INTO locations (name, lat, lng) VALUES ('Park', 51.5074, -0.1278)",
);

// Distance query
final r = await db.query('''
  SELECT name, ST_DISTANCE(ST_MAKEPOINT(lat, lng), ST_MAKEPOINT(51.5, -0.1)) AS dist
  FROM locations
  ORDER BY dist
  LIMIT 5
''');
```

---

## Query Hints

```dart
// Force a specific index
await db.query('SELECT /*+ INDEX(users idx_age) */ * FROM users WHERE age > 25');

// Skip all indexes (table scan)
await db.query('SELECT /*+ FULL_SCAN */ * FROM users');

// Disable index use
await db.query('SELECT /*+ NO_INDEX */ * FROM products WHERE price < 50');
```

---

## Backup & Restore

```dart
// SQL dump
final sql = await db.exportSql();
await db.importSql(sql); // restore into any database

// JSON snapshot
final json = await db.exportJson();
await db.importJson(json);

// File helpers
final manager = BackupManager(db);
await manager.backupToFile('/path/to/backup.sql');
await manager.restoreFromFile('/path/to/backup.sql');
```

---

## Schema Migrations

```dart
final runner = MigrationRunner(db, migrations: [
  SqlMigration(
    version: 1,
    name: 'create_users',
    upSql: 'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)',
    downSql: 'DROP TABLE users',
  ),
  CallbackMigration(
    version: 2,
    name: 'seed_admin',
    up: (db) async {
      await db.execute("INSERT INTO users (name) VALUES ('Admin')");
    },
    down: (db) async {
      await db.execute("DELETE FROM users WHERE name = 'Admin'");
    },
  ),
]);

await runner.migrate();            // apply all pending
await runner.rollback(toVersion: 1); // rollback to v1
final status = await runner.status(); // see which are applied
```

---

## Benchmarking

```dart
// Built-in standard 8-operation suite
final suite = await db.runStandardBenchmark(
  rowCount:   5000,
  warmup:     5,
  iterations: 100,
);
debugPrint(DatabaseBenchmark.formatTable(suite.results));

// Single query benchmark
final stat = await db.benchmarkQuery(
  'complex join',
  'SELECT u.name, COUNT(o.id) FROM users u LEFT JOIN orders o ON u.id = o.user_id GROUP BY u.id',
  warmup: 3, iterations: 50,
);
debugPrint('avg ${stat.avgMs.toStringAsFixed(2)} ms  p99 ${stat.p99Ms.toStringAsFixed(2)} ms');
```

---

## Built-in Admin UI

Embed a full database management screen in your app with a single widget:

```dart
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_database/ui.dart';

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => DatabaseProvider(),
      child: MaterialApp(
        home: JUDatabaseAdminScreen(
          // Optional: provide seed data shown in each database's popup menu
          onSeedDatabase: (db) async {
            await db.execute("INSERT INTO demo (name) VALUES ('sample')");
          },
          // Optional: custom theme
          // theme: ThemeData(
          //   colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          //   useMaterial3: true,
          // ),
        ),
      ),
    );
  }
}
```

The admin screen has **4 tabs** (Benchmark and Insert Row are accessible from each database card's popup menu):

| Tab | Purpose |
|---|---|
| Databases | Create, open, delete databases; popup menu per card: Open · Insert Row · Benchmark · Seed Sample Data (optional) · Delete |
| Schema | Inspect tables, columns, types, constraints, indexes |
| Query | Full SQL editor, example gallery, query history, result table |
| Settings | Default persistence toggle, default mode, DB stats, engine-feature reference |

---

## SQL Reference

### Statements

```
CREATE TABLE [IF NOT EXISTS] name (col type [constraints], )
CREATE VIEW  [IF NOT EXISTS] name AS select_stmt
CREATE [UNIQUE | SPATIAL] INDEX [IF NOT EXISTS] name ON table (col, )
CREATE TRIGGER name BEFORE|AFTER|INSTEAD OF event ON table [WHEN expr] BEGIN  END

ALTER TABLE name ADD COLUMN col type [constraints]
ALTER TABLE name DROP COLUMN col
ALTER TABLE name RENAME COLUMN old TO new

DROP TABLE  [IF EXISTS] name
DROP VIEW   [IF EXISTS] name
DROP INDEX  [IF EXISTS] name

INSERT INTO name [(cols)] VALUES (vals), 
SELECT [DISTINCT] cols FROM table [JOIN] [WHERE] [GROUP BY] [HAVING] [ORDER BY] [LIMIT] [OFFSET]
UPDATE name SET col=val [WHERE]
DELETE FROM name [WHERE]

BEGIN [DEFERRED | IMMEDIATE]
COMMIT
ROLLBACK [TO SAVEPOINT name]
SAVEPOINT name
RELEASE SAVEPOINT name
```

### Data Types

`INTEGER`  `TEXT` / `VARCHAR`  `REAL` / `FLOAT`  `BOOLEAN`  `DATETIME`  `BLOB`

### Functions

| Category | Functions |
|---|---|
| Aggregate | `COUNT`, `SUM`, `AVG`, `MIN`, `MAX` |
| String | `UPPER`, `LOWER`, `LENGTH`, `SUBSTR`, `TRIM`, `REPLACE`, `CONCAT` |
| Math | `ABS`, `ROUND` |
| Null | `COALESCE`, `IFNULL` |
| Spatial | `ST_MAKEPOINT`, `ST_X`, `ST_Y`, `ST_DISTANCE`, `ST_WITHIN`, `ST_INTERSECTS`, `ST_CONTAINS`, `ST_BBOX` |

### Constraints

`PRIMARY KEY`  `AUTOINCREMENT`  `NOT NULL`  `UNIQUE`  `DEFAULT value`  `FOREIGN KEY  REFERENCES`

---

## API Reference

### `JustDatabase`

```dart
static Future<JustDatabase> open(String name, {
  DatabaseMode mode = DatabaseMode.standard,
  bool persist = true,   // persisted by default
})

Future<QueryResult> query(String sql)
Future<QueryResult> execute(String sql)
QueryBuilder from(String tableName)

// Transactions
Future<T> transaction<T>(Future<T> Function(JustDatabase) action)
Future<QueryResult> beginTransaction({String? mode})
Future<QueryResult> commit()
Future<QueryResult> rollback({String? savepoint})
Future<QueryResult> savepoint(String name)
Future<QueryResult> releaseSavepoint(String name)

// Introspection
List<String> get tableNames
List<String> get viewNames
List<String> get triggerNames
List<String> indexNamesForTable(String tableName)
TableSchema?  getTableSchema(String name)
int get totalRows
int get estimatedSizeBytes

// Benchmarking
Future<BenchmarkSuiteResult> runStandardBenchmark({int rowCount, int warmup, int iterations})
Future<QueryStats>            benchmarkQuery(String label, String sql, {int warmup, int iterations})

Future<void> close()
```

### `QueryResult`

```dart
class QueryResult {
  final bool   success;
  final List<String>              columns;
  final List<Map<String, dynamic>> rows;
  final int    affectedRows;
  final String? errorMessage;
  bool get isEmpty  => rows.isEmpty;
  int  get rowCount => rows.length;
}
```

---

## Contributing

Pull requests are welcome. Please open an issue first to discuss large changes.

## License

BSD 3-Clause License — see [LICENSE](LICENSE).

## Repository

[https://github.com/just-unknown-dev/just-database](https://github.com/just-unknown-dev/just-database)

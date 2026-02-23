# Migration Guide

Guide for upgrading between versions and migrating from other databases.

## Table of Contents

- [Migrating from SQLite](#migrating-from-sqlite)
- [Migrating from Hive](#migrating-from-hive)
- [Migrating from Shared Preferences](#migrating-from-shared-preferences)
- [Version Upgrades](#version-upgrades)
- [Data Format Conversion](#data-format-conversion)
- [Performance Optimization Guide](#performance-optimization-guide)
- [Common Migration Patterns](#common-migration-patterns)
- [Troubleshooting](#troubleshooting)

---

## Migrating from SQLite

### Key Differences

| Feature | SQLite | JustDatabase |
|---------|--------|---------------|
| Implementation | Native C library | Pure Dart |
| Platform support | Requires platform-specific builds | Works everywhere |
| File format | Binary | JSON (when persisted) |
| JOINs | Full support | Full support (INNER, LEFT, RIGHT) |
| Transactions | Full support | Full support (BEGIN/COMMIT/ROLLBACK/SAVEPOINT) |
| Triggers | Supported | Supported (BEFORE/AFTER INSERT/UPDATE/DELETE) |
| Views | Supported | Supported (CREATE VIEW, INSTEAD OF triggers) |

### Migration Steps

1. **Export data from SQLite:**

```dart
// SQLite code
final db = await openDatabase('my_sqlite.db');
final List<Map<String, dynamic>> users = await db.query('users');
```

2. **Import into just_database:**

```dart
final jdb = await JustDatabase.open('my_db');
await jdb.execute('''
  CREATE TABLE users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    email TEXT
  )
''');

for (final user in users) {
  await jdb.execute(
    "INSERT INTO users (id, name, email) VALUES "
    "(${user['id']}, '${user['name']}', '${user['email']}')"
  );
}
```

3. **Update queries:**

```dart
// SQLite with joins
final result = await db.rawQuery('''
  SELECT u.name, p.title 
  FROM users u 
  JOIN posts p ON u.id = p.user_id
''');

// just_database — same syntax works!
final result = await jdb.query('''
  SELECT u.name, p.title
  FROM users u
  INNER JOIN posts p ON u.id = p.user_id
''');
```

### What to Keep in Mind

- ✅ Basic CRUD operations work the same
- ✅ Constraints and indexes are supported
- ✅ JOINs (INNER, LEFT, RIGHT) are fully supported
- ✅ Triggers (BEFORE/AFTER INSERT/UPDATE/DELETE) are supported
- ✅ Views and INSTEAD OF triggers are supported
- ✅ Transactions with savepoints are supported
- ✅ Performance is comparable for most use cases
- ⚠️ Persistence is JSON-based (not binary), so large BLOBs are less efficient

---

## Migrating from Hive

### Key Differences

| Feature | Hive | just_database |
|---------|------|---------------|
| Data model | Key-value / Box | Relational tables |
| Query language | Dart code | SQL |
| Relationships | Manual | Foreign keys |
| Schema | TypeAdapter | SQL DDL |
| Indexing | None / Basic | Advanced with auto-indexing |

### Migration Steps

1. **Export data from Hive:**

```dart
final box = await Hive.openBox<User>('users');
final users = box.values.toList();
```

2. **Create schema in just_database:**

```dart
final db = await JustDatabase.open('my_db');
await db.execute('''
  CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT,
    age INTEGER
  )
''');
```

3. **Import data:**

```dart
for (final user in users) {
  await db.execute(
    "INSERT INTO users (id, name, email, age) VALUES "
    "(${user.id}, '${user.name}', '${user.email}', ${user.age})"
  );
}
```

4. **Update code:**

```dart
// Hive
final user = box.get(userId);
user.name = 'New Name';
await box.put(userId, user);

// just_database
await db.execute("UPDATE users SET name = 'New Name' WHERE id = $userId");
```

### Benefits of Migration

- ✅ More powerful queries with SQL
- ✅ Better support for relationships
- ✅ Automatic indexing and optimization
- ✅ Schema validation and constraints
- ✅ Built-in admin UI

---

## Migrating from Shared Preferences

### When to Migrate

Consider migrating if you have:
- Complex data structures
- Need for queries
- More than 50-100 keys
- Relational data

### Migration Steps

1. **Read existing preferences:**

```dart
final prefs = await SharedPreferences.getInstance();
final users = <Map<String, dynamic>>[];

// Assuming you stored JSON strings
final userKeys = prefs.getKeys()
  .where((k) => k.startsWith('user_'))
  .toList();

for (final key in userKeys) {
  final json = prefs.getString(key);
  users.add(jsonDecode(json!));
}
```

2. **Create database schema:**

```dart
final db = await DatabaseManager.open('app_db', persist: true);
await db.execute('''
  CREATE TABLE users (
    id INTEGER PRIMARY KEY,
    name TEXT,
    email TEXT,
    settings TEXT
  )
''');
```

3. **Import data:**

```dart
for (final user in users) {
  await db.execute(
    "INSERT INTO users (id, name, email) VALUES "
    "(${user['id']}, '${user['name']}', '${user['email']}')"
  );
}
```

4. **Clean up old preferences:**

```dart
for (final key in userKeys) {
  await prefs.remove(key);
}
```

### Code Updates

```dart
// Old: SharedPreferences
final userId = prefs.getInt('current_user_id');
final userName = prefs.getString('user_${userId}_name');

// New: just_database
final result = await db.execute('SELECT * FROM users WHERE id = $userId');
final user = result.rows.first;
final userName = user['name'];
```

---

## Version Upgrades

### 1.0.0 → 1.1.0

This is a **non-breaking** release. No code changes are required for apps that
do not use `DatabaseMode.secure`.

#### New: `DatabaseMode.secure` (opt-in)

Encrypted databases are fully new — existing code is unaffected. To create a
new encrypted database:

```dart
// Fully automatic (no user password) — recommended
final key = await SecureKeyManager.resolveAutoKey(dbName: 'vault');
final db  = await JustDatabase.open('vault',
    mode: DatabaseMode.secure, encryptionKey: key);
```

Or via the Admin UI: set the mode to **Secure** in the Create Database dialog.
The key is generated and stored automatically — no password prompt.

#### Renamed: `Row` → `DatabaseRow`

The internal storage class `Row` was renamed to `DatabaseRow` to avoid
shadowing Flutter’s `Row` widget. This affects you only if you were accessing
`Table.rows` or passing `Table.update` / `Table.delete` callbacks directly:

```dart
// Before (1.0.0)
final List<Row> rows = table.rows;
table.update(values, (Row r) => r.values['active'] == true);

// After (1.1.0)
final List<DatabaseRow> rows = table.rows;
table.update(values, (DatabaseRow r) => r.values['active'] == true);
```

If you had any `import 'package:just_database/just_database.dart' hide Row;`
directive to avoid the Flutter widget conflict, **remove it** — the rename
resolves the ambiguity automatically.

#### New dependencies (transitive — no action required)

| Package | Version | Purpose |
|---|---|---|
| `just_storage` | path dep | Encrypted key-value store for `SecureKeyManager` |
| `encrypt` | `^5.0.3` | AES-256-GCM cipher primitives |
| `crypto` | `^3.0.3` | PBKDF2-HMAC-SHA256 key derivation |

If your app has a direct dependency on any of these, ensure version constraints
are compatible, then run `flutter pub get`.

#### Admin UI — new tabs

The Admin UI now has 6 tabs (previously 4). `JUDatabaseAdminScreen` requires no
constructor changes; the new **Insert** and **Benchmark** tabs are available
automatically.

---

## Data Format Conversion

### Converting Between Persistence Modes

**From In-Memory to Persistent:**

```dart
// 1. Create in-memory database
final memDb = await JustDatabase.open('temp_db', persist: false);
await memDb.execute('CREATE TABLE data (id INTEGER, value TEXT)');
await memDb.execute("INSERT INTO data VALUES (1, 'test')");

// 2. Create persistent database
final persistDb = await DatabaseManager.open(
  'permanent_db',
  persist: true,
);

// 3. Copy schema
for (final tableName in memDb.getTableNames()) {
  final schema = memDb.getTableSchema(tableName)!;
  // Recreate table in persistent DB
  await persistDb.execute(/* CREATE TABLE statement */);
}

// 4. Copy data
final result = await memDb.execute('SELECT * FROM data');
for (final row in result.rows) {
  await persistDb.execute(
    "INSERT INTO data (id, value) VALUES (${row['id']}, '${row['value']}')"
  );
}
```

**From Persistent to In-Memory:**

```dart
// Open existing database (persist: false means in-memory copy)
final memDb = await DatabaseManager.open('saved_db', persist: false);
```

---

## Performance Optimization Guide

### After Migration

1. **Create indexes on frequently queried columns:**

```dart
// SQL-based index creation
await db.execute('CREATE INDEX idx_email ON users (email)');
await db.execute('CREATE UNIQUE INDEX idx_slug ON posts (slug)');
await db.execute('CREATE INDEX idx_dept_sal ON employees (department, salary)');
```

2. **Enable query tracking:**

Query tracking is enabled by default. After ~100 queries with the same pattern, indexes are automatically created.

3. **Check index performance:**

```dart
for (final index in table.indexMetadata) {
  debugPrint('${index.columns}: ${index.hitRatio * 100}% hit rate');
}
```

4. **Choose the right database mode:**

- Use `DatabaseMode.readFast` for read-heavy workloads
- Use `DatabaseMode.writeFast` for write-heavy workloads
- Use `DatabaseMode.standard` for balanced workloads

5. **Monitor query execution times:**

```dart
final result = await db.execute('SELECT * FROM large_table');
debugPrint('Execution time: ${result.executionTime?.inMilliseconds}ms');
```

---

## Common Migration Patterns

### Pattern 1: Batch Import

For large datasets, process in batches:

```dart
const batchSize = 1000;
for (var i = 0; i < oldData.length; i += batchSize) {
  final batch = oldData.skip(i).take(batchSize);
  for (final record in batch) {
    await db.execute(/* INSERT */);
  }
  debugPrint('Processed ${i + batch.length} records');
}
```

### Pattern 2: Schema Validation

Validate migrated data:

```dart
final result = await db.execute('SELECT COUNT(*) as count FROM users');
final newCount = result.rows.first['count'];
debugPrint('Migrated $newCount records (expected: ${oldData.length})');

if (newCount != oldData.length) {
  debugPrint('WARNING: Record count mismatch!');
}
```

### Pattern 3: Gradual Migration

Run both systems in parallel:

```dart
class DualDatabase {
  final oldDb;
  final newDb;
  
  Future<void> write(Map<String, dynamic> data) async {
    await oldDb.write(data);  // Keep old system working
    await newDb.execute(/* INSERT */);  // Populate new system
  }
  
  Future<Map<String, dynamic>> read(int id) async {
    // Read from new system first, fallback to old
    try {
      final result = await newDb.execute('SELECT * FROM data WHERE id = $id');
      return result.rows.first;
    } catch (e) {
      return await oldDb.read(id);
    }
  }
}
```

---

## Troubleshooting

### Migration Issues

**Problem:** Data types don't match

**Solution:** Convert data types during migration:
```dart
// Convert string to integer
final age = int.tryParse(oldUser['age']) ?? 0;
await db.execute("INSERT INTO users (age) VALUES ($age)");
```

**Problem:** Large dataset migration takes too long

**Solution:** Use persistence and process in background:
```dart
final db = await DatabaseManager.open('new_db', persist: true);
// Process in isolate or with periodic UI updates
```

**Problem:** Complex queries don't translate

**Solution:** Break into simpler queries or use Dart for processing:
```dart
final users = await db.execute('SELECT * FROM users');
final result = users.rows.where((u) => /* complex condition */).toList();
```

---

## Getting Help

- 📚 [README](README.md) - Full documentation
- 📖 [API Reference](API.md) - Complete API docs
- 🤝 [Contributing Guide](CONTRIBUTING.md) - How to report bugs and open PRs
- 💬 [Discussions](https://github.com/just-unknown-dev/just-database/discussions)
- 🐛 [Issue tracker](https://github.com/just-unknown-dev/just-database/issues)

---

*Last updated: 2026-02-23*

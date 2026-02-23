# API Reference

Complete API reference for just_database package.

## Table of Contents

- [Core Classes](#core-classes)
- [Database Management](#database-management)
- [Schema & Tables](#schema--tables)
- [Indexing](#indexing)
- [Query Execution](#query-execution)
- [UI Components](#ui-components)

---

## Core Classes

### JustDatabase

Main database class for executing SQL operations.

#### Static factory

```dart
static Future<JustDatabase> open(
  String name, {
  DatabaseMode mode = DatabaseMode.standard,
  bool persist = true,   // persisted to disk by default
  String? encryptionKey, // required when mode == DatabaseMode.secure
})
```
**Parameters:**
- `name` - Database name (case-insensitive)
- `mode` - Concurrency mode (standard, readFast, writeFast, secure)
- `persist` - Write database to local storage. Pass `false` for in-memory only.
- `encryptionKey` - 64-hex-character AES-256 key for `DatabaseMode.secure`. In the Admin UI and most app flows this is supplied automatically by `SecureKeyManager.resolveAutoKey`. For password-protected flows use `SecureKeyManager.resolveKey`. The raw key bytes are never written to disk.

#### Methods

##### execute
```dart
Future<QueryResult> execute(String sql)
```
Executes a SQL statement and returns the result.

**Returns:** `QueryResult` with rows, affected rows count, and execution time

**Throws:** `Exception` if SQL is invalid or execution fails

**Example:**
```dart
final result = await db.execute('SELECT * FROM users WHERE age > 25');
debugPrint(result.rows); // List of Map<String, dynamic>
```

##### getTable
```dart
Table getTable(String name)
```
Gets a table instance for direct manipulation.

**Returns:** `Table` instance

**Throws:** `Exception` if table doesn't exist

##### getTableSchema
```dart
TableSchema? getTableSchema(String name)
```
Gets the schema definition of a table.

**Returns:** `TableSchema` or null if table doesn't exist

##### getTableNames
```dart
List<String> getTableNames()
```
Lists all table names in the database.

**Returns:** List of table name strings

##### close
```dart
Future<void> close()
```
Closes the database and flushes to disk if `persist` is true.

#### Additional getters

```dart
List<String> triggerNames          // Names of all triggers defined in the database
List<String> viewNames             // Names of all views
List<String> indexNamesForTable(String tableName)  // Index names for a table
int          totalRows             // Sum of row counts across all tables
int          estimatedSizeBytes    // Estimated in-memory + persisted size in bytes
```

#### Benchmark helpers

```dart
Future<BenchmarkSuiteResult> runStandardBenchmark({
  int rowCount   = 10000,
  int warmup     = 3,
  int iterations = 10,
})
```
Runs the 8-operation standard benchmark suite (INSERT, SELECT, filtered SELECT,
INDEX, sorted SELECT, UPDATE, DELETE, aggregate) and returns a
`BenchmarkSuiteResult`.

```dart
Future<QueryStats> benchmarkQuery(
  String label,
  String sql, {
  int warmup     = 3,
  int iterations = 10,
})
```
Benchmarks a single SQL statement and returns `QueryStats`
(avg / min / max / p95 / p99 / ops-per-sec).

---

## ORM Layer

### DbRecord

Base class for all ORM model classes.

```dart
abstract class DbRecord {
  final int? id;          // null for unsaved records
  Map<String, dynamic> toMap();  // all non-id fields
}
```

### DbColumn

Describes a single column.

| Factory | SQL type | Options |
|---|---|---|
| `DbColumn.integer(name)` | INTEGER | `notNull`, `unique`, `defaultValue` |
| `DbColumn.text(name)` | TEXT | `notNull`, `unique`, `defaultValue` |
| `DbColumn.real(name)` | REAL | `notNull`, `defaultValue` |
| `DbColumn.boolean(name)` | BOOLEAN | `notNull`, `defaultValue` |
| `DbColumn.datetime(name)` | DATETIME | `notNull`, `defaultValue` |
| `DbColumn.blob(name)` | BLOB | `notNull` |

Each column also exposes `toSql()` returning its DDL fragment.

### DbTable\<T extends DbRecord\>

Abstract accessor — extend one per entity.

**Abstract members to implement:**
- `String get tableName` — SQL table name
- `List<DbColumn> get columns` — all columns except `id`
- `T fromRow(Map<String, dynamic> row)` — row mapper

**DDL**
```dart
String createTableSql({bool ifNotExists = true})
Future<void> createTable(JustDatabase db, {bool ifNotExists = true})
Future<void> dropTable(JustDatabase db, {bool ifExists = true})
```

**INSERT**
```dart
Future<T>       insert(JustDatabase db, T record)              // returns record with id
Future<List<T>> insertAll(JustDatabase db, List<T> records)   // transactional bulk
```

**SELECT**
```dart
Future<List<T>> findAll(JustDatabase db, {
  String? where, String? orderBy,
  bool descending = false, int? limit, int? offset,
})
Future<T?>      findById(JustDatabase db, int id)
Future<List<T>> findWhere(JustDatabase db, String where)
Future<T?>      findFirst(JustDatabase db, {String? where, String? orderBy, bool descending})
Future<int>     count(JustDatabase db, {String? where})
```

**UPDATE**
```dart
Future<int> update(JustDatabase db, T record)                           // by id
Future<int> updateWhere(JustDatabase db, Map<String,dynamic> values, String where)
```

**DELETE**
```dart
Future<int> deleteById(JustDatabase db, int id)
Future<int> deleteWhere(JustDatabase db, String where)
Future<int> deleteAll(JustDatabase db)
```

**RAW**
```dart
Future<List<T>> rawQuery(JustDatabase db, String sql)
```

### DbTableException

```dart
class DbTableException implements Exception {
  final String message;
}
```

Thrown by any `DbTable` operation that receives a failed `QueryResult`.

---

## Secure Key Management

### SecureKeyManager

Manages the lifecycle of AES-256 encryption keys for `DatabaseMode.secure`
databases. Re-exported from the barrel (`just_database.dart`). All methods are
`static`; the class cannot be instantiated.

#### Password-based API (PBKDF2)

```dart
static Future<String> resolveKey({
  required String dbName,
  required String password,
})
```
Derives a 256-bit AES key from `password` via **PBKDF2-HMAC-SHA256**
(100 000 iterations, 16-byte random salt). The random salt is generated on
first call and stored in `JustSecureStorage`. On every subsequent call the
stored salt is fetched and the same password produces the same key.
The password is **never** written to disk.

Throws `ArgumentError` if `password` is empty.

```dart
static Future<void> clearSalt({required String dbName})
```
Deletes the persisted salt for `dbName`. After this call `resolveKey` will
generate a fresh salt, making the old derived key **irrecoverable**. Call this
before deleting or resetting an encrypted database.

#### Automatic API (no user password)

```dart
static Future<String> resolveAutoKey({required String dbName})
```
Generates a cryptographically random 32-byte key with `Random.secure()`,
persists it in `JustSecureStorage` (AES-256-GCM encrypted by `just_storage`),
and returns it on every subsequent call. No user interaction is required.

This is what the Admin UI uses internally — encryption is fully transparent.

```dart
static Future<void> clearAutoKey({required String dbName})
```
Deletes the auto-managed key for `dbName` from secure storage. Called
automatically by `DatabaseProvider.deleteDatabase`.

**Storage key scheme:**

| Purpose | Key stored under |
|---|---|
| PBKDF2 salt | `just_database_salt_<dbName>` |
| Auto key | `just_database_auto_key_<dbName>` |

**Example — password-based:**
```dart
final key = await SecureKeyManager.resolveKey(
  dbName: 'vault',
  password: 'user-entered-password',
);
final db = await JustDatabase.open(
  'vault',
  mode: DatabaseMode.secure,
  encryptionKey: key,
);
```

**Example — fully automatic:**
```dart
final key = await SecureKeyManager.resolveAutoKey(dbName: 'vault');
final db = await JustDatabase.open(
  'vault',
  mode: DatabaseMode.secure,
  encryptionKey: key,
);
```

---

## Database Management

### DatabaseManager

Static registry for managing multiple `JustDatabase` instances across the app.

#### Methods

##### open
```dart
static Future<JustDatabase> open(
  String name, {
  DatabaseMode mode = DatabaseMode.standard,
  bool persist = true,
  String? encryptionKey, // required for DatabaseMode.secure
})
```
Opens or creates a database and registers it in the manager.

**Parameters:**
- `name` - Unique database name (case-insensitive)
- `mode` - Concurrency mode
- `persist` - Write to local storage (default `true`)
- `encryptionKey` - 64-hex AES-256 key for `DatabaseMode.secure`. Obtain via `SecureKeyManager.resolveAutoKey` (automatic) or `SecureKeyManager.resolveKey` (password-based).

**Returns:** `JustDatabase` instance

##### getOpenDatabase
```dart
static JustDatabase? getOpenDatabase(String name)
```
Returns an already-open database, or `null` if not registered.

##### listDatabases
```dart
static Future<List<DatabaseInfo>> listDatabases()
```
Lists all databases (open and persisted-but-closed).

**Returns:** List of `DatabaseInfo` snapshots

##### close
```dart
static Future<void> close(String name)
```
Closes the named database and flushes to disk if persisted.

##### closeAll
```dart
static Future<void> closeAll()
```
Closes every currently-open database.

##### deleteDatabase
```dart
static Future<void> deleteDatabase(String name)
```
Closes and permanently deletes a database and its backing file.

##### deleteAll
```dart
static Future<void> deleteAll()
```
Deletes every managed database.

---

### DatabaseInfo

Read-only snapshot of a database (open or persisted-closed).

```dart
String       name            // Database name
bool         isOpen          // Whether currently open in memory
bool         isPersisted     // Whether a backing file exists on disk
DatabaseMode mode            // Concurrency mode
int          sizeBytes       // Estimated size in bytes
String       formattedSize   // Human-readable, e.g. "1.5 MB"
int          tableCount      // Number of tables (0 if not open)
int          totalRows       // Total rows across all tables (0 if not open)
```

---

### DatabaseMode

Enum representing concurrency and write strategies.

```dart
enum DatabaseMode {
  standard,   // Balanced read/write with mutex locks (recommended default)
  readFast,   // Many concurrent readers, exclusive writers — optimise for heavy reads
  writeFast,  // Buffered writes, batch commits every 100 ms — optimise for heavy writes
  secure,     // AES-256-GCM encryption at rest; per-save random IV; supply encryptionKey
              // via SecureKeyManager — the Admin UI handles this automatically
}
```

---

## Schema & Tables

### Table

Represents a database table.

#### Properties

```dart
String name                       // Table name
TableSchema schema                // Schema definition
List<DatabaseRow> rows            // All rows in the table
int rowCount                      // Number of rows
List<IndexMetadata> indexMetadata // Index information
```

#### Methods

##### createIndex
```dart
void createIndex(String column, IndexType type)
```
Creates an index on a single column.

**Parameters:**
- `column` - Column name to index
- `type` - Index type (hash, btree, auto)

##### createCompositeIndex
```dart
void createCompositeIndex(List<String> columns, IndexType type)
```
Creates an index on multiple columns.

**Parameters:**
- `columns` - List of column names
- `type` - Index type

**Example:**
```dart
table.createCompositeIndex(['user_id', 'created_at'], IndexType.btree);
```

##### createAutoIndex
```dart
void createAutoIndex(String column)
```
Creates an automatically managed index.

##### getIndexForColumns
```dart
TableIndex? getIndexForColumns(List<String> columns)
```
Finds an existing index for columns.

**Returns:** `TableIndex` or null

##### removeIndex
```dart
void removeIndex(String column)
```
Removes an index by column name.

##### insert
```dart
InsertResult insert(Map<String, dynamic> values)
```
Directly inserts a row (bypassing SQL).

**Returns:** `InsertResult` with row ID

##### update
```dart
int update(Map<String, dynamic> values, bool Function(DatabaseRow) where)
```
Updates rows matching condition.

**Returns:** Number of rows updated

##### delete
```dart
int delete(bool Function(DatabaseRow) where)
```
Deletes rows matching condition.

**Returns:** Number of rows deleted

---

### TableSchema

Defines table structure.

#### Properties

```dart
String name                              // Table name
List<ColumnSchema> columns               // Column definitions
List<TableConstraint> tableConstraints   // Table-level constraints
List<String> primaryKeyColumns           // Primary key column names
List<TableConstraint> uniqueConstraints  // UNIQUE constraints
```

#### Methods

##### hasColumn
```dart
bool hasColumn(String name)
```
Checks if column exists.

##### getColumn
```dart
ColumnSchema? getColumn(String name)
```
Gets column definition.

---

### ColumnSchema

Defines a table column.

#### Properties

```dart
String name                    // Column name
DataType type                  // Data type
bool isPrimaryKey              // Is primary key
bool isAutoIncrement           // Auto-incrementing
bool isUnique                  // Has unique constraint
bool isNotNull                 // NOT NULL constraint
dynamic defaultValue           // Default value
String? foreignKeyTable        // Foreign key table
String? foreignKeyColumn       // Foreign key column
```

---

### TableConstraint

Table-level constraint definition.

```dart
class TableConstraint {
  TableConstraintType type;     // PRIMARY KEY or UNIQUE
  List<String> columns;         // Affected columns
}
```

---

## Indexing

### IndexType

Enum for index types.

```dart
enum IndexType {
  hash,   // Hash index — O(1) equality lookups
  btree,  // B-tree index — range queries
  auto,   // Automatically managed based on query patterns
}
```

---

### IndexMetadata

Information about an index.

#### Properties

```dart
List<String> columns        // Indexed columns
IndexType type              // Index type
int lookupCount             // Total lookups performed
int hitCount                // Cache/index hits
double hitRatio             // Hit rate (0.0 to 1.0)
DateTime createdAt          // Creation timestamp
DateTime lastUsedAt         // Last usage timestamp
```

---

### TableIndex

Internal index structure (usually not accessed directly).

#### Constructor

```dart
// Single column index
TableIndex(String column, IndexType type)

// Composite index
TableIndex.composite(List<String> columns, IndexType type)
```

---

## Query Execution

### QueryResult

Result of a SQL query.

#### Properties

```dart
List<Map<String, dynamic>> rows   // Result rows
int affectedRows                   // Rows affected (INSERT/UPDATE/DELETE)
String? message                    // Status message
Duration? executionTime            // Query execution time
```

---

### QueryTracker

Tracks query patterns for auto-indexing (internal).

#### Methods

##### recordColumnUsage
```dart
void recordColumnUsage(String tableName, String column)
```
Records a single column usage.

##### recordCompositeUsage
```dart
void recordCompositeUsage(String tableName, List<String> columns)
```
Records composite column usage.

##### getColumnsNeedingIndex
```dart
Map<String, Set<String>> getColumnsNeedingIndex()
```
Returns columns that should be indexed.

**Returns:** Map of table name to set of columns

---

## UI Components

### JUDatabaseAdminScreen

Main admin screen widget. Provides a 4-tab UI: **Databases · Schema · Query · Settings**.

#### Constructor

```dart
JUDatabaseAdminScreen({
  Key? key,
  ThemeData? theme,
  SeedDatabaseCallback? onSeedDatabase,
})
```

**Parameters:**
- `theme` - Optional custom `ThemeData`
- `onSeedDatabase` - Optional seed-data callback. When provided, a **Seed Sample Data** option appears in each database's popup menu.

#### Tabs

| Tab | Purpose |
|---|---|
| Databases | Create / open / delete databases; `SEC` badge for encrypted databases; seed data; per-database benchmark shortcut |
| Schema | Browse tables, views, columns, indexes and rows; direct row insert |
| Insert | Dynamic form driven by the live table schema — per-column widgets (text, number, boolean switch, date picker); inline validation |
| Query | Run raw SQL; history list; paginated results table |
| Benchmark | 8-op standard suite runner + single custom-query benchmark; throughput bar chart; p95/p99/ops-per-sec stat cards |
| Settings | Live DB stats grid; engine-feature reference tiles; default mode & persistence toggles; About card |

#### SeedDatabaseCallback typedef

```dart
typedef SeedDatabaseCallback = Future<void> Function(JustDatabase db);
```

**Example:**
```dart
JUDatabaseAdminScreen(
  theme: ThemeData.dark(),
  onSeedDatabase: (db) async {
    final table = UserTable();
    await table.createTable(db);
    await table.insertAll(db, sampleUsers);
  },
)
```

---

### DatabaseProvider

Flutter `ChangeNotifier` — place above `JUDatabaseAdminScreen` in the widget tree.

#### Properties

```dart
List<DatabaseInfo> databases        // All known databases
JustDatabase? currentDatabase       // Currently selected database
DatabaseMode defaultMode            // Default mode for new databases
bool persistEnabled                 // Default persistence flag for new databases
QueryResult? lastQueryResult        // Last query result
String? lastError                   // Last error message
bool isLoading                      // True while any async operation is running
List<String> queryHistory           // Up to 50 most recent SQL statements
bool hasDatabaseOpen                // Convenience: currentDatabase != null
```

#### Methods

```dart
Future<void> refreshDatabases()
Future<void> createDatabase(String name, {DatabaseMode? mode, bool? persist})
Future<void> selectDatabase(String name)
Future<void> deleteDatabase(String name)
Future<void> runQuery(String sql)
void         setDefaultMode(DatabaseMode mode)
void         setPersistEnabled(bool value)
Future<void> clearAllDatabases()
```

**`createDatabase` notes:**
- `mode` defaults to `defaultMode`
- `persist` defaults to `persistEnabled` (the global default), but can be overridden per-database
- For `DatabaseMode.secure`, the AES-256 key is generated and stored automatically via `SecureKeyManager.resolveAutoKey` — no `encryptionKey` parameter is exposed
- `selectDatabase` similarly calls `SecureKeyManager.resolveAutoKey` transparently when opening a secure database
- `deleteDatabase` calls `SecureKeyManager.clearAutoKey` before removing the database

---

### DatabasesTab

```dart
class DatabasesTab extends StatelessWidget {
  final Future<void> Function(JustDatabase db)? seedCallback;
  const DatabasesTab({super.key, this.seedCallback});
}
```

Normally constructed by `JUDatabaseAdminScreen` — `seedCallback` is forwarded from `onSeedDatabase`.

---

### SchemaTab · QueryEditorTab · SettingsTab

All `const` widgets; no public parameters.

```dart
const SchemaTab({Key? key})
const QueryEditorTab({Key? key})
const SettingsTab({Key? key})
```

## Data Types

### DataType

Enum for SQL data types.

```dart
enum DataType {
  integer,   // Whole numbers
  real,      // Floating-point numbers
  text,      // Strings
  boolean,   // True/false
  blob,      // Binary data (hex-string in SQL)
  datetime,  // Date and time values (ISO-8601 string in SQL)
}
```

---

## SQL Support

### Supported Statements

- **CREATE TABLE** - With constraints
- **ALTER TABLE** - ADD COLUMN, DROP COLUMN, RENAME COLUMN
- **DROP TABLE** - Delete table
- **INSERT INTO** - Add rows
- **SELECT** - Query data (with WHERE, ORDER BY, LIMIT, GROUP BY, HAVING, DISTINCT)
- **JOIN** - INNER JOIN, LEFT JOIN, RIGHT JOIN
- **UPDATE** - Modify rows
- **DELETE** - Remove rows

### JOIN Operations

#### INNER JOIN
Returns only matching rows from both tables:

```dart
await db.execute('''
  SELECT orders.id, customers.name, orders.total
  FROM orders
  INNER JOIN customers ON orders.customer_id = customers.id
''');
```

#### LEFT JOIN
Returns all rows from left table, with matching rows from right table (null if no match):

```dart
await db.execute('''
  SELECT customers.name, orders.total
  FROM customers
  LEFT JOIN orders ON customers.id = orders.customer_id
''');
```

#### RIGHT JOIN
Returns all rows from right table, with matching rows from left table (null if no match):

```dart
await db.execute('''
  SELECT customers.name, orders.total
  FROM orders
  RIGHT JOIN customers ON orders.customer_id = customers.id
''');
```

### Aggregate Functions

#### COUNT
Count rows or non-null values:

```dart
// Count all rows
await db.execute('SELECT COUNT(*) as total FROM users');

// Count non-null values
await db.execute('SELECT COUNT(email) as with_email FROM users');
```

#### SUM
Sum numeric values:

```dart
await db.execute('SELECT SUM(price) as total_price FROM products');
```

#### AVG
Calculate average:

```dart
await db.execute('SELECT AVG(age) as average_age FROM users');
```

#### MIN and MAX
Find minimum and maximum values:

```dart
await db.execute('SELECT MIN(price) as min, MAX(price) as max FROM products');
```

### GROUP BY and HAVING

Group rows and filter groups:

```dart
// Group by single column
await db.execute('''
  SELECT category, COUNT(*) as count, AVG(price) as avg_price
  FROM products
  GROUP BY category
''');

// Group by multiple columns
await db.execute('''
  SELECT category, brand, COUNT(*) as count
  FROM products
  GROUP BY category, brand
''');

// Filter groups with HAVING
await db.execute('''
  SELECT category, COUNT(*) as count
  FROM products
  GROUP BY category
  HAVING COUNT(*) > 10
''');
```

### ALTER TABLE Operations

#### ADD COLUMN
```dart
// Add column
await db.execute('ALTER TABLE users ADD COLUMN phone TEXT');

// Add with default
await db.execute('ALTER TABLE users ADD COLUMN status TEXT DEFAULT \\'active\\'');
```

#### DROP COLUMN
```dart
await db.execute('ALTER TABLE users DROP COLUMN phone');
```

#### RENAME COLUMN
```dart
await db.execute('ALTER TABLE users RENAME COLUMN name TO full_name');
```

### Supported Constraints

- **PRIMARY KEY** - Single or composite
- **UNIQUE** - Single or composite
- **FOREIGN KEY** - With automatic indexing
- **NOT NULL** - Required fields
- **DEFAULT** - Default values
- **AUTOINCREMENT** - Auto-incrementing integers

### Supported Operators

- **Comparison:** `=`, `!=`, `<`, `<=`, `>`, `>=`
- **Logical:** `AND`, `OR`, `NOT`
- **Pattern:** `LIKE`
- **Null:** `IS NULL`, `IS NOT NULL`

---

## Error Handling

All async methods may throw exceptions. Always use try-catch:

```dart
try {
  await db.execute('SELECT * FROM nonexistent');
} catch (e) {
  debugPrint('Error: $e');
}
```

Common exceptions:
- SQL syntax errors
- Table/column not found
- Constraint violations
- Type mismatches

---

## Best Practices

1. **Use indexes** for frequently queried columns
2. **Enable persistence** for data that should survive app restarts
3. **Choose appropriate mode** based on workload
4. **Monitor index metadata** to optimize performance
5. **Use composite indexes** for multi-column queries
6. **Close databases** when done to free resources

---

For more examples and guides, see the [README](README.md) and [example](example/) directory.

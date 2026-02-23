import '../core/database.dart';
import '../sql/executor.dart';

// =============================================================================
// DbRecord
// =============================================================================

/// Base class for every record managed by a [DbTable].
///
/// Extend this class for each entity and implement [toMap()].
///
/// ```dart
/// class User extends DbRecord {
///   final String name;
///   final int    age;
///
///   const User({super.id, required this.name, required this.age});
///
///   @override
///   Map<String, dynamic> toMap() => {'name': name, 'age': age};
///
///   User copyWith({int? id, String? name, int? age}) => User(
///     id:   id   ?? this.id,
///     name: name ?? this.name,
///     age:  age  ?? this.age,
///   );
/// }
/// ```
abstract class DbRecord {
  /// Primary-key assigned by the database, or `null` for unsaved records.
  final int? id;

  const DbRecord({this.id});

  /// Serialise all non-id fields to a column-name  value map.
  ///
  /// Do **not** include `id` — it is managed automatically by [DbTable].
  Map<String, dynamic> toMap();
}

// =============================================================================
// DbColumn
// =============================================================================

/// Describes a single column in a [DbTable].
///
/// Use the named factory constructors to create columns:
/// ```dart
/// DbColumn.text('name',    notNull: true)
/// DbColumn.integer('age',  defaultValue: 0)
/// DbColumn.real('score')
/// DbColumn.boolean('flag', defaultValue: false)
/// DbColumn.datetime('created_at')
/// DbColumn.blob('data')
/// ```
class DbColumn {
  /// Column name (used verbatim in SQL).
  final String name;

  final String _sqlType;

  /// Whether `NOT NULL` is added to the column definition.
  final bool notNull;

  /// Whether `UNIQUE` is added to the column definition.
  final bool unique;

  /// Optional `DEFAULT` value in the column definition.
  final dynamic defaultValue;

  const DbColumn._({
    required this.name,
    required String sqlType,
    this.notNull = false,
    this.unique = false,
    this.defaultValue,
  }) : _sqlType = sqlType;

  // --------------------------------------------------------------------------
  // Factories
  // --------------------------------------------------------------------------

  /// An `INTEGER` column.
  factory DbColumn.integer(
    String name, {
    bool notNull = false,
    bool unique = false,
    int? defaultValue,
  }) => DbColumn._(
    name: name,
    sqlType: 'INTEGER',
    notNull: notNull,
    unique: unique,
    defaultValue: defaultValue,
  );

  /// A `TEXT` column.
  factory DbColumn.text(
    String name, {
    bool notNull = false,
    bool unique = false,
    String? defaultValue,
  }) => DbColumn._(
    name: name,
    sqlType: 'TEXT',
    notNull: notNull,
    unique: unique,
    defaultValue: defaultValue,
  );

  /// A `REAL` (double) column.
  factory DbColumn.real(
    String name, {
    bool notNull = false,
    double? defaultValue,
  }) => DbColumn._(
    name: name,
    sqlType: 'REAL',
    notNull: notNull,
    defaultValue: defaultValue,
  );

  /// A `BOOLEAN` column (stored as 0/1).
  factory DbColumn.boolean(
    String name, {
    bool notNull = false,
    bool? defaultValue,
  }) => DbColumn._(
    name: name,
    sqlType: 'BOOLEAN',
    notNull: notNull,
    defaultValue: defaultValue,
  );

  /// A `DATETIME` column.
  factory DbColumn.datetime(
    String name, {
    bool notNull = false,
    DateTime? defaultValue,
  }) => DbColumn._(
    name: name,
    sqlType: 'DATETIME',
    notNull: notNull,
    defaultValue: defaultValue,
  );

  /// A `BLOB` column.
  factory DbColumn.blob(String name, {bool notNull = false}) =>
      DbColumn._(name: name, sqlType: 'BLOB', notNull: notNull);

  // --------------------------------------------------------------------------
  // DDL
  // --------------------------------------------------------------------------

  /// Returns the column DDL fragment, e.g. `"name TEXT NOT NULL DEFAULT 'x'"`.
  String toSql() {
    final buf = StringBuffer('$name $_sqlType');
    if (notNull) buf.write(' NOT NULL');
    if (unique) buf.write(' UNIQUE');
    if (defaultValue != null) {
      buf.write(' DEFAULT ${_sqlLiteral(defaultValue)}');
    }
    return buf.toString();
  }

  @override
  String toString() => toSql();
}

// =============================================================================
// DbTable<T>
// =============================================================================

/// Type-safe table accessor — extend once per entity to get full CRUD.
///
/// ### Defining a table
/// ```dart
/// class UserTable extends DbTable<User> {
///   @override
///   String get tableName => 'users';
///
///   @override
///   List<DbColumn> get columns => [
///     DbColumn.text('name',    notNull: true),
///     DbColumn.integer('age',  defaultValue: 0),
///     DbColumn.boolean('active', defaultValue: true),
///   ];
///
///   @override
///   User fromRow(Map<String, dynamic> row) => User(
///     id:     row['id']     as int?,
///     name:   row['name']   as String,
///     age:    row['age']    as int?  ?? 0,
///     active: row['active'] as bool? ?? true,
///   );
/// }
/// ```
///
/// ### Usage
/// ```dart
/// final db    = await JustDatabase.open('mydb');
/// final users = UserTable();
///
/// await users.createTable(db);
///
/// final alice = await users.insert(db, User(name: 'Alice', age: 30));
/// // alice.id is populated from the database
///
/// final all   = await users.findAll(db);
/// final byId  = await users.findById(db, alice.id!);
/// final young = await users.findWhere(db, 'age < 25');
/// final total = await users.count(db);
///
/// await users.update(db, alice.copyWith(age: 31));
/// await users.deleteById(db, alice.id!);
/// ```
abstract class DbTable<T extends DbRecord> {
  // --------------------------------------------------------------------------
  // Abstract interface — override these three members
  // --------------------------------------------------------------------------

  /// SQL table name.
  String get tableName;

  /// Column definitions, **excluding** `id`.
  ///
  /// `id INTEGER PRIMARY KEY AUTOINCREMENT` is always prepended automatically.
  List<DbColumn> get columns;

  /// Maps a raw result row (`Map<String, dynamic>`) to a typed [T] instance.
  T fromRow(Map<String, dynamic> row);

  // --------------------------------------------------------------------------
  // DDL helpers
  // --------------------------------------------------------------------------

  /// Returns the full `CREATE TABLE` SQL string.
  String createTableSql({bool ifNotExists = true}) {
    final guard = ifNotExists ? 'IF NOT EXISTS ' : '';
    final colDefs = [
      'id INTEGER PRIMARY KEY AUTOINCREMENT',
      ...columns.map((c) => c.toSql()),
    ].join(', ');
    return 'CREATE TABLE $guard$tableName ($colDefs)';
  }

  /// Executes `CREATE TABLE` on [db].
  Future<void> createTable(JustDatabase db, {bool ifNotExists = true}) async {
    _check(
      await db.execute(createTableSql(ifNotExists: ifNotExists)),
      'createTable',
    );
  }

  /// Executes `DROP TABLE` on [db].
  Future<void> dropTable(JustDatabase db, {bool ifExists = true}) async {
    final guard = ifExists ? 'IF EXISTS ' : '';
    _check(await db.execute('DROP TABLE $guard$tableName'), 'dropTable');
  }

  // --------------------------------------------------------------------------
  // INSERT
  // --------------------------------------------------------------------------

  /// Inserts [record] and returns it with [DbRecord.id] populated from the DB.
  Future<T> insert(JustDatabase db, T record) async {
    final map = record.toMap();
    final cols = map.keys.join(', ');
    final vals = map.values.map(_sqlLiteral).join(', ');
    _check(
      await db.execute('INSERT INTO $tableName ($cols) VALUES ($vals)'),
      'insert',
    );
    // Re-fetch the row we just inserted (highest id in a single-writer engine).
    final r = await db.query(
      'SELECT * FROM $tableName ORDER BY id DESC LIMIT 1',
    );
    _check(r, 'insert (re-fetch)');
    if (r.rows.isEmpty) {
      throw const DbTableException('insert: re-fetch returned no rows');
    }
    return fromRow(r.rows.first);
  }

  /// Inserts multiple [records] in a single transaction and returns them all
  /// with their new ids.
  Future<List<T>> insertAll(JustDatabase db, List<T> records) async {
    final saved = <T>[];
    await db.transaction((tx) async {
      for (final rec in records) {
        saved.add(await insert(tx, rec));
      }
      return null;
    });
    return saved;
  }

  // --------------------------------------------------------------------------
  // SELECT
  // --------------------------------------------------------------------------

  /// Returns rows, optionally filtered / ordered / paginated.
  ///
  /// ```dart
  /// users.findAll(db, where: 'age > 18', orderBy: 'name', limit: 20)
  /// ```
  Future<List<T>> findAll(
    JustDatabase db, {
    String? where,
    String? orderBy,
    bool descending = false,
    int? limit,
    int? offset,
  }) async {
    final buf = StringBuffer('SELECT * FROM $tableName');
    if (where != null) buf.write(' WHERE $where');
    if (orderBy != null) {
      buf.write(' ORDER BY $orderBy');
      if (descending) buf.write(' DESC');
    }
    if (limit != null) buf.write(' LIMIT $limit');
    if (offset != null) buf.write(' OFFSET $offset');
    return _toList(await db.query(buf.toString()), 'findAll');
  }

  /// Returns the row with the given [id], or `null` if not found.
  Future<T?> findById(JustDatabase db, int id) async {
    final r = await db.query(
      'SELECT * FROM $tableName WHERE id = $id LIMIT 1',
    );
    _check(r, 'findById');
    return r.rows.isEmpty ? null : fromRow(r.rows.first);
  }

  /// Returns all rows matching a raw SQL [where] clause.
  Future<List<T>> findWhere(JustDatabase db, String where) =>
      findAll(db, where: where);

  /// Returns the first matching row, or `null`.
  Future<T?> findFirst(
    JustDatabase db, {
    String? where,
    String? orderBy,
    bool descending = false,
  }) async {
    final rows = await findAll(
      db,
      where: where,
      orderBy: orderBy,
      descending: descending,
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  // --------------------------------------------------------------------------
  // Aggregates
  // --------------------------------------------------------------------------

  /// Returns the row count (optionally filtered by [where]).
  Future<int> count(JustDatabase db, {String? where}) async {
    final buf = StringBuffer('SELECT COUNT(*) AS n FROM $tableName');
    if (where != null) buf.write(' WHERE $where');
    final r = await db.query(buf.toString());
    _check(r, 'count');
    return (r.rows.firstOrNull?['n'] as int?) ?? 0;
  }

  // --------------------------------------------------------------------------
  // UPDATE
  // --------------------------------------------------------------------------

  /// Updates the row matching [record.id]. Throws if `record.id` is `null`.
  Future<int> update(JustDatabase db, T record) async {
    if (record.id == null) {
      throw const DbTableException('update() requires a non-null record.id');
    }
    final set = record
        .toMap()
        .entries
        .map((e) => '${e.key} = ${_sqlLiteral(e.value)}')
        .join(', ');
    final r = await db.execute(
      'UPDATE $tableName SET $set WHERE id = ${record.id}',
    );
    _check(r, 'update');
    return r.affectedRows;
  }

  /// Updates all rows matching [where] with the supplied [values].
  ///
  /// ```dart
  /// users.updateWhere(db, {'active': false}, 'age < 13')
  /// ```
  Future<int> updateWhere(
    JustDatabase db,
    Map<String, dynamic> values,
    String where,
  ) async {
    final set = values.entries
        .map((e) => '${e.key} = ${_sqlLiteral(e.value)}')
        .join(', ');
    final r = await db.execute('UPDATE $tableName SET $set WHERE $where');
    _check(r, 'updateWhere');
    return r.affectedRows;
  }

  // --------------------------------------------------------------------------
  // DELETE
  // --------------------------------------------------------------------------

  /// Deletes the row with the given [id]. Returns rows removed (0 or 1).
  Future<int> deleteById(JustDatabase db, int id) async {
    final r = await db.execute('DELETE FROM $tableName WHERE id = $id');
    _check(r, 'deleteById');
    return r.affectedRows;
  }

  /// Deletes rows matching a raw SQL [where] clause.
  Future<int> deleteWhere(JustDatabase db, String where) async {
    final r = await db.execute('DELETE FROM $tableName WHERE $where');
    _check(r, 'deleteWhere');
    return r.affectedRows;
  }

  /// Deletes every row in the table. Returns the number of rows removed.
  Future<int> deleteAll(JustDatabase db) async {
    final r = await db.execute('DELETE FROM $tableName');
    _check(r, 'deleteAll');
    return r.affectedRows;
  }

  // --------------------------------------------------------------------------
  // Raw query
  // --------------------------------------------------------------------------

  /// Executes an arbitrary SELECT [sql] and maps every result row to [T].
  Future<List<T>> rawQuery(JustDatabase db, String sql) async =>
      _toList(await db.query(sql), 'rawQuery');

  // --------------------------------------------------------------------------
  // Internal helpers
  // --------------------------------------------------------------------------

  List<T> _toList(QueryResult r, String op) {
    _check(r, op);
    return r.rows.map(fromRow).toList();
  }

  static void _check(QueryResult r, String op) {
    if (!r.success) throw DbTableException('$op failed: ${r.errorMessage}');
  }
}

// =============================================================================
// DbTableException
// =============================================================================

/// Thrown when a [DbTable] operation fails.
class DbTableException implements Exception {
  final String message;

  const DbTableException(this.message);

  @override
  String toString() => 'DbTableException: $message';
}

// =============================================================================
// Internal: SQL literal encoding
// =============================================================================

/// Encodes a Dart value as a SQL literal string.
///
/// | Dart type      | SQL output                       |
/// |----------------|----------------------------------|
/// | `null`         | `NULL`                           |
/// | `bool`         | `1` / `0`                        |
/// | `num`          | digits as-is                     |
/// | `DateTime`     | ISO-8601 text literal            |
/// | `List<int>`    | `X'...'` hex blob literal        |
/// | `String`       | single-quoted, `'` escaped as `''` |
String _sqlLiteral(dynamic v) {
  if (v == null) return 'NULL';
  if (v is bool) return v ? '1' : '0';
  if (v is num) return '$v';
  if (v is DateTime) return "'${v.toIso8601String()}'";
  if (v is List<int>) {
    final hex = v.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return "X'$hex'";
  }
  return "'${v.toString().replaceAll("'", "''")}'";
}

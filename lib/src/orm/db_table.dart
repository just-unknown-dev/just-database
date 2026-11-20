import 'dart:typed_data';

import '../core/just_database.dart';
import '../core/query_result.dart';
import '../storage/values.dart';

/// Base class for every record a [DbTable] manages.
///
/// ```dart
/// class User extends DbRecord {
///   const User({super.id, required this.name, required this.active});
///   final String name;
///   final bool active;
///
///   @override
///   Map<String, Object?> toMap() => {'name': name, 'active': active};
/// }
/// ```
abstract class DbRecord {
  /// Creates a record; [id] is null until it is saved.
  const DbRecord({this.id});

  /// The primary key the database assigned, or null for an unsaved record.
  final int? id;

  /// Every field but `id`, by column name. Values may be null, `int`,
  /// `double`, `String`, `bool`, `DateTime` or `Uint8List`.
  Map<String, Object?> toMap();
}

/// A column of a [DbTable].
class DbColumn {
  const DbColumn._({
    required this.name,
    required this.type,
    this.notNull = false,
    this.unique = false,
    this.defaultValue,
  });

  /// An `INTEGER` column.
  factory DbColumn.integer(
    String name, {
    bool notNull = false,
    bool unique = false,
    int? defaultValue,
  }) => DbColumn._(
    name: name,
    type: 'INTEGER',
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
    type: 'TEXT',
    notNull: notNull,
    unique: unique,
    defaultValue: defaultValue,
  );

  /// A `REAL` column.
  factory DbColumn.real(
    String name, {
    bool notNull = false,
    double? defaultValue,
  }) => DbColumn._(
    name: name,
    type: 'REAL',
    notNull: notNull,
    defaultValue: defaultValue,
  );

  /// A `BOOLEAN` column: stored as 1/0, read back with [DbRowValues.boolValue].
  factory DbColumn.boolean(
    String name, {
    bool notNull = false,
    bool? defaultValue,
  }) => DbColumn._(
    name: name,
    type: 'BOOLEAN',
    notNull: notNull,
    defaultValue: defaultValue,
  );

  /// A `DATETIME` column: stored as ISO-8601 UTC text, read back with
  /// [DbRowValues.dateTimeValue].
  factory DbColumn.datetime(
    String name, {
    bool notNull = false,
    DateTime? defaultValue,
  }) => DbColumn._(
    name: name,
    type: 'DATETIME',
    notNull: notNull,
    defaultValue: defaultValue,
  );

  /// A `BLOB` column.
  factory DbColumn.blob(String name, {bool notNull = false}) =>
      DbColumn._(name: name, type: 'BLOB', notNull: notNull);

  /// The column's name (quoted in SQL, so any name works).
  final String name;

  /// The declared type.
  final String type;

  /// Whether NULL is rejected.
  final bool notNull;

  /// Whether values must be unique.
  final bool unique;

  /// The DEFAULT value, or null for none.
  final Object? defaultValue;

  /// The column's part of `CREATE TABLE`.
  String toSql() {
    final b = StringBuffer('${quoteIdentifier(name)} $type');
    if (notNull) b.write(' NOT NULL');
    if (unique) b.write(' UNIQUE');
    if (defaultValue != null) b.write(' DEFAULT ${sqlLiteral(defaultValue)}');
    return b.toString();
  }

  @override
  String toString() => toSql();
}

/// Typed reads of a result row, for [DbTable.fromRow].
extension DbRowValues on Map<String, Object?> {
  /// An integer (reals are truncated); null when absent or NULL.
  int? intValue(String column) => switch (this[column]) {
    final int v => v,
    final double v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };

  /// A double; null when absent or NULL.
  double? doubleValue(String column) => switch (this[column]) {
    final num v => v.toDouble(),
    final String v => double.tryParse(v),
    _ => null,
  };

  /// A string; null when absent or NULL.
  String? stringValue(String column) => switch (this[column]) {
    null => null,
    final String v => v,
    final Object v => '$v',
  };

  /// A boolean stored as a number (non-zero is true) or `'true'`/`'false'`.
  bool? boolValue(String column) => switch (this[column]) {
    final num v => v != 0,
    final String v => v == '1' || v.toLowerCase() == 'true',
    _ => null,
  };

  /// A date stored as ISO-8601 text (or Unix seconds), in UTC.
  DateTime? dateTimeValue(String column) => switch (this[column]) {
    final String v => DateTime.tryParse(v)?.toUtc(),
    final int v => DateTime.fromMillisecondsSinceEpoch(v * 1000, isUtc: true),
    _ => null,
  };

  /// A blob.
  Uint8List? bytesValue(String column) => switch (this[column]) {
    final Uint8List v => v,
    _ => null,
  };
}

/// Typed CRUD for one table; extend it once per entity.
///
/// ```dart
/// class UserTable extends DbTable<User> {
///   @override
///   String get tableName => 'users';
///
///   @override
///   List<DbColumn> get columns => [
///     DbColumn.text('name', notNull: true),
///     DbColumn.boolean('active', defaultValue: true),
///   ];
///
///   @override
///   User fromRow(Map<String, Object?> row) => User(
///     id: row.intValue('id'),
///     name: row.stringValue('name')!,
///     active: row.boolValue('active') ?? true,
///   );
/// }
///
/// final users = UserTable();
/// await users.createTable(db);
/// final ann = await users.insert(db, const User(name: 'Ann', active: true));
/// final active = await users.findAll(db, where: 'active = ?', whereArgs: [true]);
/// ```
abstract class DbTable<T extends DbRecord> {
  /// The table's name.
  String get tableName;

  /// The columns, without `id` (`id INTEGER PRIMARY KEY AUTOINCREMENT` is
  /// added first).
  List<DbColumn> get columns;

  /// Builds a record from a result row.
  T fromRow(Map<String, Object?> row);

  String get _table => quoteIdentifier(tableName);

  /// The `CREATE TABLE` statement.
  String createTableSql({bool ifNotExists = true}) {
    final defs = [
      '"id" INTEGER PRIMARY KEY AUTOINCREMENT',
      for (final c in columns) c.toSql(),
    ];
    return 'CREATE TABLE ${ifNotExists ? 'IF NOT EXISTS ' : ''}$_table (${defs.join(', ')})';
  }

  /// Creates the table.
  Future<void> createTable(JustDatabase db, {bool ifNotExists = true}) async {
    _check(
      await db.execute(createTableSql(ifNotExists: ifNotExists)),
      'createTable',
    );
  }

  /// Drops the table.
  Future<void> dropTable(JustDatabase db, {bool ifExists = true}) async {
    _check(
      await db.execute('DROP TABLE ${ifExists ? 'IF EXISTS ' : ''}$_table'),
      'dropTable',
    );
  }

  /// Inserts [record]; returns it as stored, with its id.
  Future<T> insert(JustDatabase db, T record) async {
    final map = record.toMap();
    final sql = map.isEmpty
        ? 'INSERT INTO $_table DEFAULT VALUES'
        : 'INSERT INTO $_table (${map.keys.map(quoteIdentifier).join(', ')}) '
              'VALUES (${List.filled(map.length, '?').join(', ')})';
    final r = await db.execute(sql, map.isEmpty ? null : map.values.toList());
    _check(r, 'insert');
    final saved = await findById(db, r.lastInsertRowId!);
    if (saved == null) {
      throw const DbTableException('insert: the new row was not found');
    }
    return saved;
  }

  /// Inserts [records] in one transaction (all or none); returns them as
  /// stored.
  Future<List<T>> insertAll(JustDatabase db, List<T> records) => db.transaction(
    (_) async => [for (final r in records) await insert(db, r)],
  );

  /// The rows matching [where] (SQL with `?` for [whereArgs]), ordered by
  /// [orderBy] (a column name) and paged.
  Future<List<T>> findAll(
    JustDatabase db, {
    String? where,
    List<Object?> whereArgs = const [],
    String? orderBy,
    bool descending = false,
    int? limit,
    int? offset,
  }) async {
    final b = StringBuffer('SELECT * FROM $_table');
    if (where != null) b.write(' WHERE $where');
    if (orderBy != null) {
      b.write(
        ' ORDER BY ${quoteIdentifier(orderBy)}${descending ? ' DESC' : ''}',
      );
    }
    if (limit != null || offset != null) b.write(' LIMIT ${limit ?? -1}');
    if (offset != null) b.write(' OFFSET $offset');
    return _toList(await db.query(b.toString(), whereArgs), 'findAll');
  }

  /// The row with [id], or null.
  Future<T?> findById(JustDatabase db, int id) async {
    final r = await db.query('SELECT * FROM $_table WHERE "id" = ?', [id]);
    _check(r, 'findById');
    return r.rows.isEmpty ? null : fromRow(r.rows.first);
  }

  /// The rows matching [where].
  Future<List<T>> findWhere(
    JustDatabase db,
    String where, [
    List<Object?> whereArgs = const [],
  ]) => findAll(db, where: where, whereArgs: whereArgs);

  /// The first matching row, or null.
  Future<T?> findFirst(
    JustDatabase db, {
    String? where,
    List<Object?> whereArgs = const [],
    String? orderBy,
    bool descending = false,
  }) async {
    final rows = await findAll(
      db,
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      descending: descending,
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// The number of rows matching [where] (all rows when null).
  Future<int> count(
    JustDatabase db, {
    String? where,
    List<Object?> whereArgs = const [],
  }) async {
    final r = await db.query(
      'SELECT COUNT(*) FROM $_table${where == null ? '' : ' WHERE $where'}',
      whereArgs,
    );
    _check(r, 'count');
    return r.scalar as int;
  }

  /// Updates the row of [record]'s id; returns the number updated (0 or 1).
  Future<int> update(JustDatabase db, T record) async {
    final id = record.id;
    if (id == null) {
      throw const DbTableException('update() needs a record with an id');
    }
    final map = record.toMap();
    if (map.isEmpty) return 0;
    final r = await db.execute(
      'UPDATE $_table SET ${map.keys.map((k) => '${quoteIdentifier(k)} = ?').join(', ')} WHERE "id" = ?',
      [...map.values, id],
    );
    _check(r, 'update');
    return r.affectedRows;
  }

  /// Sets [values] on the rows matching [where]; returns how many.
  Future<int> updateWhere(
    JustDatabase db,
    Map<String, Object?> values,
    String where, [
    List<Object?> whereArgs = const [],
  ]) async {
    if (values.isEmpty) return 0;
    final r = await db.execute(
      'UPDATE $_table SET ${values.keys.map((k) => '${quoteIdentifier(k)} = ?').join(', ')} WHERE $where',
      [...values.values, ...whereArgs],
    );
    _check(r, 'updateWhere');
    return r.affectedRows;
  }

  /// Deletes the row with [id]; returns how many (0 or 1).
  Future<int> deleteById(JustDatabase db, int id) async {
    final r = await db.execute('DELETE FROM $_table WHERE "id" = ?', [id]);
    _check(r, 'deleteById');
    return r.affectedRows;
  }

  /// Deletes the rows matching [where]; returns how many.
  Future<int> deleteWhere(
    JustDatabase db,
    String where, [
    List<Object?> whereArgs = const [],
  ]) async {
    final r = await db.execute('DELETE FROM $_table WHERE $where', whereArgs);
    _check(r, 'deleteWhere');
    return r.affectedRows;
  }

  /// Deletes every row; returns how many.
  Future<int> deleteAll(JustDatabase db) async {
    final r = await db.execute('DELETE FROM $_table');
    _check(r, 'deleteAll');
    return r.affectedRows;
  }

  /// Runs a SELECT [sql] and maps every row.
  Future<List<T>> rawQuery(
    JustDatabase db,
    String sql, [
    Object? parameters,
  ]) async => _toList(await db.query(sql, parameters), 'rawQuery');

  List<T> _toList(QueryResult r, String op) {
    _check(r, op);
    return [for (final row in r.rows) fromRow(row)];
  }

  static void _check(QueryResult r, String op) {
    if (!r.success) throw DbTableException('$op failed: ${r.errorMessage}');
  }
}

/// A failed [DbTable] operation.
class DbTableException implements Exception {
  /// Creates the exception.
  const DbTableException(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => 'DbTableException: $message';
}

import '../storage/values.dart';
import 'just_database.dart';
import 'query_result.dart';

/// A fluent builder for simple queries on one table, from
/// `JustDatabase.from`. Values are always bound as parameters and names
/// quoted, so any value or column name is safe.
///
/// ```dart
/// final r = await db.from('users')
///     .where('age > ?', [18])
///     .orderBy('name')
///     .limit(10)
///     .get();
/// ```
final class QueryBuilder {
  /// Creates a builder; use `JustDatabase.from`.
  QueryBuilder(this._db, this._table);

  final JustDatabase _db;
  final String _table;
  final List<String> _columns = [];
  final List<String> _where = [];
  final List<Object?> _whereParams = [];
  final List<String> _orderBy = [];
  int? _limit;
  int? _offset;

  /// Selects only [columns] (all by default).
  QueryBuilder select([List<String>? columns]) {
    _columns
      ..clear()
      ..addAll(columns ?? const []);
    return this;
  }

  /// Adds a condition (ANDed with the others). [condition] is SQL with
  /// `?` placeholders for [params].
  QueryBuilder where(String condition, [List<Object?> params = const []]) {
    _where.add('($condition)');
    _whereParams.addAll(params);
    return this;
  }

  /// Adds `column = value`.
  QueryBuilder whereEquals(String column, Object? value) {
    if (value == null) {
      _where.add('${quoteIdentifier(column)} IS NULL');
    } else {
      _where.add('${quoteIdentifier(column)} = ?');
      _whereParams.add(value);
    }
    return this;
  }

  /// Orders by [column].
  QueryBuilder orderBy(String column, {bool descending = false}) {
    _orderBy.add('${quoteIdentifier(column)}${descending ? ' DESC' : ''}');
    return this;
  }

  /// Returns at most [count] rows.
  QueryBuilder limit(int count) {
    _limit = count;
    return this;
  }

  /// Skips [count] rows.
  QueryBuilder offset(int count) {
    _offset = count;
    return this;
  }

  String get _whereSql =>
      _where.isEmpty ? '' : ' WHERE ${_where.join(' AND ')}';

  /// Runs the SELECT.
  Future<QueryResult> get() {
    final cols = _columns.isEmpty
        ? '*'
        : _columns.map(quoteIdentifier).join(', ');
    final b = StringBuffer(
      'SELECT $cols FROM ${quoteIdentifier(_table)}$_whereSql',
    );
    if (_orderBy.isNotEmpty) b.write(' ORDER BY ${_orderBy.join(', ')}');
    if (_limit != null) b.write(' LIMIT $_limit');
    if (_offset != null) {
      b.write('${_limit == null ? ' LIMIT -1' : ''} OFFSET $_offset');
    }
    return _db.query(b.toString(), _whereParams);
  }

  /// Inserts one row of [values] (column → value).
  Future<QueryResult> insert(Map<String, Object?> values) {
    final cols = values.keys.map(quoteIdentifier).join(', ');
    final marks = List.filled(values.length, '?').join(', ');
    return _db.execute(
      'INSERT INTO ${quoteIdentifier(_table)} ($cols) VALUES ($marks)',
      values.values.toList(),
    );
  }

  /// Updates the matching rows with [values] (column → value).
  Future<QueryResult> update(Map<String, Object?> values) {
    final sets = values.keys.map((k) => '${quoteIdentifier(k)} = ?').join(', ');
    return _db.execute(
      'UPDATE ${quoteIdentifier(_table)} SET $sets$_whereSql',
      [...values.values, ..._whereParams],
    );
  }

  /// Deletes the matching rows.
  Future<QueryResult> delete() => _db.execute(
    'DELETE FROM ${quoteIdentifier(_table)}$_whereSql',
    _whereParams,
  );
}

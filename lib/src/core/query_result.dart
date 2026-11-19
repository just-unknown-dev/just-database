import '../sql/sql_exception.dart';
import '../storage/values.dart';

/// The outcome of one SQL statement.
///
/// A failed statement does not throw from `JustDatabase.execute` or
/// `query`: [success] is false and [error] says why. Inside
/// `JustDatabase.transaction` failures are thrown instead.
final class QueryResult {
  QueryResult._(
    this.columns,
    this.values,
    this.affectedRows,
    this.lastInsertRowId,
    this.error,
  );

  /// A successful result.
  factory QueryResult.success({
    List<String> columns = const [],
    List<List<Object?>> values = const [],
    int affectedRows = 0,
    int? lastInsertRowId,
  }) => QueryResult._(
    List.unmodifiable(columns),
    List.unmodifiable([
      for (final r in values) List<Object?>.unmodifiable(r.map(copyValue)),
    ]),
    affectedRows,
    lastInsertRowId,
    null,
  );

  /// A failed result.
  factory QueryResult.failure(SqlException error) =>
      QueryResult._(const [], const [], 0, null, error);

  /// The result column names, unique: a repeated name gets `:1`, `:2`, …
  /// (`SELECT a.id, b.id` gives `id` and `id:1`).
  final List<String> columns;

  /// The rows as lists, one value per column, in column order.
  final List<List<Object?>> values;

  /// Rows inserted, updated or deleted by the statement.
  final int affectedRows;

  /// The rowid of the last row an INSERT added, when it added one.
  final int? lastInsertRowId;

  /// Why the statement failed; null on success.
  final SqlException? error;

  /// The rows as maps from column name to value.
  late final List<Map<String, Object?>> rows = List.unmodifiable([
    for (final r in values)
      Map<String, Object?>.unmodifiable({
        for (var i = 0; i < columns.length; i++) columns[i]: r[i],
      }),
  ]);

  /// Whether the statement succeeded.
  bool get success => error == null;

  /// [error]'s message, or null on success.
  String? get errorMessage => error?.message;

  /// Whether no rows came back.
  bool get isEmpty => values.isEmpty;

  /// Whether rows came back.
  bool get isNotEmpty => values.isNotEmpty;

  /// The number of rows.
  int get rowCount => values.length;

  /// The first row, or null when there is none.
  Map<String, Object?>? get firstOrNull => rows.isEmpty ? null : rows.first;

  /// The first column of the first row, or null (`SELECT COUNT(*) …`).
  Object? get scalar =>
      values.isEmpty || values.first.isEmpty ? null : values.first.first;

  /// Returns this result, or throws [error] when the statement failed.
  QueryResult orThrow() {
    final e = error;
    if (e != null) throw e;
    return this;
  }

  @override
  String toString() => success
      ? 'QueryResult(rows: $rowCount, affected: $affectedRows)'
      : 'QueryResult(error: $errorMessage)';
}

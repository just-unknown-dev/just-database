/// What kind of failure a [SqlException] reports.
enum SqlErrorKind {
  /// The SQL text could not be parsed.
  syntax,

  /// A table, view, index, trigger or column does not exist, or a name is
  /// already in use.
  schema,

  /// A NOT NULL, UNIQUE, PRIMARY KEY, CHECK or FOREIGN KEY constraint
  /// failed.
  constraint,

  /// A trigger called `RAISE(ABORT | FAIL | ROLLBACK, …)`.
  raised,

  /// The API was used in a way it does not allow (wrong parameter count,
  /// a write passed to `query()`, a nested transaction, …).
  misuse,

  /// Any other failure while running a statement.
  error,
}

/// A failed SQL statement.
///
/// `JustDatabase.execute` and `query` report failures as an unsuccessful
/// `QueryResult` whose `error` is one of these; inside
/// `JustDatabase.transaction` they are thrown, so the transaction rolls
/// back.
final class SqlException implements Exception {
  /// Creates an exception.
  const SqlException(
    this.message, {
    this.kind = SqlErrorKind.error,
    this.sql,
    this.offset,
  });

  /// A syntax error at [offset] in [sql].
  const SqlException.syntax(this.message, this.sql, this.offset)
    : kind = SqlErrorKind.syntax;

  /// A schema error (no such table, name in use, …).
  const SqlException.schema(this.message)
    : kind = SqlErrorKind.schema,
      sql = null,
      offset = null;

  /// A constraint violation.
  const SqlException.constraint(this.message)
    : kind = SqlErrorKind.constraint,
      sql = null,
      offset = null;

  /// A misuse of the API.
  const SqlException.misuse(this.message)
    : kind = SqlErrorKind.misuse,
      sql = null,
      offset = null;

  /// What went wrong.
  final String message;

  /// The kind of failure.
  final SqlErrorKind kind;

  /// The SQL text, for syntax errors.
  final String? sql;

  /// Where in [sql] the syntax error is.
  final int? offset;

  /// A copy that carries the SQL text the statement came from.
  SqlException withSql(String sql) =>
      this.sql != null ? this : SqlException(message, kind: kind, sql: sql);

  @override
  String toString() {
    final b = StringBuffer('SqlException: $message');
    final s = sql, o = offset;
    if (s != null && o != null) {
      final from = o.clamp(0, s.length);
      final near = s.substring(from, (from + 20).clamp(0, s.length));
      b.write(near.isEmpty ? ' (at end of input)' : ' (near "$near")');
    }
    return b.toString();
  }
}

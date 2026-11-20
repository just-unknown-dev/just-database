/// What changed in a database: an event of `JustDatabase.changes`.
final class DatabaseChange {
  /// Creates an event.
  const DatabaseChange({this.tables = const {}, this.schemaChanged = false});

  /// The tables whose rows or definition changed, as they were named when
  /// they changed (a table dropped or renamed since may be among them).
  /// Empty when only something else changed, such as
  /// `PRAGMA user_version`.
  final Set<String> tables;

  /// Whether a table, view, trigger or index was created, changed or
  /// dropped.
  final bool schemaChanged;

  /// Whether [table] is among [tables] (names ignore case).
  bool touches(String table) {
    final lower = table.toLowerCase();
    return tables.any((t) => t.toLowerCase() == lower);
  }

  @override
  String toString() =>
      'DatabaseChange(tables: $tables, schemaChanged: $schemaChanged)';
}

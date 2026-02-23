/// Tracks query patterns to identify frequently-queried columns
/// for automatic index creation.
class QueryTracker {
  /// Tracks column usage in WHERE clauses: tableName → columnName → count
  final Map<String, Map<String, int>> _columnUsage = {};

  /// Tracks composite column usage: tableName → column set → count
  final Map<String, Map<String, int>> _compositeUsage = {};

  /// Threshold for auto-creating an index (default: 100 queries)
  final int autoIndexThreshold;

  /// Columns that have already been auto-indexed
  final Map<String, Set<String>> _autoIndexedColumns = {};

  /// Composite column sets that have been auto-indexed
  final Map<String, Set<String>> _autoIndexedComposites = {};

  QueryTracker({this.autoIndexThreshold = 100});

  /// Records that a single column was used in a WHERE clause.
  void recordColumnUsage(String tableName, String columnName) {
    final tableKey = tableName.toLowerCase();
    final colKey = columnName.toLowerCase();

    _columnUsage.putIfAbsent(tableKey, () => {});
    _columnUsage[tableKey]![colKey] =
        (_columnUsage[tableKey]![colKey] ?? 0) + 1;
  }

  /// Records that multiple columns were used together in a WHERE clause.
  void recordCompositeUsage(String tableName, List<String> columns) {
    if (columns.length < 2) return; // Only track multi-column usage

    final tableKey = tableName.toLowerCase();
    final sortedCols = columns.map((c) => c.toLowerCase()).toList()..sort();
    final compositeKey = sortedCols.join(',');

    _compositeUsage.putIfAbsent(tableKey, () => {});
    _compositeUsage[tableKey]![compositeKey] =
        (_compositeUsage[tableKey]![compositeKey] ?? 0) + 1;
  }

  /// Checks if any columns have reached the threshold and should be auto-indexed.
  /// Returns a list of column names that should get automatic indexes.
  List<String> getColumnsNeedingIndex(String tableName) {
    final tableKey = tableName.toLowerCase();
    final usage = _columnUsage[tableKey];
    if (usage == null) return [];

    final alreadyIndexed = _autoIndexedColumns[tableKey] ?? {};
    final needsIndex = <String>[];

    for (final entry in usage.entries) {
      if (entry.value >= autoIndexThreshold &&
          !alreadyIndexed.contains(entry.key)) {
        needsIndex.add(entry.key);
      }
    }

    return needsIndex;
  }

  /// Checks if any composite column sets have reached the threshold.
  /// Returns a list of column sets (each set is a list of column names).
  List<List<String>> getCompositesNeedingIndex(String tableName) {
    final tableKey = tableName.toLowerCase();
    final usage = _compositeUsage[tableKey];
    if (usage == null) return [];

    final alreadyIndexed = _autoIndexedComposites[tableKey] ?? {};
    final needsIndex = <List<String>>[];

    for (final entry in usage.entries) {
      if (entry.value >= autoIndexThreshold &&
          !alreadyIndexed.contains(entry.key)) {
        needsIndex.add(entry.key.split(','));
      }
    }

    return needsIndex;
  }

  /// Marks a column as having been auto-indexed.
  void markColumnIndexed(String tableName, String columnName) {
    final tableKey = tableName.toLowerCase();
    final colKey = columnName.toLowerCase();
    _autoIndexedColumns.putIfAbsent(tableKey, () => {});
    _autoIndexedColumns[tableKey]!.add(colKey);
  }

  /// Marks a composite as having been auto-indexed.
  void markCompositeIndexed(String tableName, List<String> columns) {
    final tableKey = tableName.toLowerCase();
    final sortedCols = columns.map((c) => c.toLowerCase()).toList()..sort();
    final compositeKey = sortedCols.join(',');
    _autoIndexedComposites.putIfAbsent(tableKey, () => {});
    _autoIndexedComposites[tableKey]!.add(compositeKey);
  }

  /// Gets usage count for a specific column.
  int getColumnUsageCount(String tableName, String columnName) {
    final tableKey = tableName.toLowerCase();
    final colKey = columnName.toLowerCase();
    return _columnUsage[tableKey]?[colKey] ?? 0;
  }

  /// Gets usage count for a specific composite.
  int getCompositeUsageCount(String tableName, List<String> columns) {
    final tableKey = tableName.toLowerCase();
    final sortedCols = columns.map((c) => c.toLowerCase()).toList()..sort();
    final compositeKey = sortedCols.join(',');
    return _compositeUsage[tableKey]?[compositeKey] ?? 0;
  }

  /// Clears all tracking data.
  void clear() {
    _columnUsage.clear();
    _compositeUsage.clear();
    _autoIndexedColumns.clear();
    _autoIndexedComposites.clear();
  }

  /// Gets statistics about column usage for a table.
  Map<String, int> getTableStatistics(String tableName) {
    final tableKey = tableName.toLowerCase();
    return Map.unmodifiable(_columnUsage[tableKey] ?? {});
  }
}

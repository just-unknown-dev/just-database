import 'database_row.dart';

/// Type of index for tracking its purpose and behavior.
enum IndexType {
  primary, // Primary key index
  unique, // Unique constraint index
  foreign, // Foreign key index
  auto, // Automatically created based on query patterns
  spatial, // Spatial (R-tree) index
  manual, // User-created index via CREATE INDEX
}

/// Metadata about an index, tracking its properties and usage.
class IndexMetadata {
  final String name;
  final List<String> columns;
  final IndexType type;
  final bool unique;
  final DateTime createdAt;
  int usageCount;
  DateTime? lastUsedAt;

  IndexMetadata({
    required this.name,
    required this.columns,
    required this.type,
    required this.unique,
    DateTime? createdAt,
    this.usageCount = 0,
    this.lastUsedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  void recordUsage() {
    usageCount++;
    lastUsedAt = DateTime.now();
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'columns': columns,
    'type': type.name,
    'unique': unique,
    'createdAt': createdAt.toIso8601String(),
    'usageCount': usageCount,
    'lastUsedAt': lastUsedAt?.toIso8601String(),
  };

  factory IndexMetadata.fromJson(Map<String, dynamic> json) {
    return IndexMetadata(
      name: json['name'] as String,
      columns: (json['columns'] as List<dynamic>).cast<String>(),
      type: IndexType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => IndexType.auto,
      ),
      unique: json['unique'] as bool? ?? false,
      createdAt: DateTime.parse(json['createdAt'] as String),
      usageCount: json['usageCount'] as int? ?? 0,
      lastUsedAt: json['lastUsedAt'] != null
          ? DateTime.parse(json['lastUsedAt'] as String)
          : null,
    );
  }

  @override
  String toString() => 'IndexMetadata($name on ${columns.join(", ")})';
}

/// A hash-based index mapping column values to row IDs.
/// Supports both single-column and composite (multi-column) indexes.
/// Used to accelerate WHERE conditions on indexed columns.
class TableIndex {
  final List<String> columns;
  final IndexMetadata metadata;

  /// value (or composite key tuple) → list of rowIds that have this value.
  final Map<Object, List<int>> _buckets = {};

  TableIndex({
    required String columnName,
    required bool unique,
    IndexType type = IndexType.auto,
    String? name,
  }) : columns = [columnName],
       metadata = IndexMetadata(
         name: name ?? 'idx_$columnName',
         columns: [columnName],
         type: type,
         unique: unique,
       );

  /// Creates a composite index on multiple columns.
  TableIndex.composite({
    required List<String> columns,
    required bool unique,
    IndexType type = IndexType.auto,
    String? name,
  }) : columns = List.unmodifiable(columns),
       metadata = IndexMetadata(
         name: name ?? 'idx_${columns.join("_")}',
         columns: columns,
         type: type,
         unique: unique,
       );

  /// Legacy getter for backward compatibility with single-column indexes.
  String get columnName => columns.first;

  /// Legacy getter for backward compatibility.
  bool get unique => metadata.unique;

  /// Whether this is a composite (multi-column) index.
  bool get isComposite => columns.length > 1;

  /// Adds a row to the index. For single-column indexes, pass the value.
  /// For composite indexes, pass a DatabaseRow object.
  void add(dynamic value, int rowId) {
    final key = _makeKey(value);
    if (key == null) return;
    _buckets.putIfAbsent(key, () => []).add(rowId);
  }

  /// Removes a row from the index.
  void remove(dynamic value, int rowId) {
    final key = _makeKey(value);
    if (key == null) return;
    _buckets[key]?.remove(rowId);
    if (_buckets[key]?.isEmpty ?? false) _buckets.remove(key);
  }

  void update(dynamic oldValue, dynamic newValue, int rowId) {
    remove(oldValue, rowId);
    add(newValue, rowId);
  }

  /// Returns row IDs where the column value equals [value].
  /// For composite indexes, [value] should be a DatabaseRow or Map with all columns.
  List<int> lookup(dynamic value) {
    metadata.recordUsage();
    final key = _makeKey(value);
    if (key == null) return [];
    return List.unmodifiable(_buckets[key] ?? []);
  }

  /// Looks up using a partial key (for composite indexes).
  /// [values] is a map of column names to values - only need to provide a subset.
  List<int> lookupPartial(Map<String, dynamic> values) {
    metadata.recordUsage();
    if (!isComposite) {
      // For single-column, just use regular lookup
      return lookup(values[columns.first]);
    }

    // For composite, scan all buckets and match prefix
    final result = <int>[];
    for (final entry in _buckets.entries) {
      if (entry.key is _CompositeKey) {
        final compositeKey = entry.key as _CompositeKey;
        bool matches = true;
        for (final colEntry in values.entries) {
          final colIndex = columns.indexOf(colEntry.key);
          if (colIndex >= 0 &&
              colIndex < compositeKey.values.length &&
              _toKey(compositeKey.values[colIndex]) != _toKey(colEntry.value)) {
            matches = false;
            break;
          }
        }
        if (matches) result.addAll(entry.value);
      }
    }
    return result;
  }

  /// Returns row IDs satisfying the comparison [op] vs [value].
  /// '=' benefits from O(1) hash lookup; all others fall back to bucket scan.
  /// For composite indexes, only works for full-key comparisons.
  List<int> scan(String op, dynamic value) {
    metadata.recordUsage();
    if (op == '=') return lookup(value);

    final result = <int>[];
    final targetKey = _makeKey(value);
    if (targetKey == null) return result;

    for (final entry in _buckets.entries) {
      final cmp = _compareKeys(entry.key, targetKey);
      bool include = false;
      switch (op) {
        case '!=':
          include = cmp != 0;
        case '<':
          include = cmp < 0;
        case '<=':
          include = cmp <= 0;
        case '>':
          include = cmp > 0;
        case '>=':
          include = cmp >= 0;
      }
      if (include) result.addAll(entry.value);
    }
    return result;
  }

  bool containsValue(dynamic value) {
    final key = _makeKey(value);
    if (key == null) return false;
    return _buckets.containsKey(key);
  }

  void rebuild(List<DatabaseRow> rows) {
    _buckets.clear();
    for (final row in rows) {
      if (isComposite) {
        add(row, row.rowId);
      } else {
        add(row.values[columns.first], row.rowId);
      }
    }
  }

  void clear() => _buckets.clear();

  int get bucketCount => _buckets.length;

  /// Creates a hash key from the value(s).
  /// For single-column: converts the value to a hashable key.
  /// For composite: creates a composite key from a DatabaseRow or Map.
  Object? _makeKey(dynamic value) {
    if (isComposite) {
      // Extract values for all columns from DatabaseRow or Map
      List<dynamic> values;
      if (value is DatabaseRow) {
        values = columns.map((col) => value.values[col]).toList();
      } else if (value is Map<String, dynamic>) {
        values = columns.map((col) => value[col]).toList();
      } else {
        return null; // Invalid input for composite index
      }
      // If any value is null, return null (nulls not indexed)
      if (values.any((v) => v == null)) return null;
      return _CompositeKey(values.map(_toKey).toList());
    } else {
      // Single column: just convert value
      if (value == null) return null;
      return _toKey(value);
    }
  }

  Object _toKey(dynamic value) {
    if (value is String) return value;
    if (value is num) return value;
    if (value is bool) return value;
    if (value is DateTime) return value.toUtc().millisecondsSinceEpoch;
    return value.toString();
  }

  /// Compares two keys (handles both simple keys and composite keys).
  int _compareKeys(Object a, Object b) {
    if (a is _CompositeKey && b is _CompositeKey) {
      return a.compareTo(b);
    }
    return _compare(a, b);
  }

  int _compare(Object a, Object b) {
    if (a is num && b is num) return a.compareTo(b);
    return a.toString().compareTo(b.toString());
  }
}

/// Internal class for representing composite index keys.
class _CompositeKey {
  final List<Object> values;

  _CompositeKey(this.values);

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! _CompositeKey) return false;
    if (values.length != other.values.length) return false;
    for (int i = 0; i < values.length; i++) {
      if (values[i] != other.values[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    int hash = 0;
    for (final v in values) {
      hash = hash ^ v.hashCode;
    }
    return hash;
  }

  int compareTo(_CompositeKey other) {
    final minLen = values.length < other.values.length
        ? values.length
        : other.values.length;
    for (int i = 0; i < minLen; i++) {
      final a = values[i];
      final b = other.values[i];
      int cmp;
      if (a is num && b is num) {
        cmp = a.compareTo(b);
      } else {
        cmp = a.toString().compareTo(b.toString());
      }
      if (cmp != 0) return cmp;
    }
    return values.length.compareTo(other.values.length);
  }

  @override
  String toString() => '(${values.join(", ")})';
}

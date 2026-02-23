import 'dart:convert';
import 'dart:typed_data';
import 'schema.dart';

/// A single row in a table.
class DatabaseRow {
  /// Column name → value. Values are native Dart types:
  /// INTEGER → int, TEXT → String, REAL → double,
  /// BLOB → Uint8List, BOOLEAN → bool, DATETIME → DateTime.
  final Map<String, dynamic> values;

  /// Auto-assigned internal row identifier.
  final int rowId;

  const DatabaseRow({required this.values, required this.rowId});

  dynamic operator [](String column) => values[column];

  /// Returns a new DatabaseRow with updated values (immutable).
  DatabaseRow copyWith(Map<String, dynamic> updates) {
    return DatabaseRow(rowId: rowId, values: {...values, ...updates});
  }

  /// Merges two rows for JOIN results.
  /// Keys are prefixed as "prefixA.col" and "prefixB.col" in addition to
  /// plain "col" (plain key uses last assignment, so prefer qualified form
  /// in expressions that could be ambiguous).
  static DatabaseRow merge(DatabaseRow a, DatabaseRow b, {String? prefixA, String? prefixB}) {
    final merged = <String, dynamic>{};
    // Plain keys first (b overwrites a on collision — callers must use qualified)
    for (final entry in a.values.entries) {
      merged[entry.key] = entry.value;
    }
    for (final entry in b.values.entries) {
      merged[entry.key] = entry.value;
    }
    // Qualified keys
    if (prefixA != null) {
      for (final entry in a.values.entries) {
        merged['$prefixA.${entry.key}'] = entry.value;
      }
    }
    if (prefixB != null) {
      for (final entry in b.values.entries) {
        merged['$prefixB.${entry.key}'] = entry.value;
      }
    }
    return DatabaseRow(rowId: a.rowId, values: merged);
  }

  /// Creates a null row for LEFT/RIGHT JOIN padding.
  static DatabaseRow nullRow(TableSchema schema, {String? prefix}) {
    final values = <String, dynamic>{};
    for (final col in schema.columns) {
      values[col.name] = null;
      if (prefix != null) {
        values['$prefix.${col.name}'] = null;
      }
    }
    return DatabaseRow(rowId: -1, values: values);
  }

  Map<String, dynamic> toJson() {
    final encoded = <String, dynamic>{};
    for (final entry in values.entries) {
      final v = entry.value;
      if (v is Uint8List) {
        encoded[entry.key] = {'__type': 'blob', 'data': base64.encode(v)};
      } else if (v is DateTime) {
        encoded[entry.key] = {
          '__type': 'datetime',
          'data': v.toUtc().toIso8601String(),
        };
      } else {
        encoded[entry.key] = v;
      }
    }
    return encoded;
  }

  factory DatabaseRow.fromJson(Map<String, dynamic> json, int rowId) {
    final values = <String, dynamic>{};
    for (final entry in json.entries) {
      final v = entry.value;
      if (v is Map && v['__type'] == 'blob') {
        values[entry.key] = base64.decode(v['data'] as String);
      } else if (v is Map && v['__type'] == 'datetime') {
        values[entry.key] = DateTime.parse(v['data'] as String);
      } else {
        values[entry.key] = v;
      }
    }
    return DatabaseRow(rowId: rowId, values: values);
  }

  @override
  String toString() => 'DatabaseRow(id=$rowId, $values)';
}

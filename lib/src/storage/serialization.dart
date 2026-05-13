import 'table.dart';
import '../core/database_mode.dart';

/// Shared serialization helpers used by both native and web persistence.
///
/// Encodes/decodes the database table map to/from a JSON-compatible structure.
/// The actual JSON encoding (`jsonEncode`/`jsonDecode`) and I/O is handled by
/// the platform-specific persistence implementations.
class DatabaseSerializer {
  DatabaseSerializer._();

  /// Encodes all [tables] and [mode] into a JSON-serialisable map.
  ///
  /// Structure:
  /// ```json
  /// {
  ///   "version": 1,
  ///   "mode": "standard",
  ///   "tables": { "<name>": <Table.toJson()>, ... }
  /// }
  /// ```
  static Map<String, dynamic> encodeDatabase(
    Map<String, Table> tables,
    DatabaseMode mode,
  ) {
    return {
      'version': 1,
      'mode': mode.name,
      'tables': {
        for (final entry in tables.entries) entry.key: entry.value.toJson(),
      },
    };
  }

  /// Decodes a tables map from the `"tables"` key of a database JSON.
  static Map<String, Table> decodeTables(Map<String, dynamic> json) {
    return {
      for (final entry in json.entries)
        entry.key: Table.fromJson(entry.value as Map<String, dynamic>),
    };
  }
}

import '../core/database_mode.dart';
import 'table.dart';

/// A snapshot of a persisted database loaded from disk.
class DatabaseSnapshot {
  final String name;
  final DatabaseMode mode;
  final Map<String, Table> tables;

  const DatabaseSnapshot({
    required this.name,
    required this.mode,
    required this.tables,
  });
}

/// Web stub for [PersistenceManager].
///
/// File-based persistence is not supported on the web platform.
/// All operations are no-ops or return empty/default values.
class PersistenceManager {
  PersistenceManager._();

  /// No-op on web — file persistence is not available.
  static Future<void> save(
    String name,
    Map<String, Table> tables,
    DatabaseMode mode, {
    String? encryptionKey,
  }) async {}

  /// Always returns null on web — no files to load from.
  static Future<DatabaseSnapshot?> load(
    String name, {
    String? encryptionKey,
  }) async => null;

  /// Always returns [DatabaseMode.standard] on web.
  static Future<DatabaseMode> peekMode(String name) async =>
      DatabaseMode.standard;

  /// No-op on web.
  static Future<void> delete(String name) async {}

  /// Always returns an empty list on web.
  static Future<List<String>> listPersistedNames() async => [];

  /// Always returns 0 on web.
  static Future<int> getFileSize(String name) async => 0;
}

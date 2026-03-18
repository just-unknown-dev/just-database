/// OPFS-based persistence manager for web.
///
/// Implements the same API as the native `PersistenceManager` but uses the
/// Origin Private File System with synchronous byte-level I/O via
/// `FileSystemSyncAccessHandle`. Intended to run inside a dedicated Web Worker.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../core/database_mode.dart';
import '../storage/serialization.dart';
import '../storage/table.dart';
import 'opfs_storage.dart';

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

/// OPFS-backed persistence for the just_database web engine.
///
/// Uses `OpfsStorageDriver` for synchronous file I/O inside a Web Worker.
/// The format is the same JSON schema as the native `.jdb` files, ensuring
/// cross-platform portability of database snapshots.
class OpfsPersistenceManager {
  OpfsPersistenceManager._();

  /// Saves all [tables] to `<name>.jdb` in the OPFS `just_database/` directory.
  static void save(
    OpfsStorageDriver driver,
    String name,
    Map<String, Table> tables,
    DatabaseMode mode,
  ) {
    final json = DatabaseSerializer.encodeDatabase(tables, mode);
    final jsonString = jsonEncode(json);
    final bytes = Uint8List.fromList(utf8.encode(jsonString));
    driver.writeAll(bytes);
  }

  /// Loads a database from an open OPFS driver. Returns `null` if the file is
  /// empty (new database).
  static DatabaseSnapshot? load(OpfsStorageDriver driver, String name) {
    final bytes = driver.readAll();
    if (bytes.isEmpty) return null;

    final content = utf8.decode(bytes);
    final json = jsonDecode(content) as Map<String, dynamic>;

    final modeStr = json['mode'] as String? ?? 'standard';
    final mode = DatabaseMode.values.firstWhere(
      (m) => m.name == modeStr,
      orElse: () => DatabaseMode.standard,
    );

    final tables = DatabaseSerializer.decodeTables(
      json['tables'] as Map<String, dynamic>? ?? {},
    );

    return DatabaseSnapshot(name: name, mode: mode, tables: tables);
  }

  /// Reads the [DatabaseMode] from a `.jdb` file without fully decoding tables.
  static DatabaseMode peekMode(OpfsStorageDriver driver) {
    final bytes = driver.readAll();
    if (bytes.isEmpty) return DatabaseMode.standard;

    try {
      final content = utf8.decode(bytes);
      final json = jsonDecode(content) as Map<String, dynamic>;
      final modeStr = json['mode'] as String? ?? 'standard';
      return DatabaseMode.values.firstWhere(
        (m) => m.name == modeStr,
        orElse: () => DatabaseMode.standard,
      );
    } catch (_) {
      return DatabaseMode.standard;
    }
  }

  /// Deletes a database file and its WAL from the OPFS directory.
  static Future<void> delete(String name) async {
    await OpfsStorageDriver.deleteFile(name);
    await OpfsWalDriver.deleteFile(name);
  }

  /// Lists all persisted database names in the OPFS directory.
  static Future<List<String>> listPersistedNames() =>
      OpfsStorageDriver.listDatabases();

  /// Returns the file size in bytes for the given database, or 0 if not found.
  static Future<int> getFileSize(String name) async {
    try {
      final driver = await OpfsStorageDriver.open(name);
      try {
        return driver.fileSize();
      } finally {
        driver.close();
      }
    } catch (_) {
      return 0;
    }
  }
}

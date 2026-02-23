import 'package:flutter/foundation.dart';
import '../storage/persistence.dart';
import 'database.dart';
import 'database_mode.dart';

/// Summary information about a database (open or persisted).
class DatabaseInfo {
  final String name;
  final DatabaseMode mode;
  final bool isPersisted;
  final int sizeBytes;
  final int tableCount;
  final int totalRows;
  final bool isOpen;

  const DatabaseInfo({
    required this.name,
    required this.mode,
    required this.isPersisted,
    required this.sizeBytes,
    required this.tableCount,
    required this.totalRows,
    required this.isOpen,
  });

  /// Human-readable size string, e.g. "2.4 KB", "1.1 MB".
  String get formattedSize {
    if (sizeBytes < 1024) return '$sizeBytes B';
    if (sizeBytes < 1024 * 1024) {
      return '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String get modeName {
    switch (mode) {
      case DatabaseMode.standard:
        return 'Standard';
      case DatabaseMode.readFast:
        return 'Read Fast';
      case DatabaseMode.writeFast:
        return 'Write Fast';
      case DatabaseMode.secure:
        return 'Secure';
    }
  }

  @override
  String toString() => 'DatabaseInfo($name, mode=$modeName, open=$isOpen)';
}

/// Global registry and lifecycle manager for [JustDatabase] instances.
class DatabaseManager {
  /// All currently open database instances. Key = lowercase database name.
  @visibleForTesting
  static final Map<String, JustDatabase> openDatabases = {};

  /// Opens a database and registers it with the manager.
  /// If the database is already open, returns the existing instance.
  ///
  /// See [JustDatabase.open] for details on [mode], [persist], and
  /// [encryptionKey] ([DatabaseMode.secure] only).
  static Future<JustDatabase> open(
    String name, {
    DatabaseMode mode = DatabaseMode.standard,
    bool persist = true,
    String? encryptionKey,
  }) async {
    final key = name.toLowerCase();
    if (openDatabases.containsKey(key)) return openDatabases[key]!;
    final db = await JustDatabase.open(
      name,
      mode: mode,
      persist: persist,
      encryptionKey: encryptionKey,
    );
    openDatabases[key] = db;
    return db;
  }

  /// Returns the open database with [name], or null if not open.
  static JustDatabase? getOpenDatabase(String name) {
    return openDatabases[name.toLowerCase()];
  }

  /// Returns [DatabaseInfo] for all open and all persisted (closed) databases.
  static Future<List<DatabaseInfo>> listDatabases() async {
    final result = <DatabaseInfo>[];

    // Open databases
    for (final entry in openDatabases.entries) {
      result.add(
        DatabaseInfo(
          name: entry.value.name,
          mode: entry.value.mode,
          isPersisted: entry.value.persist,
          sizeBytes: entry.value.estimatedSizeBytes,
          tableCount: entry.value.tableNames.length,
          totalRows: entry.value.totalRows,
          isOpen: true,
        ),
      );
    }

    // Persisted but not currently open
    try {
      final persistedNames = await PersistenceManager.listPersistedNames();
      for (final persName in persistedNames) {
        final key = persName.toLowerCase();
        if (!openDatabases.containsKey(key)) {
          final size = await PersistenceManager.getFileSize(persName);
          final mode = await PersistenceManager.peekMode(persName);
          result.add(
            DatabaseInfo(
              name: persName,
              mode: mode,
              isPersisted: true,
              sizeBytes: size,
              tableCount: 0,
              totalRows: 0,
              isOpen: false,
            ),
          );
        }
      }
    } catch (_) {
      // path_provider may not be available in all environments
    }

    return result;
  }

  /// Closes and unregisters a database (saves to disk first if persist=true).
  static Future<void> close(String name) async {
    final key = name.toLowerCase();
    final db = openDatabases.remove(key);
    if (db != null && db.isOpen) await db.close();
  }

  /// Closes a database and deletes its persisted file.
  static Future<void> deleteDatabase(String name) async {
    await close(name);
    try {
      await PersistenceManager.delete(name);
    } catch (_) {}
  }

  /// Closes all open databases.
  static Future<void> closeAll() async {
    final names = List.of(openDatabases.keys);
    for (final name in names) {
      await close(name);
    }
    openDatabases.clear();
  }

  /// Closes and deletes all databases including all persisted files.
  static Future<void> deleteAll() async {
    await closeAll();
    try {
      final names = await PersistenceManager.listPersistedNames();
      for (final name in names) {
        await PersistenceManager.delete(name);
      }
    } catch (_) {}
  }
}

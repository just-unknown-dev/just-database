import '../core/database_mode.dart';
import '../web/idb_persistence.dart' as idb;
import 'table.dart';

/// A snapshot of a persisted database loaded from storage.
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

/// Web [PersistenceManager] backed by IndexedDB.
///
/// OPFS persistence is handled inside the Web Worker (see [database_web.dart]),
/// so this class only needs to cover the IndexedDB fallback path for
/// non-worker usage (e.g. direct [PersistenceManager] calls from tests or the
/// admin widget).
class PersistenceManager {
  PersistenceManager._();

  /// Saves the database tables to IndexedDB.
  static Future<void> save(
    String name,
    Map<String, Table> tables,
    DatabaseMode mode, {
    String? encryptionKey,
  }) async {
    if (!idb.IdbPersistenceManager.isAvailable) return;
    await idb.IdbPersistenceManager.save(name, tables, mode);
  }

  /// Loads a database from IndexedDB.
  static Future<DatabaseSnapshot?> load(
    String name, {
    String? encryptionKey,
  }) async {
    if (!idb.IdbPersistenceManager.isAvailable) return null;
    final snapshot = await idb.IdbPersistenceManager.load(name);
    if (snapshot == null) return null;
    return DatabaseSnapshot(
      name: snapshot.name,
      mode: snapshot.mode,
      tables: snapshot.tables,
    );
  }

  /// Peeks at the stored mode without loading full data.
  static Future<DatabaseMode> peekMode(String name) async {
    if (!idb.IdbPersistenceManager.isAvailable) return DatabaseMode.standard;
    return idb.IdbPersistenceManager.peekMode(name);
  }

  /// Deletes a persisted database from IndexedDB.
  static Future<void> delete(String name) async {
    if (!idb.IdbPersistenceManager.isAvailable) return;
    await idb.IdbPersistenceManager.delete(name);
  }

  /// Lists all persisted database names.
  static Future<List<String>> listPersistedNames() async {
    if (!idb.IdbPersistenceManager.isAvailable) return [];
    return idb.IdbPersistenceManager.listPersistedNames();
  }

  /// Returns the approximate size of a persisted database.
  static Future<int> getFileSize(String name) async {
    if (!idb.IdbPersistenceManager.isAvailable) return 0;
    return idb.IdbPersistenceManager.getFileSize(name);
  }
}

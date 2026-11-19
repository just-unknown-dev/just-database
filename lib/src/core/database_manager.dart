import 'dart:async';

import 'package:flutter/foundation.dart' show internal;

import '../persistence/crypto.dart' show looksEncrypted;
import '../persistence/store.dart';
import 'database_mode.dart';
import 'just_database.dart';
import '../io/file_store.dart'
    if (dart.library.js_interop) '../web/idb_store.dart';

/// What [DatabaseManager.listDatabases] knows about one database.
final class DatabaseInfo {
  /// Creates an entry.
  const DatabaseInfo({
    required this.name,
    required this.isOpen,
    required this.isPersisted,
    required this.isEncrypted,
    required this.sizeBytes,
    this.mode,
    this.tableCount,
    this.totalRows,
  });

  final String name;

  /// Whether it is open in this app.
  final bool isOpen;

  /// Whether it is saved (false for an in-memory database).
  final bool isPersisted;

  /// Whether its file is encrypted.
  final bool isEncrypted;

  /// The stored size in bytes (an estimate for an in-memory database).
  final int sizeBytes;

  /// The mode it is open in; null when closed.
  final DatabaseMode? mode;

  /// The number of tables; null when closed.
  final int? tableCount;

  /// The number of rows; null when closed.
  final int? totalRows;
}

/// Opens databases by name and lists, closes and deletes them; the admin
/// UI works through it.
///
/// It holds one reference to each database it opened: [close] releases
/// that reference, so a database the app opened itself with
/// `JustDatabase.open` stays open for the app.
abstract final class DatabaseManager {
  static final Map<String, JustDatabase> _held = {};
  static final StreamController<void> _listChanges =
      StreamController<void>.broadcast();

  /// An event whenever a database is opened, closed, deleted or encrypted
  /// in this app, so a list of databases can refresh itself. Events come
  /// asynchronously.
  static Stream<void> get listChanges => _listChanges.stream;

  /// Sends a [listChanges] event.
  @internal
  static void notifyListChanged() => _listChanges.add(null);
  // A fresh store each time: it resolves the storage directory anew.
  static DatabaseStore get _store => createPlatformStore();

  /// Every open database in this app, by lower-case name (whoever opened
  /// it).
  static Map<String, JustDatabase> get openDatabases => Map.unmodifiable({
    for (final db in JustDatabase.openDatabases) db.name.toLowerCase(): db,
  });

  /// Opens [name] (see `JustDatabase.open`), or returns it when it is open
  /// already with the same settings.
  static Future<JustDatabase> open(
    String name, {
    DatabaseMode mode = DatabaseMode.standard,
    bool persist = true,
    String? encryptionKey,
  }) async {
    final db = await JustDatabase.open(
      name,
      mode: mode,
      persist: persist,
      encryptionKey: encryptionKey,
    );
    final key = name.toLowerCase();
    if (identical(_held[key], db)) {
      await db.close(); // drop the reference this call added
    } else {
      _held[key] = db;
    }
    return db;
  }

  /// The open database named [name] (opened by anyone), or null.
  static JustDatabase? getOpenDatabase(String name) =>
      JustDatabase.findOpen(name);

  /// Releases the manager's reference to [name].
  static Future<void> close(String name) async {
    final db = _held.remove(name.toLowerCase());
    if (db != null) await db.close();
  }

  /// Releases every reference the manager holds.
  static Future<void> closeAll() async {
    final dbs = List.of(_held.values);
    _held.clear();
    for (final db in dbs) {
      await db.close();
    }
  }

  /// Every database: the open ones and those saved by this app.
  static Future<List<DatabaseInfo>> listDatabases() async {
    final out = <String, DatabaseInfo>{};
    for (final db in JustDatabase.openDatabases) {
      out[db.name.toLowerCase()] = DatabaseInfo(
        name: db.name,
        isOpen: true,
        isPersisted: db.persist,
        isEncrypted: db.persist && await _isEncrypted(db.name),
        sizeBytes: db.persist
            ? await _store.size(db.name)
            : db.estimatedSizeBytes,
        mode: db.mode,
        tableCount: db.tableNames.length,
        totalRows: db.totalRows,
      );
    }
    List<String> saved;
    try {
      saved = await _store.list();
    } on StorageUnavailableException {
      saved = const [];
    }
    for (final name in saved) {
      if (out.containsKey(name.toLowerCase())) continue;
      out[name.toLowerCase()] = DatabaseInfo(
        name: name,
        isOpen: false,
        isPersisted: true,
        isEncrypted: await _isEncrypted(name),
        sizeBytes: await _store.size(name),
      );
    }
    return out.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  static Future<bool> _isEncrypted(String name) async {
    try {
      final bytes = await _store.peek(name, 64);
      return bytes != null && looksEncrypted(bytes);
    } catch (_) {
      return false;
    }
  }

  /// Closes [name] for everyone (it is being deleted) and deletes its file.
  static Future<void> deleteDatabase(String name) async {
    validateDatabaseName(name);
    _held.remove(name.toLowerCase());
    final open = JustDatabase.findOpen(name);
    if (open != null) await open.closeAll();
    await _store.delete(name);
    notifyListChanged();
  }

  /// Deletes every database this app saved (and closes the open ones).
  static Future<void> deleteAll() async {
    final names = <String>{
      for (final db in JustDatabase.openDatabases) db.name,
      ...await _store.list(),
    };
    for (final name in names) {
      final open = JustDatabase.findOpen(name);
      _held.remove(name.toLowerCase());
      if (open != null) await open.closeAll();
      if (open == null || open.persist) await _store.delete(name);
    }
    notifyListChanged();
  }
}

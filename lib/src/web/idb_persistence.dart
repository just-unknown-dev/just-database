/// IndexedDB-based fallback persistence for web environments where OPFS
/// is not available (private browsing, older browsers, etc.).
///
/// Stores each database as a single JSON blob in an IndexedDB object store.
/// This is asynchronous and less performant than OPFS but widely supported.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../core/database_mode.dart';
import '../storage/serialization.dart';
import '../storage/table.dart';

/// A snapshot of a persisted database loaded from IndexedDB.
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

/// IndexedDB persistence driver.
///
/// Uses a single IndexedDB database named `just_database` with one object
/// store `databases`, keyed by database name. Each value is a JSON string
/// containing the full database snapshot.
class IdbPersistenceManager {
  static const String _idbName = 'just_database';
  static const String _storeName = 'databases';
  static const int _idbVersion = 1;

  IdbPersistenceManager._();

  /// Saves all [tables] under [name] in IndexedDB.
  static Future<void> save(
    String name,
    Map<String, Table> tables,
    DatabaseMode mode,
  ) async {
    final json = DatabaseSerializer.encodeDatabase(tables, mode);
    final jsonString = jsonEncode(json);
    final db = await _openDb();
    try {
      final tx = db.transaction(_storeName.toJS, 'readwrite');
      final store = tx.objectStore(_storeName);
      store.put(jsonString.toJS, name.toJS);
      await _completeTransaction(tx);
    } finally {
      db.close();
    }
  }

  /// Loads a database from IndexedDB. Returns `null` if not found.
  static Future<DatabaseSnapshot?> load(String name) async {
    final db = await _openDb();
    try {
      final tx = db.transaction(_storeName.toJS, 'readonly');
      final store = tx.objectStore(_storeName);
      final request = store.get(name.toJS);
      final result = await _requestToFuture(request);
      if (result == null || result.isUndefinedOrNull) return null;

      final jsonString = (result as JSString).toDart;
      final json = jsonDecode(jsonString) as Map<String, dynamic>;

      final modeStr = json['mode'] as String? ?? 'standard';
      final mode = DatabaseMode.values.firstWhere(
        (m) => m.name == modeStr,
        orElse: () => DatabaseMode.standard,
      );

      final tables = DatabaseSerializer.decodeTables(
        json['tables'] as Map<String, dynamic>? ?? {},
      );

      return DatabaseSnapshot(name: name, mode: mode, tables: tables);
    } finally {
      db.close();
    }
  }

  /// Reads the [DatabaseMode] without fully decoding tables.
  static Future<DatabaseMode> peekMode(String name) async {
    final db = await _openDb();
    try {
      final tx = db.transaction(_storeName.toJS, 'readonly');
      final store = tx.objectStore(_storeName);
      final request = store.get(name.toJS);
      final result = await _requestToFuture(request);
      if (result == null || result.isUndefinedOrNull) {
        return DatabaseMode.standard;
      }

      final jsonString = (result as JSString).toDart;
      final json = jsonDecode(jsonString) as Map<String, dynamic>;
      final modeStr = json['mode'] as String? ?? 'standard';
      return DatabaseMode.values.firstWhere(
        (m) => m.name == modeStr,
        orElse: () => DatabaseMode.standard,
      );
    } catch (_) {
      return DatabaseMode.standard;
    } finally {
      db.close();
    }
  }

  /// Deletes a database entry from IndexedDB.
  static Future<void> delete(String name) async {
    final db = await _openDb();
    try {
      final tx = db.transaction(_storeName.toJS, 'readwrite');
      final store = tx.objectStore(_storeName);
      store.delete(name.toJS);
      await _completeTransaction(tx);
    } finally {
      db.close();
    }
  }

  /// Lists all persisted database names.
  static Future<List<String>> listPersistedNames() async {
    final db = await _openDb();
    try {
      final tx = db.transaction(_storeName.toJS, 'readonly');
      final store = tx.objectStore(_storeName);
      final request = store.getAllKeys(null);
      final result = await _requestToFuture(request);
      if (result == null || result.isUndefinedOrNull) return [];

      final keys = result as JSArray<JSAny>;
      return keys.toDart.map((k) => (k as JSString).toDart).toList();
    } catch (_) {
      return [];
    } finally {
      db.close();
    }
  }

  /// Returns an estimated size in bytes, or 0 if not found.
  static Future<int> getFileSize(String name) async {
    final db = await _openDb();
    try {
      final tx = db.transaction(_storeName.toJS, 'readonly');
      final store = tx.objectStore(_storeName);
      final request = store.get(name.toJS);
      final result = await _requestToFuture(request);
      if (result == null || result.isUndefinedOrNull) return 0;
      return (result as JSString).toDart.length;
    } catch (_) {
      return 0;
    } finally {
      db.close();
    }
  }

  /// Returns `true` if IndexedDB is available in this environment.
  static bool get isAvailable {
    try {
      // Access window.indexedDB — will throw in restricted contexts
      web.window.indexedDB;
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Internal — IndexedDB helpers
  // ---------------------------------------------------------------------------

  static Future<web.IDBDatabase> _openDb() {
    final completer = Completer<web.IDBDatabase>();
    final request = web.window.indexedDB.open(_idbName, _idbVersion);

    request.onupgradeneeded = ((web.IDBVersionChangeEvent event) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }).toJS;

    request.onsuccess = ((web.Event _) {
      completer.complete(request.result as web.IDBDatabase);
    }).toJS;

    request.onerror = ((web.Event _) {
      completer.completeError(
        StateError('Failed to open IndexedDB: ${request.error}'),
      );
    }).toJS;

    return completer.future;
  }

  static Future<JSAny?> _requestToFuture(web.IDBRequest request) {
    final completer = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) {
      completer.complete(request.result);
    }).toJS;
    request.onerror = ((web.Event _) {
      completer.completeError(
        StateError('IDB request error: ${request.error}'),
      );
    }).toJS;
    return completer.future;
  }

  static Future<void> _completeTransaction(web.IDBTransaction tx) {
    final completer = Completer<void>();
    tx.oncomplete = ((web.Event _) {
      completer.complete();
    }).toJS;
    tx.onerror = ((web.Event _) {
      completer.completeError(StateError('IDB transaction error: ${tx.error}'));
    }).toJS;
    return completer.future;
  }
}

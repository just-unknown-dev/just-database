import 'dart:async';

import 'package:just_signals/just_signals.dart';

import '../core/database_manager.dart';
import '../core/database_mode.dart';
import '../core/just_database.dart';
import '../core/query_result.dart';
import '../core/secure_key_manager.dart';
import 'admin_utils.dart';

/// The state and actions behind the admin UI.
///
/// It lists every database: the ones open in this app (whoever opened
/// them) and the ones saved by it. Selecting a database that is open uses
/// that instance, so the admin screen and the app always share one;
/// selecting a closed one opens it from storage. Databases the provider
/// opened itself are closed again by [dispose].
///
/// Actions return `true` on success. On failure they return `false` and
/// [lastError] says why, so the widget that started the action can show it.
/// Query errors are kept apart in [lastQueryError].
///
/// Widgets rebuild from [revision], which changes after every update.
class DatabaseProvider {
  /// Creates a provider. [defaultMode] and [persistByDefault] are the
  /// starting values of the Settings tab's defaults for new databases.
  DatabaseProvider({
    DatabaseMode defaultMode = DatabaseMode.standard,
    bool persistByDefault = true,
  }) : _defaultMode = defaultMode,
       _persistEnabled = persistByDefault;

  /// Changes whenever the provider's state changes.
  final Signal<int> revision = Signal(
    0,
    debugLabel: 'DatabaseProvider.revision',
  );

  List<DatabaseInfo> _databases = const [];
  bool _hasLoaded = false;
  JustDatabase? _current;
  DatabaseMode _defaultMode;
  bool _persistEnabled;
  QueryResult? _lastQueryResult;
  String? _lastQueryError;
  int _lastStatementCount = 0;
  String? _lastError;
  int _busy = 0;
  bool _disposed = false;
  final List<String> _queryHistory = [];

  /// Databases this provider opened (one reference each), by lower-case name.
  final Map<String, JustDatabase> _held = {};

  /// Encrypted databases this provider created, by lower-case name: their
  /// files may not exist yet, but their auto keys do.
  final Set<String> _createdEncrypted = {};

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// Every database, sorted by name, as of the last refresh.
  List<DatabaseInfo> get databases => _databases;

  /// Whether the database list has been loaded at least once.
  bool get hasLoaded => _hasLoaded;

  /// The selected database, or null. A database that was closed since it
  /// was selected (by the app, or deleted) is replaced by the instance now
  /// open under its name, if any.
  JustDatabase? get currentDatabase {
    final db = _current;
    if (db == null || db.isOpen) return db;
    return _current = JustDatabase.findOpen(db.name);
  }

  /// Whether a database is selected.
  bool get hasDatabaseOpen => currentDatabase != null;

  /// The listing of [name], or null.
  DatabaseInfo? infoFor(String name) {
    final key = name.toLowerCase();
    for (final d in _databases) {
      if (d.name.toLowerCase() == key) return d;
    }
    return null;
  }

  /// Whether the database [name] is encrypted (as far as the provider
  /// knows).
  bool isEncrypted(String name) =>
      (infoFor(name)?.isEncrypted ?? false) ||
      _createdEncrypted.contains(name.toLowerCase());

  /// The mode new databases get by default.
  DatabaseMode get defaultMode => _defaultMode;

  /// Whether new databases are saved by default. Opening a saved database
  /// always loads it from storage, whatever this says.
  bool get persistEnabled => _persistEnabled;

  /// The result of the last statement run with [runQuery].
  QueryResult? get lastQueryResult => _lastQueryResult;

  /// Why the last [runQuery] failed, or null.
  String? get lastQueryError => _lastQueryError;

  /// How many statements the last [runQuery] ran (more than one for a
  /// script).
  int get lastStatementCount => _lastStatementCount;

  /// Why the last action (other than a query) failed, or null.
  String? get lastError => _lastError;

  /// Whether an action is running.
  bool get isLoading => _busy > 0;

  /// Statements that ran successfully, newest first (at most 50).
  List<String> get queryHistory => List.unmodifiable(_queryHistory);

  // ---------------------------------------------------------------------------
  // Names
  // ---------------------------------------------------------------------------

  /// Why [name] cannot be used for a new database, or null when it can: it
  /// must be a valid name (see `JustDatabase.open`) not used by an existing
  /// database.
  String? checkNewDatabaseName(String name) {
    final problem = databaseNameProblem(name);
    if (problem != null) return problem;
    if (infoFor(name) != null || JustDatabase.findOpen(name) != null) {
      return 'A database named "$name" already exists.';
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Databases
  // ---------------------------------------------------------------------------

  /// Reloads the database list.
  Future<bool> refreshDatabases() =>
      _run('Could not list the databases', _reload);

  Future<void> _reload() async {
    final list = await DatabaseManager.listDatabases();
    if (_disposed) return;
    _databases = List.unmodifiable(list);
    _hasLoaded = true;
    _held.removeWhere((_, db) => !db.isOpen);
  }

  Future<void> _reloadQuietly() async {
    try {
      await _reload();
    } catch (_) {
      // The action itself succeeded; the list is refreshed next time.
    }
  }

  /// Creates the database [name] and selects it.
  ///
  /// [mode] and [persist] default to [defaultMode] and [persistEnabled].
  /// With [encrypted] the file is AES-256-GCM encrypted with a random key
  /// that `SecureKeyManager.resolveAutoKey` keeps in the app's private
  /// storage; an encrypted database is always saved.
  ///
  /// Fails when the name is invalid or already used.
  Future<bool> createDatabase(
    String name, {
    DatabaseMode? mode,
    bool? persist,
    bool encrypted = false,
  }) async {
    final problem = databaseNameProblem(name);
    if (problem != null) return _fail('Invalid database name: $problem');
    return _run('Could not create "$name"', () async {
      await _reload();
      if (infoFor(name) != null || JustDatabase.findOpen(name) != null) {
        throw StateError('A database named "$name" already exists.');
      }
      String? key;
      var createdKey = false;
      if (encrypted) {
        createdKey = !await SecureKeyManager.hasAutoKey(dbName: name);
        key = await SecureKeyManager.resolveAutoKey(dbName: name);
      }
      final JustDatabase db;
      try {
        db = await JustDatabase.open(
          name,
          mode: mode ?? _defaultMode,
          persist: encrypted || (persist ?? _persistEnabled),
          encryptionKey: key,
        );
      } catch (_) {
        if (createdKey) {
          try {
            await SecureKeyManager.clearAutoKey(dbName: name);
          } catch (_) {}
        }
        rethrow;
      }
      if (_disposed) {
        await db.close();
        return;
      }
      _held[name.toLowerCase()] = db;
      if (encrypted) _createdEncrypted.add(name.toLowerCase());
      _select(db);
      await _reloadQuietly();
    });
  }

  /// Selects the database [name], opening it from storage when it is not
  /// open. A database that is open already (by the app or by this
  /// provider) is used as it is: there is never a second instance.
  ///
  /// Returns whether [currentDatabase] is now [name]. Never creates a
  /// database: an unknown name fails.
  Future<bool> selectDatabase(String name) =>
      _run('Could not open "$name"', () async {
        final db = await _open(name);
        if (_disposed) return;
        _select(db);
      });

  void _select(JustDatabase db) {
    if (!identical(_current, db)) {
      _lastQueryResult = null;
      _lastQueryError = null;
      _lastStatementCount = 0;
    }
    _current = db;
  }

  Future<JustDatabase> _open(String name) async {
    final open = JustDatabase.findOpen(name);
    if (open != null) return open;
    await _reload();
    final info = infoFor(name);
    if (info == null) throw StateError('There is no database named "$name".');
    final again = JustDatabase.findOpen(name);
    if (again != null) return again;
    String? key;
    if (info.isEncrypted) {
      if (!await SecureKeyManager.hasAutoKey(dbName: info.name)) {
        throw StateError(
          '"${info.name}" is encrypted with a key this screen does not have '
          '(it was not created here). Open it in the app first; it then '
          'appears here as open.',
        );
      }
      key = await SecureKeyManager.resolveAutoKey(dbName: info.name);
    }
    // A database that is not open is a saved one: always open it from
    // storage (persist: true), whatever the default for new databases is.
    final db = await JustDatabase.open(
      info.name,
      mode: _defaultMode,
      persist: true,
      encryptionKey: key,
    );
    if (_disposed) {
      await db.close();
      throw StateError('The admin screen was closed.');
    }
    final lower = info.name.toLowerCase();
    if (identical(_held[lower], db)) {
      // Two selections raced: keep a single reference.
      await db.close();
    } else {
      _held[lower] = db;
    }
    await _reloadQuietly();
    return db;
  }

  /// Deletes the database [name]: closes it for everyone using it, deletes
  /// its file and then, for an encrypted database, its stored key.
  Future<bool> deleteDatabase(String name) =>
      _run('Could not delete "$name"', () async {
        await _reloadQuietly();
        final encrypted = isEncrypted(name);
        await _delete(name, encrypted);
        await _reloadQuietly();
      });

  Future<void> _delete(String name, bool encrypted) async {
    final lower = name.toLowerCase();
    if (_current?.name.toLowerCase() == lower) {
      _current = null;
      _lastQueryResult = null;
      _lastQueryError = null;
    }
    _held.remove(lower);
    // Throws when the file cannot be deleted: the key is then kept, so the
    // database can still be opened.
    await DatabaseManager.deleteDatabase(name);
    if (encrypted) {
      await SecureKeyManager.clearAutoKey(dbName: name);
      _createdEncrypted.remove(lower);
    }
  }

  /// Deletes every database (see [deleteDatabase]), including the stored
  /// keys of encrypted ones. Fails, after deleting what it could, when a
  /// database could not be deleted.
  Future<bool> clearAllDatabases() =>
      _run('Could not delete every database', () async {
        await _reload();
        final failures = <String>[];
        for (final info in List.of(_databases)) {
          try {
            await _delete(info.name, isEncrypted(info.name));
          } catch (e) {
            failures.add('${info.name}: ${describeError(e)}');
          }
        }
        _current = null;
        _lastQueryResult = null;
        _lastQueryError = null;
        await _reloadQuietly();
        if (failures.isNotEmpty) throw StateError(failures.join('; '));
      });

  // ---------------------------------------------------------------------------
  // Queries
  // ---------------------------------------------------------------------------

  /// Runs [sql] on [currentDatabase] with `execute`, which runs statements
  /// of every kind (SELECT included). Several statements separated by `;`
  /// run with `executeScript`, which stops at the first failure; the last
  /// result is kept.
  Future<bool> runQuery(String sql) async {
    if (_disposed) return false;
    final db = currentDatabase;
    if (db == null) {
      _lastQueryError = 'No database selected. Open one on the Databases tab.';
      _notify();
      return false;
    }
    if (sql.trim().isEmpty) return false;
    _busy++;
    _lastQueryError = null;
    _notify();
    try {
      // A script of one statement is just that statement.
      final results = await db.executeScript(sql);
      final count = results.length;
      final result = results.isEmpty ? QueryResult.success() : results.last;
      final failedAt = result.success ? 0 : results.length;
      if (_disposed) return false;
      _lastQueryResult = result;
      _lastStatementCount = count;
      if (result.success) {
        _addToHistory(sql.trim());
      } else {
        final message = result.errorMessage ?? 'The statement failed.';
        _lastQueryError = failedAt > 1
            ? 'Statement $failedAt failed: $message '
                  '(the ${plural(failedAt - 1, 'statement')} before it ran).'
            : message;
      }
      if (count > 1 || result.columns.isEmpty) unawaited(_reloadAndNotify());
      return result.success;
    } catch (e) {
      _lastQueryResult = null;
      _lastQueryError = describeError(e);
      return false;
    } finally {
      _busy--;
      _notify();
    }
  }

  Future<void> _reloadAndNotify() async {
    await _reloadQuietly();
    _notify();
  }

  /// Forgets the last query result and error.
  void clearQueryResult() {
    _lastQueryResult = null;
    _lastQueryError = null;
    _lastStatementCount = 0;
    _notify();
  }

  /// Forgets [lastError].
  void clearLastError() {
    if (_lastError == null) return;
    _lastError = null;
    _notify();
  }

  void _addToHistory(String sql) {
    _queryHistory
      ..remove(sql)
      ..insert(0, sql);
    if (_queryHistory.length > 50) _queryHistory.removeLast();
  }

  // ---------------------------------------------------------------------------
  // Settings
  // ---------------------------------------------------------------------------

  /// Sets whether new databases are saved by default.
  void setPersistEnabled(bool value) {
    _persistEnabled = value;
    _notify();
  }

  /// Sets the mode of new databases (and of saved ones this provider
  /// opens).
  void setDefaultMode(DatabaseMode mode) {
    _defaultMode = mode;
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Closes the databases this provider opened (the app's own stay open)
  /// and disposes [revision]. The provider must not be used afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    revision.dispose();
    final held = List.of(_held.values);
    _held.clear();
    _current = null;
    for (final db in held) {
      try {
        await db.close();
      } catch (_) {
        // A failed final save was already reported to onSaveError.
      }
    }
  }

  Future<bool> _run(String failure, Future<void> Function() action) async {
    if (_disposed) return false;
    _busy++;
    _lastError = null;
    _notify();
    try {
      await action();
      return true;
    } catch (e) {
      _lastError = '$failure: ${describeError(e)}';
      return false;
    } finally {
      _busy--;
      _notify();
    }
  }

  bool _fail(String message) {
    _lastError = message;
    _notify();
    return false;
  }

  void _notify() {
    if (_disposed) return;
    revision.value++;
  }
}

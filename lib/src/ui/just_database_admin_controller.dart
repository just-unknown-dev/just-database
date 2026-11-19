import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/database_change.dart';
import '../core/database_manager.dart';
import '../core/database_mode.dart';
import '../core/just_database.dart';
import '../core/secure_key_manager.dart';
import 'admin_preferences.dart';
import 'admin_selection.dart';
import 'admin_utils.dart';

/// Fills a database with sample data (the admin screen's "Seed sample
/// data" action).
typedef SeedDatabaseCallback = Future<void> Function(JustDatabase db);

/// How the admin screen protects a database it creates or re-encrypts.
@internal
enum AdminEncryption {
  /// Not encrypted.
  none,

  /// A random key kept by `SecureKeyManager.resolveAutoKey` in the app's
  /// private storage.
  randomKey,

  /// A passphrase the user types (kept in memory for this session only).
  passphrase,
}

/// The formats a database can be exported to and imported from.
@internal
enum BackupFormat {
  sql('SQL script', 'sql'),
  json('JSON', 'json');

  const BackupFormat(this.label, this.extension);

  final String label;
  final String extension;

  /// The format [text] is in: JSON when it starts with `{`.
  static BackupFormat detect(String text) =>
      text.trimLeft().startsWith('{') ? json : sql;
}

class _NeedsPassphrase implements Exception {
  const _NeedsPassphrase(this.name);
  final String name;
  @override
  String toString() => '"$name" is encrypted: enter its passphrase.';
}

/// The state behind `JustDatabaseAdminScreen`: the databases, which one is
/// shown, the screen's settings, and the actions it offers.
///
/// It lists every database: the ones open in this app (whoever opened
/// them) and the saved ones. Showing a database that is open uses that
/// instance, so the screen and the app share it; showing a closed one opens
/// it. Databases the controller opened itself are closed by [dispose].
///
/// The list and the open databases are watched
/// ([DatabaseManager.listChanges], [JustDatabase.changes]), so the screen
/// stays current while the app works.
///
/// Pass one to several screens, or keep it to choose what the screen shows:
///
/// ```dart
/// final admin = JustDatabaseAdminController(readOnly: true);
/// await admin.selectDatabase('scores');
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => JustDatabaseAdminScreen(controller: admin),
/// ));
/// ```
class JustDatabaseAdminController extends ChangeNotifier {
  /// Creates a controller and starts listing the databases.
  ///
  /// With [readOnly] the screen offers nothing that writes: no inserts,
  /// edits, deletes, imports, schema changes or encryption changes, and its
  /// SQL console only runs reads. [defaultMode] and [persistByDefault] are
  /// the first defaults for new databases; with [rememberSettings] the
  /// screen's settings, SQL history and snippets are kept between runs
  /// (with just_storage) and override them.
  JustDatabaseAdminController({
    this.readOnly = false,
    DatabaseMode defaultMode = DatabaseMode.standard,
    bool persistByDefault = true,
    this.rememberSettings = true,
  }) : _prefs = AdminPreferences(
         remember: rememberSettings,
         defaultMode: defaultMode,
         persistByDefault: persistByDefault,
       ) {
    _listSub = DatabaseManager.listChanges.listen((_) => _scheduleReload());
    unawaited(_prefs.load().then((_) => _notify()));
    unawaited(refresh());
  }

  /// Whether the screen offers only actions that do not write.
  final bool readOnly;

  /// Whether settings, history and snippets are kept between runs.
  final bool rememberSettings;

  final AdminPreferences _prefs;
  List<DatabaseInfo> _databases = const [];
  bool _hasLoaded = false;
  int _busy = 0;
  String? _lastError;
  bool _disposed = false;
  AdminSelection? _selection;

  /// Databases this controller opened (one reference each), by lower-case
  /// name.
  final Map<String, JustDatabase> _held = {};

  /// Passphrases typed this session, by lower-case name.
  final Map<String, String> _passphrases = {};

  final Map<String, StreamSubscription<DatabaseChange>> _watching = {};
  final Map<String, Object> _paneStates = {};
  late final StreamSubscription<void> _listSub;
  Timer? _reloadTimer;
  Timer? _notifyTimer;

  // ---------------------------------------------------------------------------
  // State
  // ---------------------------------------------------------------------------

  /// Every database, sorted by name, as of the last refresh.
  List<DatabaseInfo> get databases => _databases;

  /// Whether the list has been loaded at least once.
  bool get hasLoaded => _hasLoaded;

  /// Whether an action is running.
  bool get isBusy => _busy > 0;

  /// Why the last action failed, or null.
  String? get lastError => _lastError;

  /// The database shown, or null (also when it was closed).
  JustDatabase? get database {
    final s = _selection;
    return s == null ? null : JustDatabase.findOpen(s.database);
  }

  /// What the screen shows.
  @internal
  AdminSelection? get selection => _selection;

  /// The listing of [name], or null.
  @internal
  DatabaseInfo? infoFor(String name) {
    final key = name.toLowerCase();
    for (final d in _databases) {
      if (d.name.toLowerCase() == key) return d;
    }
    return null;
  }

  /// Whether [name] is encrypted, as far as the listing knows.
  @internal
  bool isEncrypted(String name) => infoFor(name)?.isEncrypted ?? false;

  /// Whether this controller opened [name] (so it may close it).
  @internal
  bool opened(String name) => _held.containsKey(name.toLowerCase());

  /// Whether [name] can be reopened in another mode: the screen opened it
  /// and nobody else uses it.
  @internal
  bool canChangeMode(String name) {
    final db = _held[name.toLowerCase()];
    return db != null && db.isOpen && db.openerCount == 1;
  }

  /// Forgets [lastError].
  @internal
  void clearError() {
    if (_lastError == null) return;
    _lastError = null;
    _notify();
  }

  /// Per-pane state that survives switching panes, created on first use.
  @internal
  T paneState<T extends Object>(String key, T Function() create) {
    final existing = _paneStates[key];
    if (existing is T) return existing;
    final created = create();
    _paneStates[key] = created;
    return created;
  }

  // ---------------------------------------------------------------------------
  // Settings, history, snippets
  // ---------------------------------------------------------------------------

  /// The mode of new databases (and of saved ones the screen opens).
  DatabaseMode get defaultMode => _prefs.defaultMode;

  /// Sets [defaultMode].
  void setDefaultMode(DatabaseMode mode) {
    _prefs.defaultMode = mode;
    _prefs.changed();
    _notify();
  }

  /// Whether new databases are saved by default.
  bool get persistByDefault => _prefs.persistByDefault;

  /// Sets [persistByDefault].
  void setPersistByDefault(bool value) {
    _prefs.persistByDefault = value;
    _prefs.changed();
    _notify();
  }

  /// Rows per page in the data browser.
  @internal
  int get pageSize => _prefs.pageSize;

  /// Sets [pageSize].
  @internal
  void setPageSize(int size) {
    _prefs.pageSize = size;
    _prefs.changed();
    _notify();
  }

  /// The SQL console's runs, newest first.
  @internal
  List<HistoryEntry> get history => List.unmodifiable(_prefs.history);

  /// Adds a run to [history].
  @internal
  void addHistory(HistoryEntry entry) {
    _prefs.history
      ..removeWhere(
        (h) =>
            h.sql == entry.sql &&
            h.database.toLowerCase() == entry.database.toLowerCase(),
      )
      ..insert(0, entry);
    if (_prefs.history.length > AdminPreferences.maxHistory) {
      _prefs.history.removeLast();
    }
    _prefs.changed();
    _notify();
  }

  /// Empties [history].
  @internal
  void clearHistory() {
    _prefs.history.clear();
    _prefs.changed();
    _notify();
  }

  /// The saved statements.
  @internal
  List<SqlSnippet> get snippets => List.unmodifiable(_prefs.snippets);

  /// Saves [sql] as [name], replacing a snippet of that name.
  @internal
  void saveSnippet(String name, String sql) {
    final i = _prefs.snippets.indexWhere((s) => s.name == name);
    final snippet = SqlSnippet(name: name, sql: sql);
    if (i < 0) {
      _prefs.snippets.add(snippet);
    } else {
      _prefs.snippets[i] = snippet;
    }
    _prefs.changed();
    _notify();
  }

  /// Deletes the snippet [name].
  @internal
  void deleteSnippet(String name) {
    _prefs.snippets.removeWhere((s) => s.name == name);
    _prefs.changed();
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Listing and selecting
  // ---------------------------------------------------------------------------

  /// Reloads the list of databases. Returns false (see [lastError]) when it
  /// cannot be read.
  Future<bool> refresh() => _run('Could not list the databases', _reload);

  Future<void> _reload() async {
    final list = await DatabaseManager.listDatabases();
    if (_disposed) return;
    _databases = List.unmodifiable(list);
    _hasLoaded = true;
    _held.removeWhere((_, db) => !db.isOpen);
    _watchOpenDatabases();
    final s = _selection;
    if (s != null &&
        JustDatabase.findOpen(s.database) == null &&
        infoFor(s.database) == null) {
      _selection = null;
    }
  }

  Future<void> _reloadQuietly() async {
    try {
      await _reload();
    } catch (_) {
      // The action itself succeeded; the next refresh tries again.
    }
  }

  void _scheduleReload() {
    if (_disposed) return;
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 120), () async {
      _reloadTimer = null;
      await _reloadQuietly();
      _notify();
    });
  }

  void _watchOpenDatabases() {
    final open = {
      for (final db in JustDatabase.openDatabases) db.name.toLowerCase(): db,
    };
    _watching.removeWhere((key, sub) {
      if (open.containsKey(key)) return false;
      unawaited(sub.cancel());
      return true;
    });
    for (final MapEntry(:key, value: db) in open.entries) {
      _watching[key] ??= db.changes.listen(
        (_) => _scheduleNotify(),
        onDone: () {
          _watching.remove(key);
          _scheduleReload();
        },
      );
    }
  }

  void _scheduleNotify() {
    if (_disposed || _notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 100), () {
      _notifyTimer = null;
      _checkSelection();
      _notify();
    });
  }

  /// Falls back to the database when the selected object is gone.
  void _checkSelection() {
    final s = _selection;
    final kind = s?.kind;
    if (s == null || kind == null) return;
    final db = JustDatabase.findOpen(s.database);
    if (db == null) return;
    final exists = switch (kind) {
      AdminObjectKind.table => db.getTableSchema(s.object!) != null,
      AdminObjectKind.view => db.getViewSql(s.object!) != null,
      AdminObjectKind.trigger => db.getTriggerSql(s.object!) != null,
    };
    if (!exists) _selection = AdminSelection(s.database);
  }

  /// Shows [selection]; opens its database first when it is closed.
  /// Returns false when it cannot be opened (see [lastError] and
  /// [passphraseNeededFor]).
  @internal
  Future<bool> select(AdminSelection selection) async {
    if (JustDatabase.findOpen(selection.database) == null) {
      if (!await open(selection.database)) return false;
    }
    _selection = selection;
    _checkSelection();
    _notify();
    return true;
  }

  /// Shows the pane [pane] of the current selection.
  @internal
  void showPane(AdminPane pane) {
    final s = _selection;
    if (s == null || s.pane == pane) return;
    _selection = s.withPane(pane);
    _notify();
  }

  /// Stops showing a database.
  @internal
  void clearSelection() {
    if (_selection == null) return;
    _selection = null;
    _notify();
  }

  /// Shows the database [name], opening it when it is closed. Returns
  /// false (see [lastError]) when it cannot be opened, for example an
  /// encrypted database whose passphrase the screen does not know.
  Future<bool> selectDatabase(String name) => select(AdminSelection(name));

  // ---------------------------------------------------------------------------
  // Opening and closing
  // ---------------------------------------------------------------------------

  /// The database the last [open] needed a passphrase for, or null.
  @internal
  String? passphraseNeededFor;

  /// Opens the saved database [name] (in [mode], default [defaultMode]),
  /// or uses it when it is open already. An encrypted one needs
  /// [passphrase] unless this session knows it or a random key was stored
  /// for it; without one this fails and sets [passphraseNeededFor].
  @internal
  Future<bool> open(String name, {DatabaseMode? mode, String? passphrase}) {
    passphraseNeededFor = null;
    return _run('Could not open "$name"', () async {
      if (JustDatabase.findOpen(name) != null) return;
      await _reload();
      final info = infoFor(name);
      if (info == null) throw StateError('There is no database named "$name".');
      if (JustDatabase.findOpen(name) != null) return;
      final lower = info.name.toLowerCase();
      var key = passphrase;
      if (key == null && info.isEncrypted) {
        key = _passphrases[lower];
        if (key == null &&
            await SecureKeyManager.hasAutoKey(dbName: info.name)) {
          key = await SecureKeyManager.resolveAutoKey(dbName: info.name);
        }
        if (key == null) {
          passphraseNeededFor = info.name;
          throw _NeedsPassphrase(info.name);
        }
      }
      final db = await JustDatabase.open(
        info.name,
        mode: mode ?? defaultMode,
        encryptionKey: key,
      );
      if (passphrase != null) _passphrases[lower] = passphrase;
      await _hold(db);
      await _reloadQuietly();
    });
  }

  Future<void> _hold(JustDatabase db) async {
    final lower = db.name.toLowerCase();
    if (_disposed) {
      await db.close();
      throw StateError('The admin screen was closed.');
    }
    if (identical(_held[lower], db)) {
      await db.close(); // two opens raced: keep one reference
    } else {
      _held[lower] = db;
    }
  }

  /// Closes [name] for the screen. Only a database the screen opened can
  /// be closed; one the app opened stays open for the app.
  @internal
  Future<bool> close(String name) => _run('Could not close "$name"', () async {
    final db = _held.remove(name.toLowerCase());
    if (db == null) {
      throw StateError(
        '"$name" was opened by the app; only the app closes it.',
      );
    }
    await db.close();
    await _reloadQuietly();
  });

  /// Reopens [name] in [mode]. Only possible when [canChangeMode].
  @internal
  Future<bool> reopen(String name, DatabaseMode mode) async {
    final ok = await _run('Could not reopen "$name"', () async {
      if (!canChangeMode(name)) {
        throw StateError(
          'the app uses "$name" too; its mode can only change while the '
          'screen is its only user',
        );
      }
      final db = _held.remove(name.toLowerCase())!;
      await db.close();
    });
    if (!ok) return false;
    return open(name, mode: mode);
  }

  /// Waits until every committed change of [name] is saved.
  @internal
  Future<bool> flush(String name) => _run('Could not save "$name"', () async {
    await _openOrThrow(name).flush();
    await _reloadQuietly();
  });

  JustDatabase _openOrThrow(String name) =>
      JustDatabase.findOpen(name) ?? (throw StateError('"$name" is not open.'));

  // ---------------------------------------------------------------------------
  // Creating, duplicating, deleting
  // ---------------------------------------------------------------------------

  /// Why [name] cannot name a new database (invalid, or taken), or null.
  @internal
  String? checkNewName(String name) {
    final problem = databaseNameProblem(name);
    if (problem != null) return problem;
    if (infoFor(name) != null || JustDatabase.findOpen(name) != null) {
      return 'A database named "$name" already exists.';
    }
    return null;
  }

  void _checkWritable() {
    if (readOnly) throw StateError('the admin screen is read-only');
  }

  /// Creates the database [name] and shows it. An encrypted database is
  /// always saved.
  @internal
  Future<bool> create(
    String name, {
    DatabaseMode? mode,
    bool? persist,
    AdminEncryption encryption = AdminEncryption.none,
    String? passphrase,
  }) => _run('Could not create "$name"', () async {
    await _create(
      name,
      mode: mode,
      persist: persist,
      encryption: encryption,
      passphrase: passphrase,
    );
    _selection = AdminSelection(name);
    await _reloadQuietly();
  });

  Future<JustDatabase> _create(
    String name, {
    DatabaseMode? mode,
    bool? persist,
    AdminEncryption encryption = AdminEncryption.none,
    String? passphrase,
  }) async {
    _checkWritable();
    final problem = databaseNameProblem(name);
    if (problem != null) throw ArgumentError(problem);
    await _reload();
    if (infoFor(name) != null || JustDatabase.findOpen(name) != null) {
      throw StateError('a database named "$name" already exists');
    }
    String? key;
    var createdKey = false;
    switch (encryption) {
      case AdminEncryption.none:
        break;
      case AdminEncryption.randomKey:
        createdKey = !await SecureKeyManager.hasAutoKey(dbName: name);
        key = await SecureKeyManager.resolveAutoKey(dbName: name);
      case AdminEncryption.passphrase:
        if (passphrase == null || passphrase.isEmpty) {
          throw ArgumentError('enter a passphrase');
        }
        key = passphrase;
    }
    final JustDatabase db;
    try {
      db = await JustDatabase.open(
        name,
        mode: mode ?? defaultMode,
        persist: key != null || (persist ?? persistByDefault),
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
    if (encryption == AdminEncryption.passphrase) {
      _passphrases[name.toLowerCase()] = passphrase!;
    }
    await _hold(db);
    return db;
  }

  /// Copies [source] (which must be open) into the new database [target]
  /// and shows the copy.
  @internal
  Future<bool> duplicate(
    String source,
    String target, {
    AdminEncryption encryption = AdminEncryption.none,
    String? passphrase,
  }) => _run('Could not copy "$source"', () async {
    _checkWritable();
    final from = _openOrThrow(source);
    final json = await from.exportJson();
    final copy = await _create(
      target,
      mode: from.mode,
      persist: from.persist,
      encryption: encryption,
      passphrase: passphrase,
    );
    try {
      await copy.importJson(json);
    } catch (_) {
      await _delete(copy.name);
      rethrow;
    }
    _selection = AdminSelection(copy.name);
    await _reloadQuietly();
  });

  /// Deletes [name]: closes it for everyone using it (the app included),
  /// deletes its file and its stored random key.
  @internal
  Future<bool> delete(String name) =>
      _run('Could not delete "$name"', () async {
        _checkWritable();
        await _delete(name);
        await _reloadQuietly();
      });

  Future<void> _delete(String name) async {
    final lower = name.toLowerCase();
    if (_selection?.database.toLowerCase() == lower) _selection = null;
    _held.remove(lower);
    _passphrases.remove(lower);
    _paneStates.removeWhere((k, state) {
      if (!k.startsWith('$lower/')) return false;
      if (state is ChangeNotifier) state.dispose();
      return true;
    });
    // Throws when the file cannot be deleted: the key is then kept, so the
    // database can still be opened.
    await DatabaseManager.deleteDatabase(name);
    if (await SecureKeyManager.hasAutoKey(dbName: name)) {
      await SecureKeyManager.clearAutoKey(dbName: name);
    }
  }

  /// Deletes every database (see [delete]). Fails, after deleting what it
  /// could, when one could not be deleted.
  @internal
  Future<bool> deleteAll() => _run('Could not delete every database', () async {
    _checkWritable();
    await _reload();
    final names = {
      for (final d in _databases) d.name,
      for (final db in JustDatabase.openDatabases) db.name,
    };
    final failures = <String>[];
    for (final name in names) {
      try {
        await _delete(name);
      } catch (e) {
        failures.add('$name: ${describeError(e)}');
      }
    }
    _selection = null;
    await _reloadQuietly();
    if (failures.isNotEmpty) throw StateError(failures.join('; '));
  });

  /// Runs [seed] on [name] (opening it first).
  @internal
  Future<bool> seed(String name, SeedDatabaseCallback seed) =>
      _run('Seeding "$name" failed', () async {
        _checkWritable();
        if (JustDatabase.findOpen(name) == null && !await open(name)) {
          throw StateError(_lastError ?? 'could not open "$name"');
        }
        await seed(_openOrThrow(name));
        await _reloadQuietly();
      });

  // ---------------------------------------------------------------------------
  // Encryption
  // ---------------------------------------------------------------------------

  /// Encrypts, re-keys or decrypts the saved database [name], which must be
  /// open. The app must open it with the new passphrase from then on.
  @internal
  Future<bool> setEncryption(
    String name,
    AdminEncryption encryption, {
    String? passphrase,
  }) => _run('Could not change the encryption of "$name"', () async {
    _checkWritable();
    final db = _openOrThrow(name);
    if (!db.persist) {
      throw StateError('an in-memory database has no file to encrypt');
    }
    final lower = name.toLowerCase();
    final hadAutoKey = await SecureKeyManager.hasAutoKey(dbName: name);
    switch (encryption) {
      case AdminEncryption.none:
        await db.changeEncryptionKey(null);
        _passphrases.remove(lower);
        if (hadAutoKey) await SecureKeyManager.clearAutoKey(dbName: name);
      case AdminEncryption.randomKey:
        final key = await SecureKeyManager.resolveAutoKey(dbName: name);
        await db.changeEncryptionKey(key);
        _passphrases.remove(lower);
      case AdminEncryption.passphrase:
        if (passphrase == null || passphrase.isEmpty) {
          throw ArgumentError('enter a passphrase');
        }
        await db.changeEncryptionKey(passphrase);
        _passphrases[lower] = passphrase;
        // A stale random key would be tried (and fail) before asking.
        if (hadAutoKey) await SecureKeyManager.clearAutoKey(dbName: name);
    }
    await _reloadQuietly();
  });

  // ---------------------------------------------------------------------------
  // Backup and restore
  // ---------------------------------------------------------------------------

  /// [name] (which must be open) as [format] text, or null on failure
  /// (see [lastError]).
  @internal
  Future<String?> exportText(String name, BackupFormat format) async {
    String? text;
    final ok = await _run('Could not export "$name"', () async {
      final db = _openOrThrow(name);
      text = switch (format) {
        BackupFormat.sql => await db.exportSql(),
        BackupFormat.json => const JsonEncoder.withIndent(
          '  ',
        ).convert(await db.exportJson()),
      };
    });
    return ok ? text : null;
  }

  /// Replaces the contents of [name] (which must be open) with [text], a
  /// SQL script or a JSON export.
  @internal
  Future<bool> importInto(String name, String text) =>
      _run('Could not import into "$name"', () async {
        _checkWritable();
        await _import(_openOrThrow(name), text);
        await _reloadQuietly();
      });

  /// Creates the database [name] from [text] (a SQL script or a JSON
  /// export) and shows it.
  @internal
  Future<bool> importAsNew(
    String name,
    String text, {
    DatabaseMode? mode,
    bool? persist,
    AdminEncryption encryption = AdminEncryption.none,
    String? passphrase,
  }) => _run('Could not import "$name"', () async {
    final db = await _create(
      name,
      mode: mode,
      persist: persist,
      encryption: encryption,
      passphrase: passphrase,
    );
    try {
      await _import(db, text);
    } catch (_) {
      await _delete(db.name);
      rethrow;
    }
    _selection = AdminSelection(db.name);
    await _reloadQuietly();
  });

  Future<void> _import(JustDatabase db, String text) async {
    switch (BackupFormat.detect(text)) {
      case BackupFormat.json:
        final Object? json;
        try {
          json = jsonDecode(text);
        } on FormatException catch (e) {
          throw FormatException('the JSON could not be read: ${e.message}');
        }
        if (json is! Map<String, Object?>) {
          throw const FormatException('the JSON is not a database export');
        }
        await db.importJson(json);
      case BackupFormat.sql:
        await db.importSql(text);
    }
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Stops watching, saves a pending settings change, and closes the
  /// databases this controller opened (the app's own stay open).
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _reloadTimer?.cancel();
    _notifyTimer?.cancel();
    unawaited(_listSub.cancel());
    for (final sub in _watching.values) {
      unawaited(sub.cancel());
    }
    _watching.clear();
    _prefs.dispose();
    for (final state in _paneStates.values) {
      if (state is ChangeNotifier) state.dispose();
    }
    _paneStates.clear();
    final held = List.of(_held.values);
    _held.clear();
    _passphrases.clear();
    for (final db in held) {
      // A failed final save was already reported to onSaveError.
      unawaited(db.close().catchError((Object _) {}));
    }
    super.dispose();
  }

  /// Runs [action], counting it as busy; returns whether it succeeded and
  /// keeps the failure in [lastError].
  Future<bool> _run(String failure, Future<void> Function() action) async {
    if (_disposed) return false;
    _busy++;
    _lastError = null;
    _notify();
    try {
      await action();
      return true;
    } on _NeedsPassphrase catch (e) {
      _lastError = '$e';
      return false;
    } catch (e) {
      _lastError = '$failure: ${describeError(e)}';
      return false;
    } finally {
      _busy--;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }
}

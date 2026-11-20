/// The app's side of a workbench connected over the Dart VM service (the
/// just_database DevTools extension), in debug builds.
@internal
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' show max;

import 'package:flutter/foundation.dart'
    show debugPrint, internal, visibleForTesting;

import '../storage/values.dart';
import 'benchmark.dart';
import 'database_change.dart';
import 'database_manager.dart';
import 'database_mode.dart';
import 'just_database.dart';
import 'secure_key_manager.dart';
import 'version.dart';
import 'workbench_wire.dart';

/// How the workbench protects a database it creates or re-encrypts.
enum AdminEncryption {
  /// Not encrypted.
  none,

  /// A random key kept by `SecureKeyManager.resolveAutoKey` in the app's
  /// private storage.
  randomKey,

  /// A passphrase the user types (the workbench keeps it in memory for the
  /// session only).
  passphrase,
}

/// Serves a workbench in another process: one service extension
/// ([workbenchExtension]) that runs [handle], and events
/// ([workbenchListEvent], [workbenchChangeEvent]) while a workbench is
/// connected.
///
/// `JustDatabase.open` registers it in debug builds (unless
/// `JustDatabase.debugDevToolsWorkbench` is false). Nothing runs on the
/// app's writes while no workbench is connected.
abstract final class WorkbenchService {
  static bool _registered = false;
  static bool _watching = false;
  static int _sessionCount = 0;

  /// The databases each workbench session opened, by lower-case name; a
  /// session closes them when it disconnects.
  static final Map<String, Map<String, JustDatabase>> _sessions = {};

  static final StreamController<(String, Map<String, Object?>)> _events =
      StreamController.broadcast(sync: true);
  static StreamSubscription<void>? _listSub;
  static final Map<String, StreamSubscription<DatabaseChange>> _changeSubs = {};
  static final Map<String, _PendingChange> _pending = {};

  /// The events posted to connected workbenches: (kind, data).
  static Stream<(String, Map<String, Object?>)> get events => _events.stream;

  /// How long changes of one database are gathered into one event.
  static const Duration changeDelay = Duration(milliseconds: 100);

  /// Registers the service extension (once per isolate) and says in the
  /// console how to open the workbench.
  static void register() {
    if (_registered) return;
    _registered = true;
    try {
      developer.registerExtension(workbenchExtension, (_, params) async {
        Map<String, Object?> args;
        try {
          final decoded = jsonDecode(params['args'] ?? '{}');
          args = decoded is Map<String, Object?> ? decoded : const {};
        } on FormatException {
          args = const {};
        }
        final reply = await handle(params['method'] ?? '', args);
        return developer.ServiceExtensionResponse.result(jsonEncode(reply));
      });
    } on ArgumentError {
      return; // registered already (by an earlier copy of this code)
    }
    _events.stream.listen((e) => developer.postEvent(e.$1, e.$2));
    unawaited(_announce());
  }

  static Future<void> _announce() async {
    final developer.ServiceProtocolInfo info;
    try {
      info = await developer.Service.getInfo();
    } on UnsupportedError {
      return; // the web: the app can't learn its address (DevTools still can)
    }
    final uri = info.serverUri;
    final ws = info.serverWebSocketUri;
    if (uri == null || ws == null) return; // no VM service: nothing connects
    debugPrint(
      workbenchBanner(
        uri.resolve('devtools/$workbenchScreen?uri=$ws').toString(),
      ),
    );
  }

  /// The DevTools screen of the extension (DevTools names it after the
  /// package).
  static const String workbenchScreen = 'just_database_ext';

  /// What the console says when the service starts: [link] opens the
  /// workbench in the DevTools that `flutter run` serves.
  @visibleForTesting
  static String workbenchBanner(String link) {
    final lines = [
      'Just Database workbench (debug builds)',
      null,
      'Open it in Flutter DevTools, the "just_database" tab:',
      link,
      'On a phone or emulator, open the DevTools link flutter run',
      'prints instead and choose that tab. Enable it when asked.',
    ];
    final width = [for (final l in lines) l?.length ?? 0].reduce(max) + 2;
    return [
      '╔${'═' * width}╗',
      for (final l in lines)
        l == null ? '╟${'─' * width}╢' : '║ ${l.padRight(width - 2)} ║',
      '╚${'═' * width}╝',
    ].join('\n');
  }

  /// Runs the workbench call [method] with [args] (decoded JSON). The reply
  /// is `{'ok': true, ...}` or `{'ok': false, 'error': ...}`
  /// (see [encodeError]).
  static Future<Map<String, Object?>> handle(
    String method,
    Map<String, Object?> args,
  ) async {
    try {
      return {'ok': true, ...await _dispatch(method, args)};
    } catch (e) {
      return {'ok': false, 'error': encodeError(e)};
    }
  }

  static Future<Map<String, Object?>> _dispatch(
    String method,
    Map<String, Object?> args,
  ) async {
    switch (method) {
      case 'connect':
        _watch();
        final session = 'w${++_sessionCount}';
        _sessions[session] = {};
        return {
          'protocol': workbenchProtocol,
          'version': kJustDatabaseVersion,
          'session': session,
        };
      case 'disconnect':
        final held = _sessions.remove(args['session']) ?? const {};
        if (_sessions.isEmpty) await _unwatch();
        for (final db in held.values) {
          await db.close().catchError((Object _) {});
        }
        return const {};
      case 'list':
        final list = await DatabaseManager.listDatabases();
        return {
          'databases': [for (final d in list) encodeDatabaseInfo(d)],
          'open': [for (final db in JustDatabase.openDatabases) _snapshot(db)],
        };
      case 'snapshot':
        final db = JustDatabase.findOpen(_string(args, 'database'));
        return {if (db != null) 'snapshot': _snapshot(db)};
      case 'open':
        final name = _string(args, 'database');
        final open = JustDatabase.findOpen(name);
        if (open != null) return {'snapshot': _snapshot(open)};
        final db = await openSaved(
          name,
          mode: _mode(args),
          passphrase: args['passphrase'] as String?,
          encrypted: args['encrypted'] == true,
        );
        if (db == null) return {'needsPassphrase': true};
        _hold(args, db);
        return {'snapshot': _snapshot(db)};
      case 'create':
        final db = await createDatabase(
          _string(args, 'database'),
          mode: _mode(args),
          persist: args['persist'] != false,
          encryption: _encryption(args),
          passphrase: args['passphrase'] as String?,
        );
        _hold(args, db);
        return {'snapshot': _snapshot(db)};
      case 'release':
        final db = _held(args).remove(_string(args, 'database').toLowerCase());
        if (db != null) await db.close();
        return const {};
      case 'delete':
        final name = _string(args, 'database');
        for (final held in _sessions.values) {
          held.remove(name.toLowerCase());
        }
        await deleteDatabase(name);
        return const {};
      case 'setEncryption':
        final db = _db(args);
        await setEncryption(
          db,
          _encryption(args),
          passphrase: args['passphrase'] as String?,
        );
        return {'snapshot': _snapshot(db)};
      case 'hasStoredKey':
        return {
          'value': await SecureKeyManager.hasAutoKey(
            dbName: _string(args, 'database'),
          ),
        };
      case 'execute':
        final db = _db(args);
        final result = await db.execute(
          _string(args, 'sql'),
          decodeParameters(args['parameters']),
        );
        return {'result': encodeResult(result), 'snapshot': _snapshot(db)};
      case 'query':
        final result = await _db(
          args,
        ).query(_string(args, 'sql'), decodeParameters(args['parameters']));
        return {'result': encodeResult(result)};
      case 'executeScript':
        final db = _db(args);
        final results = await db.executeScript(_string(args, 'sql'));
        return {
          'results': [for (final r in results) encodeResult(r)],
          'snapshot': _snapshot(db),
        };
      case 'deleteRows':
        final db = _db(args);
        await deleteRowsOf(db, _string(args, 'table'), [
          for (final id in args['rowids'] as List? ?? const []) id as int,
        ]);
        return {'snapshot': _snapshot(db)};
      case 'flush':
        final db = _db(args);
        await db.flush();
        return {'snapshot': _snapshot(db)};
      case 'exportSql':
        return {'text': await _db(args).exportSql()};
      case 'exportJson':
        return {'json': await _db(args).exportJson()};
      case 'importSql':
        final db = _db(args);
        await db.importSql(_string(args, 'text'));
        return {'snapshot': _snapshot(db)};
      case 'importJson':
        final db = _db(args);
        final json = args['json'];
        if (json is! Map<String, Object?>) {
          throw const FormatException('the JSON is not a database export');
        }
        await db.importJson(json);
        return {'snapshot': _snapshot(db)};
      case 'benchmark':
        final name = args['database'] as String?;
        final db = name == null ? null : _db(args);
        final rowCount = _int(args, 'rowCount');
        final warmup = _int(args, 'warmup');
        final iterations = _int(args, 'iterations');
        final result = db != null
            ? await db.runStandardBenchmark(
                rowCount: rowCount,
                warmup: warmup,
                iterations: iterations,
              )
            : await runStandardDatabaseBenchmark(
                rowCount: rowCount,
                warmup: warmup,
                iterations: iterations,
              );
        return {'suite': encodeSuiteResult(result)};
      case 'benchmarkQuery':
        final stats = await _db(args).benchmarkQuery(
          _string(args, 'label'),
          _string(args, 'sql'),
          warmup: _int(args, 'warmup'),
          iterations: _int(args, 'iterations'),
        );
        return {'stats': encodeQueryStats(stats)};
      default:
        throw ArgumentError('unknown workbench call "$method"');
    }
  }

  /// Deletes the rows [rowids] of [table] in one transaction; fails, and
  /// deletes nothing, when one of them is gone.
  static Future<void> deleteRowsOf(
    JustDatabase db,
    String table,
    List<int> rowids,
  ) => db.transaction((tx) async {
    for (final rowid in rowids) {
      final r = await tx.execute(
        'DELETE FROM ${quoteIdentifier(table)} WHERE rowid = ?',
        [rowid],
      );
      if (r.affectedRows != 1) {
        throw StateError('row $rowid no longer exists; nothing was deleted');
      }
    }
  });

  // ---------------------------------------------------------------------------
  // Opening, creating, encrypting and deleting, with the key handling both
  // the in-app screen and a connected workbench use (random keys never
  // leave the app)
  // ---------------------------------------------------------------------------

  /// Opens the saved database [name] in [mode] with [passphrase], or with
  /// the random key stored for it when it is [encrypted] and no passphrase
  /// is given. Returns null when it needs a passphrase nobody gave.
  static Future<JustDatabase?> openSaved(
    String name, {
    required DatabaseMode mode,
    String? passphrase,
    required bool encrypted,
  }) async {
    var key = passphrase;
    if (key == null && encrypted) {
      if (!await SecureKeyManager.hasAutoKey(dbName: name)) return null;
      key = await SecureKeyManager.resolveAutoKey(dbName: name);
    }
    return JustDatabase.open(name, mode: mode, encryptionKey: key);
  }

  /// Creates the database [name]. An encrypted one is always saved; a
  /// random key it made is removed again when the database cannot be
  /// created.
  static Future<JustDatabase> createDatabase(
    String name, {
    required DatabaseMode mode,
    required bool persist,
    AdminEncryption encryption = AdminEncryption.none,
    String? passphrase,
  }) async {
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
    try {
      return await JustDatabase.open(
        name,
        mode: mode,
        persist: key != null || persist,
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
  }

  /// Encrypts, re-keys or decrypts the saved database [db]; the app must
  /// open it with the new passphrase from then on.
  static Future<void> setEncryption(
    JustDatabase db,
    AdminEncryption encryption, {
    String? passphrase,
  }) async {
    final name = db.name;
    if (!db.persist) {
      throw StateError('an in-memory database has no file to encrypt');
    }
    final hadAutoKey = await SecureKeyManager.hasAutoKey(dbName: name);
    switch (encryption) {
      case AdminEncryption.none:
        await db.changeEncryptionKey(null);
        if (hadAutoKey) await SecureKeyManager.clearAutoKey(dbName: name);
      case AdminEncryption.randomKey:
        await db.changeEncryptionKey(
          await SecureKeyManager.resolveAutoKey(dbName: name),
        );
      case AdminEncryption.passphrase:
        if (passphrase == null || passphrase.isEmpty) {
          throw ArgumentError('enter a passphrase');
        }
        await db.changeEncryptionKey(passphrase);
        // A stale random key would be tried (and fail) before asking.
        if (hadAutoKey) await SecureKeyManager.clearAutoKey(dbName: name);
    }
  }

  /// Deletes [name]: closes it for everyone using it, deletes its file and
  /// its stored random key. Throws when the file cannot be deleted; the key
  /// is then kept, so the database can still be opened.
  static Future<void> deleteDatabase(String name) async {
    await DatabaseManager.deleteDatabase(name);
    if (await SecureKeyManager.hasAutoKey(dbName: name)) {
      await SecureKeyManager.clearAutoKey(dbName: name);
    }
  }

  static AdminEncryption _encryption(Map<String, Object?> args) =>
      AdminEncryption.values.asNameMap()[args['encryption']] ??
      (throw ArgumentError('unknown encryption "${args['encryption']}"'));

  // ---------------------------------------------------------------------------
  // Events
  // ---------------------------------------------------------------------------

  /// Starts posting events (the first time a workbench connects).
  static void _watch() {
    if (_watching) {
      _watchOpen();
      return;
    }
    _watching = true;
    _listSub = DatabaseManager.listChanges.listen((_) {
      _watchOpen();
      _events.add((workbenchListEvent, const {}));
    });
    _watchOpen();
  }

  static void _watchOpen() {
    final open = {
      for (final db in JustDatabase.openDatabases) db.name.toLowerCase(): db,
    };
    _changeSubs.removeWhere((key, sub) {
      if (open.containsKey(key)) return false;
      unawaited(sub.cancel());
      return true;
    });
    for (final MapEntry(:key, value: db) in open.entries) {
      _changeSubs[key] ??= db.changes.listen(
        (change) => _gather(db, change),
        onDone: () => _changeSubs.remove(key),
      );
    }
  }

  /// Gathers [change] into one event per [changeDelay], so an app that
  /// writes every frame sends a few events a second, not one per write.
  static void _gather(JustDatabase db, DatabaseChange change) {
    final key = db.name.toLowerCase();
    final pending = _pending.putIfAbsent(key, _PendingChange.new)
      ..tables.addAll(change.tables)
      ..schemaChanged |= change.schemaChanged;
    pending.timer ??= Timer(changeDelay, () {
      _pending.remove(key);
      if (!db.isOpen) return;
      _events.add((
        workbenchChangeEvent,
        {
          'database': db.name,
          'change': encodeChange(
            DatabaseChange(
              tables: pending.tables,
              schemaChanged: pending.schemaChanged,
            ),
          ),
          'snapshot': _snapshot(db),
        },
      ));
    });
  }

  /// Stops posting events (when the last workbench disconnects): an app
  /// nobody watches does no work for workbenches.
  static Future<void> _unwatch() async {
    _watching = false;
    final subs = [?_listSub, ..._changeSubs.values];
    _listSub = null;
    _changeSubs.clear();
    for (final p in _pending.values) {
      p.timer?.cancel();
    }
    _pending.clear();
    for (final sub in subs) {
      await sub.cancel();
    }
  }

  /// Stops posting events and closes what workbenches opened (tests).
  @visibleForTesting
  static Future<void> reset() async {
    await _unwatch();
    for (final held in _sessions.values) {
      for (final db in held.values) {
        await db.close().catchError((Object _) {});
      }
    }
    _sessions.clear();
  }

  // ---------------------------------------------------------------------------
  // Arguments
  // ---------------------------------------------------------------------------

  static Map<String, Object?> _snapshot(JustDatabase db) =>
      DatabaseSnapshot.of(db).toJson();

  static String _string(Map<String, Object?> args, String key) {
    final v = args[key];
    if (v is String) return v;
    throw ArgumentError('the workbench call needs "$key"');
  }

  static int _int(Map<String, Object?> args, String key) {
    final v = args[key];
    if (v is int) return v;
    throw ArgumentError('the workbench call needs "$key"');
  }

  static DatabaseMode _mode(Map<String, Object?> args) =>
      DatabaseMode.values.asNameMap()[args['mode']] ?? DatabaseMode.standard;

  static JustDatabase _db(Map<String, Object?> args) {
    final name = _string(args, 'database');
    return JustDatabase.findOpen(name) ??
        (throw StateError('"$name" is not open.'));
  }

  static Map<String, JustDatabase> _held(Map<String, Object?> args) {
    final session = args['session'];
    return _sessions[session] ??
        (throw StateError(
          'the workbench session ended (was the app restarted?); reload '
          'the workbench',
        ));
  }

  static void _hold(Map<String, Object?> args, JustDatabase db) {
    final held = _held(args);
    final key = db.name.toLowerCase();
    if (identical(held[key], db)) {
      unawaited(db.close()); // two opens raced: keep one reference
    } else {
      held[key] = db;
    }
  }
}

final class _PendingChange {
  final Set<String> tables = {};
  bool schemaChanged = false;
  Timer? timer;
}

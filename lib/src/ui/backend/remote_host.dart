/// The workbench on the databases of a running app it is connected to (the
/// just_database DevTools extension), through the app's workbench service.
@internal
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show internal;

import '../../core/benchmark.dart';
import '../../core/database_change.dart';
import '../../core/database_manager.dart';
import '../../core/database_mode.dart';
import '../../core/query_result.dart';
import '../../core/workbench_service.dart' show AdminEncryption;
import '../../core/workbench_wire.dart';
import '../../storage/schema.dart';
import 'admin_backend.dart';

/// How a remote workbench reaches the app.
abstract interface class WorkbenchTransport {
  /// Calls the workbench service's [method] in the app with [args] (JSON).
  /// Returns its reply: `{'ok': true, ...}` or `{'ok': false, 'error': ...}`.
  Future<Map<String, Object?>> call(String method, Map<String, Object?> args);

  /// The app's workbench events: (kind, data).
  Stream<(String, Map<String, Object?>)> get events;
}

/// [AdminHost] for the databases of an app reached through [transport].
final class RemoteAdminHost implements AdminHost {
  RemoteAdminHost(this.transport) {
    _eventSub = transport.events.listen(_onEvent);
  }

  final WorkbenchTransport transport;

  late final StreamSubscription<(String, Map<String, Object?>)> _eventSub;
  final StreamController<void> _list = StreamController.broadcast();
  final Map<String, RemoteAdminDatabase> _open = {};
  Future<String>? _session;
  bool _disposed = false;

  /// The app's just_database version, once connected.
  String? appVersion;

  @override
  bool get isRemote => true;

  @override
  Stream<void> get listChanges => _list.stream;

  Future<String> _connect() => _session ??= () async {
    try {
      final reply = await _call('connect', const {});
      final protocol = reply['protocol'];
      if (protocol != workbenchProtocol) {
        throw StateError(
          'the app speaks workbench protocol $protocol (just_database '
          '${reply['version']}); this workbench speaks $workbenchProtocol. '
          'Use the workbench of the just_database version the app uses.',
        );
      }
      appVersion = reply['version'] as String?;
      return reply['session'] as String;
    } catch (_) {
      _session = null; // the next call tries again
      rethrow;
    }
  }();

  /// Calls [method] in the app; throws the error it reports.
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> args,
  ) async {
    final session = await _connect();
    return _call(method, {...args, 'session': session});
  }

  Future<Map<String, Object?>> _call(
    String method,
    Map<String, Object?> args,
  ) async {
    if (_disposed) throw StateError('the workbench was closed');
    final reply = await transport.call(method, args);
    if (reply['ok'] == true) return reply;
    final error = reply['error'];
    throw error is Map<String, Object?>
        ? decodeError(error)
        : const WorkbenchRemoteError('the app did not answer the workbench');
  }

  /// Brings the handle of the database [json] describes up to date (or
  /// creates it); a closed one is dropped.
  RemoteAdminDatabase? _apply(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final snapshot = DatabaseSnapshot.fromJson(json);
    final key = snapshot.name.toLowerCase();
    if (!snapshot.isOpen) {
      _open.remove(key)?._close();
      return null;
    }
    final handle = _open[key];
    if (handle != null) {
      handle._snapshot = snapshot;
      return handle;
    }
    return _open[key] = RemoteAdminDatabase._(this, snapshot);
  }

  RemoteAdminDatabase _applyOpen(Object? json) =>
      _apply(json) ??
      (throw StateError('the app closed the database right away'));

  void _onEvent((String, Map<String, Object?>) event) {
    if (_disposed) return;
    final (kind, data) = event;
    switch (kind) {
      case workbenchListEvent:
        _list.add(null);
      case workbenchChangeEvent:
        final name = data['database'];
        if (name is! String) return;
        // A database the workbench does not know yet arrives with the list
        // event its opening sent.
        if (!_open.containsKey(name.toLowerCase())) return;
        final handle = _apply(data['snapshot']);
        final change = data['change'];
        if (handle != null && change is Map<String, Object?>) {
          handle._changes.add(decodeChange(change));
        }
    }
  }

  @override
  Future<List<DatabaseInfo>> listDatabases() async {
    final reply = await call('list', const {});
    final open = <String>{};
    for (final json in reply['open'] as List? ?? const []) {
      final handle = _apply(json);
      if (handle != null) open.add(handle.name.toLowerCase());
    }
    for (final key in [..._open.keys]) {
      if (!open.contains(key)) _open.remove(key)?._close();
    }
    return [
      for (final json in reply['databases'] as List? ?? const [])
        decodeDatabaseInfo(json as Map<String, Object?>),
    ];
  }

  @override
  AdminDatabase? findOpen(String name) => _open[name.toLowerCase()];

  @override
  List<AdminDatabase> get openDatabases => List.of(_open.values);

  @override
  Future<AdminDatabase?> open(
    String name, {
    required DatabaseMode mode,
    String? passphrase,
    required bool encrypted,
  }) async {
    final reply = await call('open', {
      'database': name,
      'mode': mode.name,
      'passphrase': ?passphrase,
      'encrypted': encrypted,
    });
    if (reply['needsPassphrase'] == true) return null;
    return _applyOpen(reply['snapshot']);
  }

  @override
  Future<AdminDatabase> create(
    String name, {
    required DatabaseMode mode,
    required bool persist,
    AdminEncryption encryption = AdminEncryption.none,
    String? passphrase,
  }) async {
    final reply = await call('create', {
      'database': name,
      'mode': mode.name,
      'persist': persist,
      'encryption': encryption.name,
      'passphrase': ?passphrase,
    });
    return _applyOpen(reply['snapshot']);
  }

  @override
  Future<void> release(AdminDatabase db) async {
    await call('release', {'database': db.name});
    final reply = await call('snapshot', {'database': db.name});
    if (reply['snapshot'] == null) {
      _open.remove(db.name.toLowerCase())?._close();
    } else {
      _apply(reply['snapshot']);
    }
  }

  @override
  Future<void> delete(String name) async {
    await call('delete', {'database': name});
    _open.remove(name.toLowerCase())?._close();
  }

  @override
  Future<void> setEncryption(
    AdminDatabase db,
    AdminEncryption encryption, {
    String? passphrase,
  }) async {
    final reply = await call('setEncryption', {
      'database': db.name,
      'encryption': encryption.name,
      'passphrase': ?passphrase,
    });
    _apply(reply['snapshot']);
  }

  @override
  Future<bool> hasStoredKey(String name) async =>
      (await call('hasStoredKey', {'database': name}))['value'] == true;

  @override
  Future<BenchmarkSuiteResult> runStandardBenchmark(
    AdminDatabase? db, {
    required int rowCount,
    required int warmup,
    required int iterations,
  }) async {
    final reply = await call('benchmark', {
      'database': ?db?.name,
      'rowCount': rowCount,
      'warmup': warmup,
      'iterations': iterations,
    });
    return decodeSuiteResult(reply['suite'] as Map<String, Object?>);
  }

  @override
  Future<QueryStats> benchmarkQuery(
    AdminDatabase db,
    String label,
    String sql, {
    required int warmup,
    required int iterations,
  }) async {
    final reply = await call('benchmarkQuery', {
      'database': db.name,
      'label': label,
      'sql': sql,
      'warmup': warmup,
      'iterations': iterations,
    });
    return decodeQueryStats(reply['stats'] as Map<String, Object?>);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    final session = _session;
    try {
      if (session != null) {
        await transport.call('disconnect', {'session': await session});
      }
    } catch (_) {
      // The app may be gone already.
    }
    _disposed = true;
    await _eventSub.cancel();
    for (final handle in _open.values) {
      handle._close();
    }
    _open.clear();
    await _list.close();
  }
}

/// [AdminDatabase] for an open database of the connected app: getters
/// answer from the latest [DatabaseSnapshot], calls go to the app.
final class RemoteAdminDatabase implements AdminDatabase {
  RemoteAdminDatabase._(this._host, this._current);

  final RemoteAdminHost _host;
  DatabaseSnapshot _current;
  Map<String, TableSnapshot>? _tables;
  final StreamController<DatabaseChange> _changes =
      StreamController.broadcast();
  bool _closed = false;

  set _snapshot(DatabaseSnapshot value) {
    _current = value;
    _tables = null;
  }

  void _close() {
    if (_closed) return;
    _closed = true;
    unawaited(_changes.close());
  }

  TableSnapshot? _table(String name) => (_tables ??= {
    for (final t in _current.tables) t.schema.name.toLowerCase(): t,
  })[name.toLowerCase()];

  ObjectSnapshot? _find(List<ObjectSnapshot> list, String name) {
    final key = name.toLowerCase();
    for (final o in list) {
      if (o.name.toLowerCase() == key) return o;
    }
    return null;
  }

  @override
  String get name => _current.name;
  @override
  DatabaseMode get mode => _current.mode;
  @override
  bool get persist => _current.persist;
  @override
  bool get isOpen => !_closed && _current.isOpen;
  @override
  int get openerCount => isOpen ? _current.openerCount : 0;
  @override
  bool get inTransaction => _current.inTransaction;
  @override
  Object? get saveError => _current.saveError;
  @override
  List<String> get tableNames => [
    for (final t in _current.tables) t.schema.name,
  ];
  @override
  List<String> get viewNames => [for (final v in _current.views) v.name];
  @override
  List<String> get triggerNames => [for (final t in _current.triggers) t.name];
  @override
  TableSchema? getTableSchema(String table) => _table(table)?.schema;
  @override
  String? getViewSql(String view) => _find(_current.views, view)?.sql;
  @override
  String? getTriggerSql(String trigger) =>
      _find(_current.triggers, trigger)?.sql;
  @override
  String? getTriggerTable(String trigger) =>
      _find(_current.triggers, trigger)?.table;
  @override
  List<String> triggerNamesForTable(String table) {
    final key = table.toLowerCase();
    return [
      for (final t in _current.triggers)
        if (t.table?.toLowerCase() == key) t.name,
    ];
  }

  @override
  List<IndexInfo> indexesForTable(String table) =>
      _table(table)?.indexes ?? const [];
  @override
  List<String> indexNamesForTable(String table) => [
    for (final i in indexesForTable(table)) i.name,
  ];
  @override
  int rowCount(String table) => _table(table)?.rowCount ?? 0;
  @override
  int get totalRows => _current.tables.fold(0, (s, t) => s + t.rowCount);
  @override
  int get estimatedSizeBytes => _current.estimatedSizeBytes;
  @override
  Stream<DatabaseChange> get changes => _changes.stream;

  Future<Map<String, Object?>> _call(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final reply = await _host.call(method, {'database': name, ...args});
    _host._apply(reply['snapshot']);
    return reply;
  }

  @override
  Future<QueryResult> execute(String sql, [Object? parameters]) async {
    final reply = await _call('execute', {
      'sql': sql,
      'parameters': encodeParameters(parameters),
    });
    return decodeResult(reply['result'] as Map<String, Object?>);
  }

  @override
  Future<QueryResult> query(String sql, [Object? parameters]) async {
    final reply = await _call('query', {
      'sql': sql,
      'parameters': encodeParameters(parameters),
    });
    return decodeResult(reply['result'] as Map<String, Object?>);
  }

  @override
  Future<List<QueryResult>> executeScript(String sql) async {
    final reply = await _call('executeScript', {'sql': sql});
    return [
      for (final r in reply['results'] as List? ?? const [])
        decodeResult(r as Map<String, Object?>),
    ];
  }

  @override
  Future<void> deleteRows(String table, List<int> rowids) =>
      _call('deleteRows', {'table': table, 'rowids': rowids});

  @override
  Future<void> flush() => _call('flush');

  @override
  Future<String> exportSql() async =>
      (await _call('exportSql'))['text'] as String;

  @override
  Future<Map<String, Object?>> exportJson() async =>
      (await _call('exportJson'))['json'] as Map<String, Object?>;

  @override
  Future<void> importSql(String sql) => _call('importSql', {'text': sql});

  @override
  Future<void> importJson(Map<String, Object?> json) =>
      _call('importJson', {'json': json});

  @override
  String toString() => 'RemoteAdminDatabase($name)';
}

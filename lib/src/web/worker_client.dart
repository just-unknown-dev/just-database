/// Main-thread client proxy for communicating with the database Web Worker.
///
/// Spawns a Dart isolate (compiled to a Web Worker on web) and provides an
/// async API that mirrors [JustDatabase] by sending messages through the
/// isolate port and using [Completer]s to correlate responses.
library;

import 'dart:async';
import 'dart:isolate';

import '../sql/executor.dart' show QueryResult;
import 'database_worker.dart';
import 'worker_protocol.dart';

/// Client-side proxy for the database worker isolate.
///
/// All methods send a request message to the worker and await its response.
/// The worker runs the full SQL engine and OPFS I/O on a separate thread.
class WorkerClient {
  final Isolate _isolate;
  final SendPort _workerPort;
  final ReceivePort _receivePort;
  final StreamSubscription<dynamic> _subscription;

  int _nextId = 0;
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};

  WorkerClient._({
    required Isolate isolate,
    required SendPort workerPort,
    required ReceivePort receivePort,
    required StreamSubscription<dynamic> subscription,
  }) : _isolate = isolate,
       _workerPort = workerPort,
       _receivePort = receivePort,
       _subscription = subscription;

  /// Spawns a new worker isolate and establishes bidirectional communication.
  static Future<WorkerClient> spawn() async {
    final receivePort = ReceivePort();
    final isolate = await Isolate.spawn(
      databaseWorkerMain,
      receivePort.sendPort,
    );

    final completer = Completer<SendPort>();
    late StreamSubscription<dynamic> subscription;

    subscription = receivePort.listen((dynamic msg) {
      if (msg is SendPort) {
        completer.complete(msg);
      }
    });

    final workerPort = await completer.future;

    final client = WorkerClient._(
      isolate: isolate,
      workerPort: workerPort,
      receivePort: receivePort,
      subscription: subscription,
    );

    // Now switch the listener to handle response messages.
    subscription.onData(client._onMessage);

    return client;
  }

  void _onMessage(dynamic msg) {
    if (msg is Map<String, dynamic>) {
      final id = msg['id'] as int?;
      if (id != null && _pending.containsKey(id)) {
        _pending.remove(id)!.complete(msg);
      }
    }
  }

  Future<Map<String, dynamic>> _send(Map<String, dynamic> request) {
    final id = request['id'] as int;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;
    _workerPort.send(request);
    return completer.future;
  }

  int _allocId() => _nextId++;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Opens a database in the worker.
  Future<void> open({
    required String name,
    required String mode,
    required bool persist,
    String? encryptionKey,
  }) async {
    final id = _allocId();
    final resp = await _send(
      WorkerRequest.open(
        id: id,
        name: name,
        mode: mode,
        persist: persist,
        encryptionKey: encryptionKey,
      ),
    );
    _checkError(resp);
  }

  /// Executes a SELECT query and returns a [QueryResult].
  Future<QueryResult> query(String sql) async {
    final id = _allocId();
    final resp = await _send(WorkerRequest.query(id: id, sql: sql));
    return _toQueryResult(resp);
  }

  /// Executes a DDL/DML statement and returns a [QueryResult].
  Future<QueryResult> execute(String sql) async {
    final id = _allocId();
    final resp = await _send(WorkerRequest.execute(id: id, sql: sql));
    return _toQueryResult(resp);
  }

  /// Closes the database in the worker and releases OPFS locks.
  Future<void> close() async {
    final id = _allocId();
    final resp = await _send(WorkerRequest.close(id: id));
    _checkError(resp);
  }

  /// Begins a transaction.
  Future<QueryResult> beginTransaction({String? mode}) async {
    final id = _allocId();
    final resp = await _send(
      WorkerRequest.beginTransaction(id: id, mode: mode),
    );
    return _toQueryResult(resp);
  }

  /// Commits the current transaction.
  Future<QueryResult> commit() async {
    final id = _allocId();
    final resp = await _send(WorkerRequest.commit(id: id));
    return _toQueryResult(resp);
  }

  /// Rolls back the current transaction (or to a savepoint).
  Future<QueryResult> rollback({String? savepoint}) async {
    final id = _allocId();
    final resp = await _send(
      WorkerRequest.rollback(id: id, savepoint: savepoint),
    );
    return _toQueryResult(resp);
  }

  /// Creates a named savepoint.
  Future<QueryResult> savepoint(String name) async {
    final id = _allocId();
    final resp = await _send(WorkerRequest.savepoint(id: id, name: name));
    return _toQueryResult(resp);
  }

  /// Releases a named savepoint.
  Future<QueryResult> releaseSavepoint(String name) async {
    final id = _allocId();
    final resp = await _send(
      WorkerRequest.releaseSavepoint(id: id, name: name),
    );
    return _toQueryResult(resp);
  }

  // ---------------------------------------------------------------------------
  // Introspection
  // ---------------------------------------------------------------------------

  Future<T> _introspect<T>(IntrospectKind kind, {String? tableName}) async {
    final id = _allocId();
    final resp = await _send(
      WorkerRequest.introspect(id: id, kind: kind, tableName: tableName),
    );
    _checkError(resp);
    return resp['data'] as T;
  }

  Future<List<String>> get tableNames => _introspect(IntrospectKind.tableNames);
  Future<List<String>> get viewNames => _introspect(IntrospectKind.viewNames);
  Future<List<String>> get triggerNames =>
      _introspect(IntrospectKind.triggerNames);
  Future<int> get totalRows => _introspect(IntrospectKind.totalRows);
  Future<int> get estimatedSizeBytes =>
      _introspect(IntrospectKind.estimatedSizeBytes);
  Future<bool> get inTransaction => _introspect(IntrospectKind.inTransaction);
  Future<bool> get isOpen => _introspect(IntrospectKind.isOpen);

  Future<Map<String, dynamic>?> getTableSchema(String tableName) =>
      _introspect(IntrospectKind.tableSchema, tableName: tableName);

  Future<List<String>> indexNamesForTable(String tableName) =>
      _introspect(IntrospectKind.indexNames, tableName: tableName);

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Kills the worker isolate and cleans up resources.
  void dispose() {
    _subscription.cancel();
    _receivePort.close();
    _isolate.kill();
    // Complete any pending requests with an error.
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Worker was disposed.'));
      }
    }
    _pending.clear();
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  void _checkError(Map<String, dynamic> resp) {
    if (resp['success'] != true) {
      throw StateError(resp['error'] as String? ?? 'Unknown worker error');
    }
  }

  QueryResult _toQueryResult(Map<String, dynamic> resp) {
    if (resp['success'] == true) {
      final columns =
          (resp['columns'] as List<dynamic>?)
              ?.map((c) => c as String)
              .toList() ??
          const [];
      final rows =
          (resp['rows'] as List<dynamic>?)
              ?.map((r) => _deserializeRow(r as Map<String, dynamic>))
              .toList() ??
          const [];
      final affectedRows = resp['affectedRows'] as int? ?? 0;
      return QueryResult.success(
        columns: columns,
        rows: rows,
        affectedRows: affectedRows,
      );
    } else {
      return QueryResult.error(resp['error'] as String? ?? 'Unknown error');
    }
  }

  /// Deserializes special typed values (DateTime) sent from the worker.
  Map<String, dynamic> _deserializeRow(Map<String, dynamic> row) {
    return row.map((key, value) {
      if (value is Map<String, dynamic> && value['__type'] == 'datetime') {
        return MapEntry(key, DateTime.parse(value['data'] as String));
      }
      return MapEntry(key, value);
    });
  }
}

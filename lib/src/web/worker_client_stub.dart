/// Stub WorkerClient for WASM — dart:isolate is unavailable on this target.
///
/// Selected by the conditional import in database_web.dart when
/// dart.library.html is false (i.e. on WASM). The real implementation in
/// worker_client.dart is used on JS-web where dart:isolate compiles to web
/// workers.
library;

import 'dart:async';

import '../sql/executor.dart' show QueryResult;

class WorkerClient {
  static Future<WorkerClient> spawn() => Future.error(
    UnsupportedError(
      'Web Workers require dart:isolate, which is unavailable on WASM. '
      'Falling back to IndexedDB or in-memory storage.',
    ),
  );

  Future<void> open({
    required String name,
    required String mode,
    required bool persist,
    String? encryptionKey,
  }) => _stub();

  Future<QueryResult> query(String sql) => _stub();
  Future<QueryResult> execute(String sql) => _stub();
  Future<void> close() => _stub();
  Future<QueryResult> beginTransaction({String? mode}) => _stub();
  Future<QueryResult> commit() => _stub();
  Future<QueryResult> rollback({String? savepoint}) => _stub();
  Future<QueryResult> savepoint(String name) => _stub();
  Future<QueryResult> releaseSavepoint(String name) => _stub();

  Future<List<String>> get tableNames => _stub();
  Future<List<String>> get viewNames => _stub();
  Future<List<String>> get triggerNames => _stub();
  Future<int> get totalRows => _stub();
  Future<int> get estimatedSizeBytes => _stub();
  Future<bool> get inTransaction => _stub();
  Future<bool> get isOpen => _stub();

  Future<Map<String, dynamic>?> getTableSchema(String tableName) => _stub();
  Future<List<String>> indexNamesForTable(String tableName) => _stub();

  void dispose() {}

  // ignore: prefer_void_to_null
  static Never _stub() =>
      throw UnsupportedError('WorkerClient is not available on this platform.');
}

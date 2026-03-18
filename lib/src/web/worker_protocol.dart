/// Message protocol for communication between the main-thread WorkerClient
/// and the database Web Worker isolate.
///
/// All messages are `Map<String, dynamic>` to be isolate-transferable. Each
/// request carries a unique integer `id` used by the client to correlate
/// the asynchronous response.
library;

// ---------------------------------------------------------------------------
// Request types
// ---------------------------------------------------------------------------

/// Identifies the type of a worker request message.
enum WorkerRequestType {
  open,
  query,
  execute,
  close,
  introspect,
  beginTransaction,
  commit,
  rollback,
  savepoint,
  releaseSavepoint,
}

/// Identifies the kind of introspection data requested.
enum IntrospectKind {
  tableNames,
  viewNames,
  triggerNames,
  tableSchema,
  indexNames,
  totalRows,
  estimatedSizeBytes,
  inTransaction,
  isOpen,
}

/// Encodes a worker request as an isolate-safe map.
abstract final class WorkerRequest {
  static Map<String, dynamic> open({
    required int id,
    required String name,
    required String mode,
    required bool persist,
    String? encryptionKey,
  }) => {
    'id': id,
    'type': WorkerRequestType.open.name,
    'name': name,
    'mode': mode,
    'persist': persist,
    'encryptionKey': ?encryptionKey,
  };

  static Map<String, dynamic> query({required int id, required String sql}) => {
    'id': id,
    'type': WorkerRequestType.query.name,
    'sql': sql,
  };

  static Map<String, dynamic> execute({required int id, required String sql}) =>
      {'id': id, 'type': WorkerRequestType.execute.name, 'sql': sql};

  static Map<String, dynamic> close({required int id}) => {
    'id': id,
    'type': WorkerRequestType.close.name,
  };

  static Map<String, dynamic> introspect({
    required int id,
    required IntrospectKind kind,
    String? tableName,
  }) => {
    'id': id,
    'type': WorkerRequestType.introspect.name,
    'kind': kind.name,
    'tableName': ?tableName,
  };

  static Map<String, dynamic> beginTransaction({
    required int id,
    String? mode,
  }) => {
    'id': id,
    'type': WorkerRequestType.beginTransaction.name,
    'mode': ?mode,
  };

  static Map<String, dynamic> commit({required int id}) => {
    'id': id,
    'type': WorkerRequestType.commit.name,
  };

  static Map<String, dynamic> rollback({required int id, String? savepoint}) =>
      {
        'id': id,
        'type': WorkerRequestType.rollback.name,
        'savepoint': ?savepoint,
      };

  static Map<String, dynamic> savepoint({
    required int id,
    required String name,
  }) => {'id': id, 'type': WorkerRequestType.savepoint.name, 'name': name};

  static Map<String, dynamic> releaseSavepoint({
    required int id,
    required String name,
  }) => {
    'id': id,
    'type': WorkerRequestType.releaseSavepoint.name,
    'name': name,
  };
}

// ---------------------------------------------------------------------------
// Response types
// ---------------------------------------------------------------------------

/// Encodes a worker response as an isolate-safe map.
abstract final class WorkerResponse {
  static Map<String, dynamic> success({
    required int id,
    List<String> columns = const [],
    List<Map<String, dynamic>> rows = const [],
    int affectedRows = 0,
  }) => {
    'id': id,
    'success': true,
    'columns': columns,
    'rows': rows,
    'affectedRows': affectedRows,
  };

  static Map<String, dynamic> error({
    required int id,
    required String message,
  }) => {'id': id, 'success': false, 'error': message};

  static Map<String, dynamic> introspectResult({
    required int id,
    required dynamic data,
  }) => {'id': id, 'success': true, 'introspect': true, 'data': data};

  /// The special initial response sent by the worker once it's ready.
  static Map<String, dynamic> ready() => {'type': 'ready'};
}

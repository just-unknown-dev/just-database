/// Database Web Worker entry point.
///
/// This file is the isolate entry point spawned by [WorkerClient]. It runs
/// the full SQL engine (Parser, Executor, LockManager, QueryTracker) and
/// performs all OPFS I/O inside the worker. Communication with the main thread
/// uses the Dart isolate `SendPort` / `ReceivePort` mechanism which compiles
/// to `postMessage`/`onmessage` on the web.
library;

import 'dart:async';
import 'dart:isolate';

import '../concurrency/lock_manager.dart';
import '../core/database_mode.dart';
import '../sql/ast.dart';
import '../sql/executor.dart';
import '../sql/parser.dart';
import '../storage/query_tracker.dart';
import '../storage/table.dart';
import 'opfs_persistence.dart';
import 'opfs_storage.dart';
import 'wal_manager.dart';
import 'worker_protocol.dart';

/// Entry point for the database worker isolate.
///
/// [message] is expected to be the main thread's [SendPort].
void databaseWorkerMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  final worker = _DatabaseWorkerState(mainSendPort);
  receivePort.listen((dynamic msg) {
    if (msg is Map<String, dynamic>) {
      worker._handleMessage(msg);
    }
  });
}

/// Internal state for the database worker.
class _DatabaseWorkerState {
  final SendPort _sendPort;

  // Engine state — initialized on `open`.
  final Map<String, Table> _tables = {};
  late Executor _executor;
  late LockManager _lockManager;
  late QueryTracker _queryTracker;

  // Persistence state.
  OpfsStorageDriver? _dbDriver;
  WalManager? _walManager;
  bool _persist = false;
  String? _dbName;
  DatabaseMode _mode = DatabaseMode.standard;
  bool _isOpen = false;

  _DatabaseWorkerState(this._sendPort);

  void _handleMessage(Map<String, dynamic> msg) {
    final typeStr = msg['type'] as String;
    final type = WorkerRequestType.values.firstWhere(
      (t) => t.name == typeStr,
      orElse: () => WorkerRequestType.query,
    );

    switch (type) {
      case WorkerRequestType.open:
        _handleOpen(msg);
      case WorkerRequestType.query:
        _handleQuery(msg);
      case WorkerRequestType.execute:
        _handleExecute(msg);
      case WorkerRequestType.close:
        _handleClose(msg);
      case WorkerRequestType.introspect:
        _handleIntrospect(msg);
      case WorkerRequestType.beginTransaction:
        _handleBeginTransaction(msg);
      case WorkerRequestType.commit:
        _handleCommit(msg);
      case WorkerRequestType.rollback:
        _handleRollback(msg);
      case WorkerRequestType.savepoint:
        _handleSavepoint(msg);
      case WorkerRequestType.releaseSavepoint:
        _handleReleaseSavepoint(msg);
    }
  }

  // ---------------------------------------------------------------------------
  // Open
  // ---------------------------------------------------------------------------

  Future<void> _handleOpen(Map<String, dynamic> msg) async {
    final id = msg['id'] as int;
    try {
      _dbName = msg['name'] as String;
      _persist = msg['persist'] as bool;
      final modeStr = msg['mode'] as String;
      _mode = DatabaseMode.values.firstWhere(
        (m) => m.name == modeStr,
        orElse: () => DatabaseMode.standard,
      );

      _queryTracker = QueryTracker();
      _lockManager = LockManager.forMode(_mode);
      _executor = Executor(_tables, queryTracker: _queryTracker);

      if (_persist) {
        try {
          _dbDriver = await OpfsStorageDriver.open(_dbName!);
          _walManager = await WalManager.open(_dbName!);

          // Load main database snapshot
          final snapshot = OpfsPersistenceManager.load(_dbDriver!, _dbName!);
          if (snapshot != null) {
            for (final entry in snapshot.tables.entries) {
              _tables[entry.key.toLowerCase()] = entry.value;
            }
          }

          // Replay WAL entries on top of the snapshot
          final walEntries = _walManager!.replay();
          for (final entry in walEntries) {
            if (entry.type == WalEntryType.statement) {
              final sql = entry.payload['sql'] as String?;
              if (sql != null) {
                try {
                  final stmt = Parser.parseSQL(sql);
                  await _executor.execute(stmt);
                } catch (_) {
                  // Skip invalid WAL entries during replay
                }
              }
            }
          }

          // If WAL had entries, checkpoint immediately to consolidate
          if (walEntries.isNotEmpty) {
            _doCheckpoint();
          }
        } catch (e) {
          // OPFS not available in this worker context — fall through to
          // in-memory mode. Persistence will be disabled.
          _dbDriver?.close();
          _dbDriver = null;
          _walManager?.close();
          _walManager = null;
          _persist = false;
        }
      }

      _isOpen = true;
      _sendPort.send(WorkerResponse.success(id: id));
    } catch (e) {
      _sendPort.send(WorkerResponse.error(id: id, message: e.toString()));
    }
  }

  // ---------------------------------------------------------------------------
  // Query (SELECT)
  // ---------------------------------------------------------------------------

  Future<void> _handleQuery(Map<String, dynamic> msg) async {
    final id = msg['id'] as int;
    if (!_isOpen) {
      _sendPort.send(
        WorkerResponse.error(id: id, message: 'Database is not open.'),
      );
      return;
    }

    final sql = msg['sql'] as String;
    try {
      final stmt = Parser.parseSQL(sql);
      final resourceName = _extractTableName(stmt) ?? '*';
      await _lockManager.acquireRead(resourceName);
      try {
        final result = await _executor.execute(stmt);
        _sendPort.send(
          WorkerResponse.success(
            id: id,
            columns: result.columns,
            rows: _sanitizeRows(result.rows),
            affectedRows: result.affectedRows,
          ),
        );
      } finally {
        _lockManager.releaseRead(resourceName);
      }
    } on ParseException catch (e) {
      _sendPort.send(WorkerResponse.error(id: id, message: 'Parse error: $e'));
    } catch (e) {
      _sendPort.send(WorkerResponse.error(id: id, message: e.toString()));
    }
  }

  // ---------------------------------------------------------------------------
  // Execute (DDL / DML)
  // ---------------------------------------------------------------------------

  Future<void> _handleExecute(Map<String, dynamic> msg) async {
    final id = msg['id'] as int;
    if (!_isOpen) {
      _sendPort.send(
        WorkerResponse.error(id: id, message: 'Database is not open.'),
      );
      return;
    }

    final sql = msg['sql'] as String;
    try {
      final stmt = Parser.parseSQL(sql);
      final resourceName = _extractTableName(stmt) ?? '*';
      await _lockManager.acquireWrite(resourceName);
      try {
        final result = await _executor.execute(stmt);
        if (result.success && _persist) {
          _appendWal(sql, result.affectedRows);
          _maybeCheckpoint();
        }
        _sendPort.send(
          WorkerResponse.success(
            id: id,
            columns: result.columns,
            rows: _sanitizeRows(result.rows),
            affectedRows: result.affectedRows,
          ),
        );
      } finally {
        _lockManager.releaseWrite(resourceName);
      }
    } on ParseException catch (e) {
      _sendPort.send(WorkerResponse.error(id: id, message: 'Parse error: $e'));
    } catch (e) {
      _sendPort.send(WorkerResponse.error(id: id, message: e.toString()));
    }
  }

  // ---------------------------------------------------------------------------
  // Transaction control
  // ---------------------------------------------------------------------------

  Future<void> _handleBeginTransaction(Map<String, dynamic> msg) async {
    final id = msg['id'] as int;
    final mode = msg['mode'] as String?;
    final sql = mode != null ? 'BEGIN $mode' : 'BEGIN';
    await _executeStatement(id, sql, isWrite: true);
  }

  Future<void> _handleCommit(Map<String, dynamic> msg) async {
    final id = msg['id'] as int;
    await _executeStatement(id, 'COMMIT', isWrite: true);
  }

  Future<void> _handleRollback(Map<String, dynamic> msg) async {
    final id = msg['id'] as int;
    final savepoint = msg['savepoint'] as String?;
    final sql = savepoint != null
        ? 'ROLLBACK TO SAVEPOINT $savepoint'
        : 'ROLLBACK';
    await _executeStatement(id, sql, isWrite: true);
  }

  Future<void> _handleSavepoint(Map<String, dynamic> msg) async {
    final id = msg['id'] as int;
    final name = msg['name'] as String;
    await _executeStatement(id, 'SAVEPOINT $name', isWrite: true);
  }

  Future<void> _handleReleaseSavepoint(Map<String, dynamic> msg) async {
    final id = msg['id'] as int;
    final name = msg['name'] as String;
    await _executeStatement(id, 'RELEASE SAVEPOINT $name', isWrite: true);
  }

  Future<void> _executeStatement(
    int id,
    String sql, {
    required bool isWrite,
  }) async {
    if (!_isOpen) {
      _sendPort.send(
        WorkerResponse.error(id: id, message: 'Database is not open.'),
      );
      return;
    }
    try {
      final stmt = Parser.parseSQL(sql);
      final resourceName = _extractTableName(stmt) ?? '*';
      if (isWrite) {
        await _lockManager.acquireWrite(resourceName);
        try {
          final result = await _executor.execute(stmt);
          if (result.success && _persist) {
            _appendWal(sql, result.affectedRows);
          }
          _sendResult(id, result);
        } finally {
          _lockManager.releaseWrite(resourceName);
        }
      } else {
        await _lockManager.acquireRead(resourceName);
        try {
          final result = await _executor.execute(stmt);
          _sendResult(id, result);
        } finally {
          _lockManager.releaseRead(resourceName);
        }
      }
    } on ParseException catch (e) {
      _sendPort.send(WorkerResponse.error(id: id, message: 'Parse error: $e'));
    } catch (e) {
      _sendPort.send(WorkerResponse.error(id: id, message: e.toString()));
    }
  }

  // ---------------------------------------------------------------------------
  // Close
  // ---------------------------------------------------------------------------

  void _handleClose(Map<String, dynamic> msg) {
    final id = msg['id'] as int;
    try {
      if (_isOpen && _persist) {
        _doCheckpoint();
      }
      _walManager?.close();
      _dbDriver?.close();
      _walManager = null;
      _dbDriver = null;
      _isOpen = false;
      _sendPort.send(WorkerResponse.success(id: id));
    } catch (e) {
      _sendPort.send(WorkerResponse.error(id: id, message: e.toString()));
    }
  }

  // ---------------------------------------------------------------------------
  // Introspection
  // ---------------------------------------------------------------------------

  void _handleIntrospect(Map<String, dynamic> msg) {
    final id = msg['id'] as int;
    final kindStr = msg['kind'] as String;
    final kind = IntrospectKind.values.firstWhere(
      (k) => k.name == kindStr,
      orElse: () => IntrospectKind.tableNames,
    );

    try {
      dynamic data;
      switch (kind) {
        case IntrospectKind.tableNames:
          data = List<String>.from(_tables.keys);
        case IntrospectKind.viewNames:
          data = _executor.viewNames;
        case IntrospectKind.triggerNames:
          data = _executor.triggerNames;
        case IntrospectKind.tableSchema:
          final tableName = msg['tableName'] as String?;
          if (tableName != null) {
            final lower = tableName.toLowerCase();
            final table = _tables[lower];
            data = table?.schema.toJson();
          }
        case IntrospectKind.indexNames:
          final tableName = msg['tableName'] as String?;
          if (tableName != null) {
            final lower = tableName.toLowerCase();
            final table = _tables[lower];
            data = table?.indexNames ?? <String>[];
          }
        case IntrospectKind.totalRows:
          data = _tables.values.fold<int>(0, (s, t) => s + t.rowCount);
        case IntrospectKind.estimatedSizeBytes:
          data = _tables.values.fold<int>(
            0,
            (s, t) => s + t.estimatedSizeBytes,
          );
        case IntrospectKind.inTransaction:
          data = _executor.inTransaction;
        case IntrospectKind.isOpen:
          data = _isOpen;
      }
      _sendPort.send(WorkerResponse.introspectResult(id: id, data: data));
    } catch (e) {
      _sendPort.send(WorkerResponse.error(id: id, message: e.toString()));
    }
  }

  // ---------------------------------------------------------------------------
  // WAL + Persistence helpers
  // ---------------------------------------------------------------------------

  void _appendWal(String sql, int affectedRows) {
    _walManager?.append({
      'sql': sql,
      'affected': affectedRows,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _maybeCheckpoint() {
    if (_walManager != null && _walManager!.shouldCheckpoint) {
      _doCheckpoint();
    }
  }

  void _doCheckpoint() {
    if (_dbDriver != null) {
      OpfsPersistenceManager.save(_dbDriver!, _dbName!, _tables, _mode);
      _walManager?.checkpoint();
    }
  }

  void _sendResult(int id, QueryResult result) {
    if (result.success) {
      _sendPort.send(
        WorkerResponse.success(
          id: id,
          columns: result.columns,
          rows: _sanitizeRows(result.rows),
          affectedRows: result.affectedRows,
        ),
      );
    } else {
      _sendPort.send(
        WorkerResponse.error(
          id: id,
          message: result.errorMessage ?? 'Unknown error',
        ),
      );
    }
  }

  /// Ensures all row values are isolate-transferable.
  ///
  /// Dart isolate messaging supports primitives, strings, lists, and maps.
  /// `DateTime` and `Uint8List` values are converted to transferable forms.
  List<Map<String, dynamic>> _sanitizeRows(List<Map<String, dynamic>> rows) {
    return rows.map((row) {
      return row.map((key, value) {
        if (value is DateTime) {
          return MapEntry(key, {
            '__type': 'datetime',
            'data': value.toUtc().toIso8601String(),
          });
        }
        // Uint8List is transferable across isolates, so keep as-is on web.
        return MapEntry(key, value);
      });
    }).toList();
  }

  String? _extractTableName(Statement stmt) {
    if (stmt is SelectStatement) return stmt.tableName.toLowerCase();
    if (stmt is InsertStatement) return stmt.tableName.toLowerCase();
    if (stmt is UpdateStatement) return stmt.tableName.toLowerCase();
    if (stmt is DeleteStatement) return stmt.tableName.toLowerCase();
    if (stmt is CreateTableStatement) return stmt.tableName.toLowerCase();
    if (stmt is DropTableStatement) return stmt.tableName.toLowerCase();
    if (stmt is AlterTableStatement) return stmt.tableName.toLowerCase();
    if (stmt is BeginStatement ||
        stmt is CommitStatement ||
        stmt is RollbackStatement ||
        stmt is SavepointStatement ||
        stmt is ReleaseStatement) {
      return '*';
    }
    if (stmt is CreateViewStatement) return '*';
    if (stmt is DropViewStatement) return '*';
    if (stmt is CreateTriggerStatement) return '*';
    if (stmt is DropTriggerStatement) return '*';
    if (stmt is CreateIndexStatement) return stmt.tableName.toLowerCase();
    if (stmt is DropIndexStatement) return stmt.tableName?.toLowerCase() ?? '*';
    return null;
  }
}

/// The SQL engine: runs parsed statements against a [Catalog].
///
/// Everything here is synchronous: the data lives in memory, so a statement
/// runs start to finish without yielding, and no other statement can see
/// it half done. `JustDatabase` serializes calls behind an async lock and
/// saves the catalog afterwards.
@internal
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show internal;

import '../sql/ast.dart';
import '../sql/lexer.dart';
import '../sql/parser.dart';
import '../sql/sql_exception.dart';
import '../storage/catalog.dart';
import '../storage/index.dart';
import '../storage/rtree.dart';
import '../storage/schema.dart';
import '../storage/table.dart';
import '../storage/values.dart';

part 'aggregates.dart';
part 'compiler.dart';
part 'datetime.dart';
part 'ddl.dart';
part 'dml.dart';
part 'functions.dart';
part 'geometry.dart';
part 'rename.dart';
part 'scope.dart';
part 'select.dart';

/// The result of one statement.
final class StatementResult {
  StatementResult({
    this.columns = const [],
    this.rows = const [],
    this.changes = 0,
    this.lastInsertRowId,
  });

  /// The result column names (unique: duplicates get `:1`, `:2`, …).
  final List<String> columns;

  /// The result rows, one value per column.
  final List<List<Object?>> rows;

  /// Rows inserted, updated or deleted by the statement itself (not by
  /// triggers or foreign key actions).
  final int changes;

  /// The rowid of the last row the statement inserted, if it inserted one.
  final int? lastInsertRowId;
}

/// A savepoint: its name and where the undo log stood when it was taken.
final class _Savepoint {
  _Savepoint(this.name, this.mark);
  final String name;
  final int mark;
}

/// Thrown by `RAISE()` inside a trigger.
final class _Raise implements Exception {
  _Raise(this.kind, this.message);
  final RaiseKind kind;
  final String? message;
}

/// Thrown to roll back the whole transaction (conflict action ROLLBACK, or
/// `RAISE(ROLLBACK, …)`).
final class _RollbackTransaction implements Exception {
  _RollbackTransaction(this.error);
  final SqlException error;
}

/// Thrown for conflict action FAIL and `RAISE(FAIL, …)`: the statement ends
/// with an error but keeps the changes it made before the failure.
final class _Fail implements Exception {
  _Fail(this.error);
  final SqlException error;
}

/// The SQL engine.
final class Engine {
  /// Creates an engine over [catalog].
  Engine(this.catalog);

  /// The data.
  final Catalog catalog;

  /// Whether foreign keys are enforced (`PRAGMA foreign_keys`). On by
  /// default, unlike SQLite.
  bool foreignKeys = true;

  /// The rowid of the most recent successful INSERT.
  int lastInsertRowId = 0;

  /// Rows changed by the most recent INSERT, UPDATE or DELETE.
  int lastChanges = 0;

  /// Rows changed since the engine was created.
  int totalChanges = 0;

  int? _txMark;
  bool _txImplicit = false;
  final List<_Savepoint> _savepoints = [];

  // Per-execution state.
  List<Object?> _params = const [];

  /// The SQL text the expressions being compiled come from (their offsets
  /// point into it); it names result columns.
  String _source = '';
  DateTime _now = DateTime.now().toUtc();
  int _execId = 0;
  int _triggerDepth = 0;
  final Set<TriggerDefinition> _activeTriggers = {};
  final List<_PendingFk> _pendingFks = [];

  // Compiled views and triggers, dropped when the schema changes.
  int _cacheVersion = -1;
  final Map<String, _SelectPlan> _viewPlans = {};
  final Map<TriggerDefinition, _TriggerPlan> _triggerPlans = {};
  final Set<String> _viewsBeingCompiled = {};

  /// Whether a transaction is open.
  bool get inTransaction => _txMark != null;

  /// Whether [statement] only reads (SELECT, or a PRAGMA that reads).
  static bool isReadOnly(Statement statement) =>
      statement is SelectStatement ||
      (statement is PragmaStatement && statement.value == null);

  /// Runs [parsed] with [params] (one per parameter, already bound with
  /// [bindValue]). Throws [SqlException] on failure; a failed statement
  /// changes nothing, except under conflict action FAIL, and a ROLLBACK
  /// conflict also ends the transaction.
  StatementResult execute(ParsedStatement parsed, List<Object?> params) {
    final stmt = parsed.statement;
    if (params.length != parsed.parameterCount) {
      throw SqlException.misuse(
        'expected ${parsed.parameterCount} parameter(s), got ${params.length}',
      );
    }
    _params = params;
    _source = parsed.source;
    _now = DateTime.now().toUtc();
    _execId++;
    try {
      switch (stmt) {
        case BeginStatement():
          return _begin();
        case CommitStatement():
          return _commit();
        case RollbackStatement():
          return _rollback(stmt.savepoint);
        case SavepointStatement():
          return _savepoint(stmt.name);
        case ReleaseStatement():
          return _release(stmt.name);
        default:
          break;
      }
      _syncCaches();
      final mark = catalog.log.hold();
      var released = false;
      try {
        final result = _dispatch(stmt, parsed.sql);
        _checkPendingForeignKeys();
        return result;
      } on _Fail catch (f) {
        // FAIL keeps the changes made before the failure.
        _pendingFks.clear();
        throw f.error;
      } on _RollbackTransaction catch (r) {
        _pendingFks.clear();
        catalog.log.rollbackTo(mark);
        catalog.log.release();
        released = true;
        if (inTransaction) _endTransaction(rollback: true);
        throw r.error;
      } catch (_) {
        _pendingFks.clear();
        catalog.log.rollbackTo(mark);
        rethrow;
      } finally {
        if (!released) catalog.log.release();
      }
    } on _Raise catch (r) {
      throw SqlException(
        'RAISE() may only be used within a trigger-program: ${r.message}',
        kind: SqlErrorKind.misuse,
      );
    } on SqlException catch (e) {
      throw e.withSql(parsed.sql);
    } on StateError catch (e) {
      throw SqlException(e.message, sql: parsed.sql);
    }
  }

  StatementResult _dispatch(Statement stmt, String sql) {
    switch (stmt) {
      case SelectStatement():
        final plan = _compileSelect(stmt, null);
        final rows = plan.run(null);
        return StatementResult(columns: plan.columnNames, rows: rows);
      case InsertStatement():
        return _insert(stmt);
      case UpdateStatement():
        return _update(stmt);
      case DeleteStatement():
        return _delete(stmt);
      case CreateTableStatement():
        return _createTable(stmt);
      case DropTableStatement():
        return _dropTable(stmt);
      case RenameTableStatement():
        return _renameTable(stmt);
      case RenameColumnStatement():
        return _renameColumn(stmt);
      case AddColumnStatement():
        return _addColumn(stmt);
      case DropColumnStatement():
        return _dropColumn(stmt);
      case CreateIndexStatement():
        return _createIndex(stmt);
      case DropIndexStatement():
        return _dropIndex(stmt);
      case CreateViewStatement():
        return _createView(stmt, sql);
      case DropViewStatement():
        return _dropView(stmt);
      case CreateTriggerStatement():
        return _createTrigger(stmt, sql);
      case DropTriggerStatement():
        return _dropTrigger(stmt);
      case PragmaStatement():
        return _pragma(stmt);
      case BeginStatement():
      case CommitStatement():
      case RollbackStatement():
      case SavepointStatement():
      case ReleaseStatement():
        throw StateError('unreachable');
    }
  }

  /// Runs [fn] with [_source] set to [sql], for compiling stored views and
  /// triggers.
  T _withSource<T>(String sql, T Function() fn) {
    final saved = _source;
    _source = sql;
    try {
      return fn();
    } finally {
      _source = saved;
    }
  }

  void _syncCaches() {
    if (_cacheVersion != catalog.schemaVersion) {
      _viewPlans.clear();
      _triggerPlans.clear();
      _cacheVersion = catalog.schemaVersion;
    }
  }

  // ---------------------------------------------------------------------------
  // Transactions
  // ---------------------------------------------------------------------------

  StatementResult _begin() {
    if (inTransaction) {
      throw const SqlException.misuse(
        'cannot start a transaction within a transaction',
      );
    }
    _txMark = catalog.log.hold();
    _txImplicit = false;
    return StatementResult();
  }

  StatementResult _commit() {
    if (!inTransaction) {
      throw const SqlException.misuse(
        'cannot commit - no transaction is active',
      );
    }
    _endTransaction(rollback: false);
    return StatementResult();
  }

  StatementResult _rollback(String? savepoint) {
    if (!inTransaction) {
      throw const SqlException.misuse(
        'cannot rollback - no transaction is active',
      );
    }
    if (savepoint == null) {
      _endTransaction(rollback: true);
      return StatementResult();
    }
    final i = _findSavepoint(savepoint);
    catalog.log.rollbackTo(_savepoints[i].mark);
    _savepoints.removeRange(i + 1, _savepoints.length);
    _syncCaches();
    return StatementResult();
  }

  StatementResult _savepoint(String name) {
    if (!inTransaction) {
      _txMark = catalog.log.hold();
      _txImplicit = true;
    }
    _savepoints.add(_Savepoint(name, catalog.log.mark()));
    return StatementResult();
  }

  StatementResult _release(String name) {
    if (!inTransaction) {
      throw SqlException.misuse('no such savepoint: $name');
    }
    final i = _findSavepoint(name);
    _savepoints.removeRange(i, _savepoints.length);
    if (_savepoints.isEmpty && _txImplicit) {
      _endTransaction(rollback: false);
    }
    return StatementResult();
  }

  int _findSavepoint(String name) {
    final lower = name.toLowerCase();
    for (var i = _savepoints.length - 1; i >= 0; i--) {
      if (_savepoints[i].name.toLowerCase() == lower) return i;
    }
    throw SqlException.misuse('no such savepoint: $name');
  }

  void _endTransaction({required bool rollback}) {
    if (rollback) catalog.log.rollbackTo(_txMark!);
    _txMark = null;
    _txImplicit = false;
    _savepoints.clear();
    catalog.log.release();
    _syncCaches();
  }

  /// Rolls back an open transaction, if any (used by `close()`).
  void rollbackOpenTransaction() {
    if (inTransaction) _endTransaction(rollback: true);
  }

  // ---------------------------------------------------------------------------
  // PRAGMA
  // ---------------------------------------------------------------------------

  StatementResult _pragma(PragmaStatement p) {
    switch (p.name) {
      case 'foreign_keys':
        if (p.value == null) {
          return StatementResult(
            columns: const ['foreign_keys'],
            rows: [
              [foreignKeys ? 1 : 0],
            ],
          );
        }
        if (inTransaction) return StatementResult(); // no-op, as SQLite
        foreignKeys = _pragmaBool(p.value!);
        return StatementResult();
      case 'user_version':
        if (p.value == null) {
          return StatementResult(
            columns: const ['user_version'],
            rows: [
              [catalog.userVersion],
            ],
          );
        }
        final v = int.tryParse(p.value!);
        if (v == null) {
          throw SqlException('bad user_version: ${p.value}');
        }
        catalog.setUserVersion(v);
        return StatementResult();
      case 'table_info':
        final name = p.value;
        if (name == null) return StatementResult();
        final t = catalog.table(name);
        if (t == null) return StatementResult();
        final pk = [for (final c in t.schema.primaryKey) c.toLowerCase()];
        return StatementResult(
          columns: const ['cid', 'name', 'type', 'notnull', 'dflt_value', 'pk'],
          rows: [
            for (var i = 0; i < t.schema.columns.length; i++)
              [
                i,
                t.schema.columns[i].name,
                t.schema.columns[i].type,
                t.schema.columns[i].notNull ? 1 : 0,
                t.schema.columns[i].defaultSql,
                pk.indexOf(t.schema.columns[i].name.toLowerCase()) + 1,
              ],
          ],
        );
      case 'index_list':
        final name = p.value;
        final t = name == null ? null : catalog.table(name);
        if (t == null) return StatementResult();
        final infos = t.describeIndexes();
        return StatementResult(
          columns: const ['seq', 'name', 'unique', 'origin'],
          rows: [
            for (var i = 0; i < infos.length; i++)
              [
                i,
                infos[i].name,
                infos[i].unique ? 1 : 0,
                switch (infos[i].origin) {
                  IndexOrigin.primaryKey => 'pk',
                  IndexOrigin.unique => 'u',
                  _ => 'c',
                },
              ],
          ],
        );
      default:
        // Unknown pragmas are ignored, as in SQLite.
        return StatementResult();
    }
  }

  static bool _pragmaBool(String v) {
    switch (v.toUpperCase()) {
      case '1':
      case 'ON':
      case 'TRUE':
      case 'YES':
        return true;
      case '0':
      case 'OFF':
      case 'FALSE':
      case 'NO':
        return false;
    }
    throw SqlException('bad boolean pragma value: $v');
  }
}

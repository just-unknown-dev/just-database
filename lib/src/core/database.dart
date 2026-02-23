import 'dart:async';
import '../storage/table.dart';
import '../storage/schema.dart';
import '../storage/persistence.dart';
import '../storage/query_tracker.dart';
import '../sql/ast.dart';
import '../sql/executor.dart';
import '../sql/parser.dart';
import '../concurrency/lock_manager.dart';
import '../benchmark/benchmark.dart';
import 'database_mode.dart';

/// Fluent query builder for convenience wrapping of SQL operations.
class QueryBuilder {
  final JustDatabase _db;
  final String _table;
  final List<String> _selectedColumns = [];
  final List<String> _whereClauses = [];
  final List<String> _orderByClauses = [];
  int? _limitValue;
  int? _offsetValue;

  QueryBuilder._(this._db, this._table);

  QueryBuilder select([List<String>? columns]) {
    _selectedColumns.addAll(columns ?? ['*']);
    return this;
  }

  QueryBuilder where(String condition) {
    _whereClauses.add(condition);
    return this;
  }

  QueryBuilder orderBy(String column, {bool descending = false}) {
    _orderByClauses.add('$column ${descending ? 'DESC' : 'ASC'}');
    return this;
  }

  QueryBuilder limit(int count) {
    _limitValue = count;
    return this;
  }

  QueryBuilder offset(int count) {
    _offsetValue = count;
    return this;
  }

  String _buildSelectSQL() {
    final cols = _selectedColumns.isEmpty ? '*' : _selectedColumns.join(', ');
    final buf = StringBuffer('SELECT $cols FROM $_table');
    if (_whereClauses.isNotEmpty) {
      buf.write(' WHERE ${_whereClauses.join(' AND ')}');
    }
    if (_orderByClauses.isNotEmpty) {
      buf.write(' ORDER BY ${_orderByClauses.join(', ')}');
    }
    if (_limitValue != null) buf.write(' LIMIT $_limitValue');
    if (_offsetValue != null) buf.write(' OFFSET $_offsetValue');
    return buf.toString();
  }

  Future<QueryResult> get() => _db.query(_buildSelectSQL());

  Future<QueryResult> insert(Map<String, dynamic> values) {
    final cols = values.keys.join(', ');
    final vals = values.values.map(_sqlValue).join(', ');
    return _db.execute('INSERT INTO $_table ($cols) VALUES ($vals)');
  }

  Future<QueryResult> update(Map<String, dynamic> values) {
    final sets = values.entries
        .map((e) => '${e.key} = ${_sqlValue(e.value)}')
        .join(', ');
    final where = _whereClauses.isNotEmpty
        ? ' WHERE ${_whereClauses.join(' AND ')}'
        : '';
    return _db.execute('UPDATE $_table SET $sets$where');
  }

  Future<QueryResult> delete() {
    final where = _whereClauses.isNotEmpty
        ? ' WHERE ${_whereClauses.join(' AND ')}'
        : '';
    return _db.execute('DELETE FROM $_table$where');
  }

  String _sqlValue(dynamic v) {
    if (v == null) return 'NULL';
    if (v is String) return "'${v.replaceAll("'", "''")}'";
    if (v is bool) return v ? 'TRUE' : 'FALSE';
    return v.toString();
  }
}

/// The main database class. Wraps the storage, SQL engine, and lock manager.
class JustDatabase {
  final String name;
  final DatabaseMode mode;
  final bool persist;

  /// The AES-256-GCM encryption key used when [mode] is [DatabaseMode.secure].
  /// `null` for all other modes.
  final String? encryptionKey;

  final Map<String, Table> _tables = {};
  late final LockManager _lockManager;
  late final QueryTracker _queryTracker;
  late final Executor _executor;
  bool _isOpen = false;

  JustDatabase._({
    required this.name,
    required this.mode,
    required this.persist,
    this.encryptionKey,
  });

  /// Opens or creates a database.
  /// If [persist] is true and a file exists on disk, loads tables from disk.
  static Future<JustDatabase> open(
    String name, {
    DatabaseMode mode = DatabaseMode.standard,
    bool persist = true,
    String? encryptionKey,
  }) async {
    // Validate key <-> mode pairing.
    if (mode == DatabaseMode.secure && encryptionKey == null) {
      throw ArgumentError.value(
        null,
        'encryptionKey',
        'An encryptionKey is required when using DatabaseMode.secure.',
      );
    }
    if (mode != DatabaseMode.secure && encryptionKey != null) {
      throw ArgumentError.value(
        encryptionKey,
        'encryptionKey',
        'encryptionKey is only valid with DatabaseMode.secure.',
      );
    }

    final db = JustDatabase._(
      name: name,
      mode: mode,
      persist: persist,
      encryptionKey: encryptionKey,
    );
    db._queryTracker = QueryTracker();
    db._lockManager = LockManager.forMode(mode);
    db._executor = Executor(db._tables, queryTracker: db._queryTracker);
    if (persist) {
      try {
        await db._loadFromDisk();
      } on StateError {
        // Wrong encryption key or corrupted file — propagate so the caller knows.
        rethrow;
      } catch (_) {
        // Other load errors (file missing, JSON parse) → start fresh.
      }
    }
    db._isOpen = true;
    return db;
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Executes a SELECT statement and returns results.
  Future<QueryResult> query(String sql) => _runStatement(sql, isWrite: false);

  /// Executes DDL or DML statements (CREATE, INSERT, UPDATE, DELETE, DROP, ALTER).
  Future<QueryResult> execute(String sql) => _runStatement(sql, isWrite: true);

  /// Returns a [QueryBuilder] for fluent query construction on [tableName].
  QueryBuilder from(String tableName) => QueryBuilder._(this, tableName);

  // ---------------------------------------------------------------------------
  // Transaction convenience API
  // ---------------------------------------------------------------------------

  /// Whether a transaction is currently active on this database.
  bool get inTransaction => _executor.inTransaction;

  /// Begins a transaction. Returns an error result if one is already active.
  ///
  /// Example:
  /// ```dart
  /// await db.beginTransaction();
  /// await db.execute('INSERT INTO users ...');
  /// await db.commit();
  /// ```
  Future<QueryResult> beginTransaction({String? mode}) {
    final sql = mode != null ? 'BEGIN $mode' : 'BEGIN';
    return _runStatement(sql, isWrite: true);
  }

  /// Commits the current transaction.
  Future<QueryResult> commit() => _runStatement('COMMIT', isWrite: true);

  /// Rolls back the current transaction.
  /// If [savepoint] is provided, rolls back only to that savepoint.
  Future<QueryResult> rollback({String? savepoint}) {
    final sql = savepoint != null
        ? 'ROLLBACK TO SAVEPOINT $savepoint'
        : 'ROLLBACK';
    return _runStatement(sql, isWrite: true);
  }

  /// Creates a named savepoint within the current transaction.
  Future<QueryResult> savepoint(String name) =>
      _runStatement('SAVEPOINT $name', isWrite: true);

  /// Releases a named savepoint.
  Future<QueryResult> releaseSavepoint(String name) =>
      _runStatement('RELEASE SAVEPOINT $name', isWrite: true);

  /// Executes [action] inside a transaction, automatically committing on
  /// success or rolling back on error.
  ///
  /// Returns the result of the last statement in [action].
  Future<T> transaction<T>(Future<T> Function(JustDatabase db) action) async {
    final beginResult = await beginTransaction();
    if (!beginResult.success) {
      throw StateError('Cannot start transaction: ${beginResult.errorMessage}');
    }
    try {
      final result = await action(this);
      final commitResult = await commit();
      if (!commitResult.success) {
        throw StateError('Commit failed: ${commitResult.errorMessage}');
      }
      return result;
    } catch (_) {
      await rollback();
      rethrow;
    }
  }

  Future<void> close() async {
    _ensureOpen();
    if (persist) await _saveToDisk();
    _isOpen = false;
  }

  // ---------------------------------------------------------------------------
  // Introspection
  // ---------------------------------------------------------------------------

  List<String> get tableNames => List.unmodifiable(_tables.keys);

  /// Returns the names of all defined views.
  List<String> get viewNames => _executor.viewNames;

  /// Returns the names of all defined triggers.
  List<String> get triggerNames => _executor.triggerNames;

  /// Returns the names of all indexes on a named table.
  List<String> indexNamesForTable(String tableName) {
    final key = _findTableKey(tableName);
    return key != null ? (_tables[key]?.indexNames ?? []) : [];
  }

  TableSchema? getTableSchema(String name) {
    final key = _findTableKey(name);
    return key != null ? _tables[key]?.schema : null;
  }

  int get totalRows => _tables.values.fold(0, (s, t) => s + t.rowCount);

  int get estimatedSizeBytes =>
      _tables.values.fold(0, (s, t) => s + t.estimatedSizeBytes);

  bool get isOpen => _isOpen;

  // ---------------------------------------------------------------------------
  // Benchmarking
  // ---------------------------------------------------------------------------

  /// Runs the standard benchmark suite against this database.
  ///
  /// Creates an isolated `_bench_t` table, runs 8 pre-built scenarios
  /// (INSERT, SELECT, UPDATE, DELETE, COUNT, ORDER BY, parse), then
  /// drops the table and returns the results.
  Future<BenchmarkSuiteResult> runStandardBenchmark({
    int rowCount = 1000,
    int warmup = 3,
    int iterations = 50,
  }) {
    _ensureOpen();
    return DatabaseBenchmark(
      executor: _executor,
      rowCount: rowCount,
    ).run(warmup: warmup, iterations: iterations);
  }

  /// Benchmarks a single SQL query by running it [iterations] times.
  Future<QueryStats> benchmarkQuery(
    String label,
    String sql, {
    int warmup = 3,
    int iterations = 50,
  }) {
    _ensureOpen();
    return DatabaseBenchmark(
      executor: _executor,
    ).runQuery(label, sql, warmup: warmup, iterations: iterations);
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<QueryResult> _runStatement(String sql, {required bool isWrite}) async {
    _ensureOpen();
    Statement stmt;
    try {
      stmt = Parser.parseSQL(sql);
    } on ParseException catch (e) {
      return QueryResult.error('Parse error: $e');
    } catch (e) {
      return QueryResult.error('Parse error: $e');
    }

    // Determine the resource name for the lock (table name or '*' for unknown)
    final resourceName = _extractTableName(stmt) ?? '*';

    if (isWrite) {
      await _lockManager.acquireWrite(resourceName);
      try {
        final result = await _executor.execute(stmt);
        if (persist && result.success) {
          unawaited(_saveToDisk());
        }
        return result;
      } finally {
        _lockManager.releaseWrite(resourceName);
      }
    } else {
      await _lockManager.acquireRead(resourceName);
      try {
        return await _executor.execute(stmt);
      } finally {
        _lockManager.releaseRead(resourceName);
      }
    }
  }

  Future<void> _loadFromDisk() async {
    final snapshot = await PersistenceManager.load(
      name,
      encryptionKey: encryptionKey,
    );
    if (snapshot != null) {
      for (final entry in snapshot.tables.entries) {
        _tables[entry.key.toLowerCase()] = entry.value;
      }
    }
  }

  Future<void> _saveToDisk() async {
    try {
      await PersistenceManager.save(
        name,
        _tables,
        mode,
        encryptionKey: encryptionKey,
      );
    } catch (_) {
      // Ignore persistence errors silently
    }
  }

  void _ensureOpen() {
    if (!_isOpen) throw StateError('Database "$name" is not open.');
  }

  String? _extractTableName(Statement stmt) {
    if (stmt is SelectStatement) return stmt.tableName.toLowerCase();
    if (stmt is InsertStatement) return stmt.tableName.toLowerCase();
    if (stmt is UpdateStatement) return stmt.tableName.toLowerCase();
    if (stmt is DeleteStatement) return stmt.tableName.toLowerCase();
    if (stmt is CreateTableStatement) return stmt.tableName.toLowerCase();
    if (stmt is DropTableStatement) return stmt.tableName.toLowerCase();
    if (stmt is AlterTableStatement) return stmt.tableName.toLowerCase();
    // Transaction statements lock the whole database
    if (stmt is BeginStatement ||
        stmt is CommitStatement ||
        stmt is RollbackStatement ||
        stmt is SavepointStatement ||
        stmt is ReleaseStatement) {
      return '*';
    }
    // View statements lock the whole database
    if (stmt is CreateViewStatement) return '*';
    if (stmt is DropViewStatement) return '*';
    // Trigger/index statements lock the whole database
    if (stmt is CreateTriggerStatement) return '*';
    if (stmt is DropTriggerStatement) return '*';
    if (stmt is CreateIndexStatement) return stmt.tableName.toLowerCase();
    if (stmt is DropIndexStatement) return stmt.tableName?.toLowerCase() ?? '*';
    return null;
  }

  String? _findTableKey(String tableName) {
    final lower = tableName.toLowerCase();
    if (_tables.containsKey(lower)) return lower;
    for (final key in _tables.keys) {
      if (key.toLowerCase() == lower) return key;
    }
    return null;
  }
}

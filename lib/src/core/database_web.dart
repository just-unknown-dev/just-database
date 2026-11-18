import 'dart:async';
import '../storage/table.dart';
import '../storage/schema.dart';
import '../storage/query_tracker.dart';
import '../sql/ast.dart';
import '../sql/executor.dart';
import '../sql/parser.dart';
import '../concurrency/lock_manager.dart';
import '../benchmark/benchmark.dart';
import '../web/worker_client_stub.dart'
    if (dart.library.html) '../web/worker_client.dart';
import '../web/idb_persistence.dart' as idb;
import '../web/opfs_support.dart';
import 'database_mode.dart';
import 'migration.dart';

/// The storage backend selected for this web database instance.
enum WebStorageBackend {
  /// Full OPFS with synchronous I/O inside a Web Worker.
  opfsWorker,

  /// IndexedDB fallback — main-thread engine with async blob persistence.
  indexedDb,

  /// In-memory only — no persistence.
  memory,
}

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

/// Web implementation of [JustDatabase].
///
/// Selects the best available storage backend:
/// 1. **OPFS Worker** — spawns a Web Worker running the full SQL engine with
///    synchronous OPFS I/O and WAL. Maximum performance.
/// 2. **IndexedDB** — runs the SQL engine on the main thread and persists
///    database snapshots as JSON blobs in IndexedDB.
/// 3. **In-memory** — no persistence; data only lives for the session.
class JustDatabase {
  final String name;
  final DatabaseMode mode;
  final bool persist;
  final String? encryptionKey;

  /// The storage backend selected during [open].
  late final WebStorageBackend storageBackend;

  // Worker path state (when storageBackend == opfsWorker)
  WorkerClient? _worker;

  // Fallback path state (when storageBackend == indexedDb or memory)
  final Map<String, Table> _tables = {};
  LockManager? _lockManager;
  QueryTracker? _queryTracker;
  Executor? _executor;

  // IndexedDB saves run one at a time, in order. Writes made while a save
  // waits to start share that save, which snapshots the tables when it
  // starts, so the newest state is always written last. See [_scheduleSave].
  Future<void> _saveTail = Future<void>.value();
  Future<void>? _queuedSave;
  int _changes = 0; // successful writes so far
  int _savedChanges = 0; // writes covered by the last successful save

  bool _isOpen = false;

  /// Optional callback invoked when a database opened with `persist: true`
  /// cannot find a durable storage backend and falls back to in-memory mode.
  ///
  /// Data written to an in-memory database will not survive a page reload.
  /// Set this once at app startup to surface the warning in your logging
  /// infrastructure:
  ///
  /// ```dart
  /// import 'dart:developer' as dev;
  /// JustDatabase.onStorageDowngrade = (name, reason) =>
  ///     dev.log('[just_database] $name: $reason', level: 900);
  /// ```
  static void Function(String dbName, String reason)? onStorageDowngrade;

  JustDatabase._({
    required this.name,
    required this.mode,
    required this.persist,
    this.encryptionKey,
  });

  /// Opens or creates a database.
  ///
  /// On web, this probes the environment and selects the best storage backend:
  /// - OPFS with Web Worker if available
  /// - IndexedDB if OPFS is unavailable
  /// - In-memory if neither is available
  ///
  /// With IndexedDB, throws a [StateError] if a stored snapshot exists but
  /// cannot be decoded. It is left untouched rather than replaced by an empty
  /// database.
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

    if (persist) {
      // Try the OPFS + Worker path first
      try {
        final cap = await detectOpfsCapability();
        if (cap == OpfsCapability.full) {
          await db._openWithWorker();
          return db;
        }
      } catch (_) {
        // OPFS detection failed — fall through
      }

      // Try IndexedDB fallback
      if (idb.IdbPersistenceManager.isAvailable) {
        await db._openWithIdb();
        return db;
      }
    }

    // In-memory fallback: persist was requested but no durable backend exists.
    if (persist) {
      onStorageDowngrade?.call(
        name,
        'Neither OPFS nor IndexedDB is available — data will not survive a page reload.',
      );
    }
    await db._openInMemory();
    return db;
  }

  // ---------------------------------------------------------------------------
  // Initialization paths
  // ---------------------------------------------------------------------------

  Future<void> _openWithWorker() async {
    storageBackend = WebStorageBackend.opfsWorker;
    _worker = await WorkerClient.spawn();
    await _worker!.open(
      name: name,
      mode: mode.name,
      persist: persist,
      encryptionKey: encryptionKey,
    );
    _isOpen = true;
  }

  Future<void> _openWithIdb() async {
    storageBackend = WebStorageBackend.indexedDb;
    _initMainThreadEngine();

    // Load from IndexedDB
    try {
      final snapshot = await idb.IdbPersistenceManager.load(name);
      if (snapshot != null) {
        for (final entry in snapshot.tables.entries) {
          _tables[entry.key.toLowerCase()] = entry.value;
        }
      }
    } on StateError {
      // A stored snapshot that cannot be decoded. Starting empty would let
      // the next save overwrite it, so tell the caller.
      rethrow;
    } catch (_) {
      // IndexedDB itself failed → start fresh.
    }
    _isOpen = true;
  }

  Future<void> _openInMemory() async {
    storageBackend = WebStorageBackend.memory;
    _initMainThreadEngine();
    _isOpen = true;
  }

  void _initMainThreadEngine() {
    _queryTracker = QueryTracker();
    _lockManager = LockManager.forMode(mode);
    _executor = Executor(_tables, queryTracker: _queryTracker!);
  }

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Executes a SELECT statement and returns results.
  Future<QueryResult> query(String sql) {
    if (_worker != null) return _worker!.query(sql);
    return _runStatement(sql, isWrite: false);
  }

  /// Executes DDL or DML statements.
  Future<QueryResult> execute(String sql) {
    if (_worker != null) return _worker!.execute(sql);
    return _runStatement(sql, isWrite: true);
  }

  /// Returns a [QueryBuilder] for fluent query construction on [tableName].
  QueryBuilder from(String tableName) => QueryBuilder._(this, tableName);

  // ---------------------------------------------------------------------------
  // Transaction convenience API
  // ---------------------------------------------------------------------------

  /// Whether a transaction is currently active on this database.
  bool get inTransaction {
    if (_worker != null) {
      // Cannot determine synchronously when using worker — return false.
      // Use `inTransactionAsync` for accurate result.
      return false;
    }
    return _executor!.inTransaction;
  }

  Future<QueryResult> beginTransaction({String? mode}) {
    if (_worker != null) return _worker!.beginTransaction(mode: mode);
    final sql = mode != null ? 'BEGIN $mode' : 'BEGIN';
    return _runStatement(sql, isWrite: true);
  }

  Future<QueryResult> commit() {
    if (_worker != null) return _worker!.commit();
    return _runStatement('COMMIT', isWrite: true);
  }

  Future<QueryResult> rollback({String? savepoint}) {
    if (_worker != null) return _worker!.rollback(savepoint: savepoint);
    final sql = savepoint != null
        ? 'ROLLBACK TO SAVEPOINT $savepoint'
        : 'ROLLBACK';
    return _runStatement(sql, isWrite: true);
  }

  Future<QueryResult> savepoint(String name) {
    if (_worker != null) return _worker!.savepoint(name);
    return _runStatement('SAVEPOINT $name', isWrite: true);
  }

  Future<QueryResult> releaseSavepoint(String name) {
    if (_worker != null) return _worker!.releaseSavepoint(name);
    return _runStatement('RELEASE SAVEPOINT $name', isWrite: true);
  }

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

  /// Waits until every write made so far is saved.
  ///
  /// With IndexedDB, [execute] returns before its change is saved: saves run
  /// in the background, one at a time. Await this after critical writes. It
  /// throws if the save fails, whereas background saves fail silently.
  /// Completes at once in OPFS worker mode (the worker logs each statement to
  /// its WAL before replying), in memory, or when nothing is unsaved.
  Future<void> flush() async {
    _ensureOpen();
    if (!persist || storageBackend != WebStorageBackend.indexedDb) return;
    await _saveTail;
    if (_savedChanges < _changes) await _scheduleSave();
  }

  /// Closes the database. With IndexedDB, waits for pending saves and saves
  /// the final state first. Save errors are not thrown here; call [flush]
  /// before closing to observe them.
  Future<void> close() async {
    _ensureOpen();
    _isOpen = false;
    if (_worker != null) {
      await _worker!.close();
      _worker!.dispose();
      _worker = null;
    } else {
      if (persist && storageBackend == WebStorageBackend.indexedDb) {
        await _saveToIdb();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Schema migrations
  // ---------------------------------------------------------------------------

  /// Returns a [MigrationRunner] that applies [migrations] to this database.
  ///
  /// Migrations run straight on the SQL engine, so run them before the rest
  /// of the app uses the database (e.g. right after [open]). With the
  /// IndexedDB backend, every runner operation saves before it returns.
  ///
  /// Throws [UnsupportedError] when [storageBackend] is
  /// [WebStorageBackend.opfsWorker]: the SQL engine then lives in the worker,
  /// and migrations cannot be sent to it yet.
  MigrationRunner migrationRunner(List<Migration> migrations) {
    _ensureOpen();
    if (_executor == null) {
      throw UnsupportedError(
        'Migrations are not supported in OPFS worker mode yet.',
      );
    }
    return MigrationRunner(
      executor: _executor!,
      migrations: migrations,
      guard: _guardMigration,
    );
  }

  /// Applies every pending migration in [migrations], up to [targetVersion]
  /// if given. Shorthand for `migrationRunner(migrations).migrate()`.
  Future<List<MigrationResult>> migrate(
    List<Migration> migrations, {
    int? targetVersion,
  }) => migrationRunner(migrations).migrate(targetVersion: targetVersion);

  Future<T> _guardMigration<T>(Future<T> Function() operation) async {
    _ensureOpen();
    try {
      return await operation();
    } finally {
      if (persist && storageBackend == WebStorageBackend.indexedDb) {
        _changes++;
        await _saveToIdb();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Introspection
  // ---------------------------------------------------------------------------

  List<String> get tableNames {
    if (_worker != null) return []; // Use async version for worker mode
    return List.unmodifiable(_tables.keys);
  }

  List<String> get viewNames {
    if (_worker != null) return [];
    return _executor!.viewNames;
  }

  List<String> get triggerNames {
    if (_worker != null) return [];
    return _executor!.triggerNames;
  }

  List<String> indexNamesForTable(String tableName) {
    if (_worker != null) return [];
    final key = _findTableKey(tableName);
    return key != null ? (_tables[key]?.indexNames ?? []) : [];
  }

  TableSchema? getTableSchema(String name) {
    if (_worker != null) return null; // Use async version for worker mode
    final key = _findTableKey(name);
    return key != null ? _tables[key]?.schema : null;
  }

  int get totalRows {
    if (_worker != null) return 0;
    return _tables.values.fold(0, (s, t) => s + t.rowCount);
  }

  int get estimatedSizeBytes {
    if (_worker != null) return 0;
    return _tables.values.fold(0, (s, t) => s + t.estimatedSizeBytes);
  }

  bool get isOpen => _isOpen;

  // ---------------------------------------------------------------------------
  // Async introspection — works in ALL backends including OPFS worker mode.
  // Prefer these over the sync getters when the storage backend is unknown.
  // ---------------------------------------------------------------------------

  Future<List<String>> tableNamesAsync() {
    if (_worker != null) return _worker!.tableNames;
    return Future.value(List.unmodifiable(_tables.keys));
  }

  Future<List<String>> viewNamesAsync() {
    if (_worker != null) return _worker!.viewNames;
    return Future.value(_executor!.viewNames);
  }

  Future<List<String>> triggerNamesAsync() {
    if (_worker != null) return _worker!.triggerNames;
    return Future.value(_executor!.triggerNames);
  }

  Future<List<String>> indexNamesForTableAsync(String tableName) {
    if (_worker != null) return _worker!.indexNamesForTable(tableName);
    final key = _findTableKey(tableName);
    return Future.value(key != null ? (_tables[key]?.indexNames ?? []) : []);
  }

  Future<TableSchema?> getTableSchemaAsync(String name) async {
    if (_worker != null) {
      final json = await _worker!.getTableSchema(name);
      return json != null ? TableSchema.fromJson(json) : null;
    }
    return getTableSchema(name);
  }

  Future<int> totalRowsAsync() {
    if (_worker != null) return _worker!.totalRows;
    return Future.value(totalRows);
  }

  Future<int> estimatedSizeBytesAsync() {
    if (_worker != null) return _worker!.estimatedSizeBytes;
    return Future.value(estimatedSizeBytes);
  }

  // ---------------------------------------------------------------------------
  // Benchmarking
  // ---------------------------------------------------------------------------

  Future<BenchmarkSuiteResult> runStandardBenchmark({
    int rowCount = 1000,
    int warmup = 3,
    int iterations = 50,
  }) {
    _ensureOpen();
    if (_executor == null) {
      throw UnsupportedError(
        'Benchmarking is not supported in OPFS worker mode.',
      );
    }
    return DatabaseBenchmark(
      executor: _executor!,
      rowCount: rowCount,
    ).run(warmup: warmup, iterations: iterations);
  }

  Future<QueryStats> benchmarkQuery(
    String label,
    String sql, {
    int warmup = 3,
    int iterations = 50,
  }) {
    _ensureOpen();
    if (_executor == null) {
      throw UnsupportedError(
        'Benchmarking is not supported in OPFS worker mode.',
      );
    }
    return DatabaseBenchmark(
      executor: _executor!,
    ).runQuery(label, sql, warmup: warmup, iterations: iterations);
  }

  // ---------------------------------------------------------------------------
  // Internal — fallback main-thread engine
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

    final resourceName = _extractTableName(stmt) ?? '*';

    if (isWrite) {
      await _lockManager!.acquireWrite(resourceName);
      try {
        final result = await _executor!.execute(stmt);
        if (persist &&
            result.success &&
            storageBackend == WebStorageBackend.indexedDb) {
          // The statement returns before its save lands; a page crash in
          // that window loses the unsaved writes. Await flush() for
          // durability. OPFS-worker mode is unaffected — WAL durability is
          // handled there.
          _changes++;
          unawaited(_scheduleSave());
        }
        return result;
      } finally {
        _lockManager!.releaseWrite(resourceName);
      }
    } else {
      await _lockManager!.acquireRead(resourceName);
      try {
        return await _executor!.execute(stmt);
      } finally {
        _lockManager!.releaseRead(resourceName);
      }
    }
  }

  /// Queues an IndexedDB save of the tables after the saves already queued,
  /// and returns it. Fails if the save does.
  ///
  /// At most one save waits to start: callers share it until it starts. It
  /// snapshots the tables as it starts, so it includes every write made while
  /// it waited, and a write made after it started queues the next save.
  Future<void> _scheduleSave() {
    final queued = _queuedSave;
    if (queued != null) return queued;
    final save = _saveTail.then((_) async {
      _queuedSave = null;
      final changes = _changes;
      // Takes its snapshot synchronously, before its first await.
      await idb.IdbPersistenceManager.save(name, _tables, mode);
      _savedChanges = changes;
    });
    _queuedSave = save;
    // Keeps the chain going past a failed save; this also marks the failure
    // as handled, so un-awaited saves never report it as uncaught.
    _saveTail = save.then<void>((_) {}, onError: (Object _) {});
    return save;
  }

  /// Saves after any pending saves, ignoring failures (see [flush]).
  Future<void> _saveToIdb() async {
    try {
      await _scheduleSave();
    } catch (_) {
      // Ignore IDB persistence errors silently
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

  String? _findTableKey(String tableName) {
    final lower = tableName.toLowerCase();
    if (_tables.containsKey(lower)) return lower;
    for (final key in _tables.keys) {
      if (key.toLowerCase() == lower) return key;
    }
    return null;
  }
}

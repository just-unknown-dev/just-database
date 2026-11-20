/// The workbench on the app's own databases: straight calls, no copies.
@internal
library;

import 'package:flutter/foundation.dart' show internal;

import '../../core/benchmark.dart';
import '../../core/database_change.dart';
import '../../core/database_manager.dart';
import '../../core/database_mode.dart';
import '../../core/just_database.dart';
import '../../core/query_result.dart';
import '../../core/secure_key_manager.dart';
import '../../core/workbench_service.dart';
import '../../storage/schema.dart';
import 'admin_backend.dart';

/// [AdminDatabase] over one of the app's [JustDatabase]s.
final class LocalAdminDatabase implements AdminDatabase {
  LocalAdminDatabase._(this.db);

  static final Expando<LocalAdminDatabase> _wrappers = Expando();

  /// The one wrapper of [db], so the screen sees the same object each time.
  factory LocalAdminDatabase.of(JustDatabase db) =>
      _wrappers[db] ??= LocalAdminDatabase._(db);

  /// The app's database.
  final JustDatabase db;

  @override
  String get name => db.name;
  @override
  DatabaseMode get mode => db.mode;
  @override
  bool get persist => db.persist;
  @override
  bool get isOpen => db.isOpen;
  @override
  int get openerCount => db.openerCount;
  @override
  bool get inTransaction => db.inTransaction;
  @override
  Object? get saveError => db.saveError;
  @override
  List<String> get tableNames => db.tableNames;
  @override
  List<String> get viewNames => db.viewNames;
  @override
  List<String> get triggerNames => db.triggerNames;
  @override
  TableSchema? getTableSchema(String table) => db.getTableSchema(table);
  @override
  String? getViewSql(String view) => db.getViewSql(view);
  @override
  String? getTriggerSql(String trigger) => db.getTriggerSql(trigger);
  @override
  String? getTriggerTable(String trigger) => db.getTriggerTable(trigger);
  @override
  List<String> triggerNamesForTable(String table) =>
      db.triggerNamesForTable(table);
  @override
  List<IndexInfo> indexesForTable(String table) => db.indexesForTable(table);
  @override
  List<String> indexNamesForTable(String table) => db.indexNamesForTable(table);
  @override
  int rowCount(String table) => db.rowCount(table);
  @override
  int get totalRows => db.totalRows;
  @override
  int get estimatedSizeBytes => db.estimatedSizeBytes;
  @override
  Stream<DatabaseChange> get changes => db.changes;
  @override
  Future<QueryResult> execute(String sql, [Object? parameters]) =>
      db.execute(sql, parameters);
  @override
  Future<QueryResult> query(String sql, [Object? parameters]) =>
      db.query(sql, parameters);
  @override
  Future<List<QueryResult>> executeScript(String sql) => db.executeScript(sql);
  @override
  Future<void> deleteRows(String table, List<int> rowids) =>
      WorkbenchService.deleteRowsOf(db, table, rowids);
  @override
  Future<void> flush() => db.flush();
  @override
  Future<String> exportSql() => db.exportSql();
  @override
  Future<Map<String, Object?>> exportJson() => db.exportJson();
  @override
  Future<void> importSql(String sql) => db.importSql(sql);
  @override
  Future<void> importJson(Map<String, Object?> json) => db.importJson(json);

  @override
  String toString() => 'LocalAdminDatabase($name)';
}

/// [AdminHost] for this app's databases.
final class LocalAdminHost implements AdminHost {
  @override
  bool get isRemote => false;

  @override
  Stream<void> get listChanges => DatabaseManager.listChanges;

  @override
  Future<List<DatabaseInfo>> listDatabases() => DatabaseManager.listDatabases();

  @override
  AdminDatabase? findOpen(String name) {
    final db = JustDatabase.findOpen(name);
    return db == null ? null : LocalAdminDatabase.of(db);
  }

  @override
  List<AdminDatabase> get openDatabases => [
    for (final db in JustDatabase.openDatabases) LocalAdminDatabase.of(db),
  ];

  @override
  Future<AdminDatabase?> open(
    String name, {
    required DatabaseMode mode,
    String? passphrase,
    required bool encrypted,
  }) async {
    final db = await WorkbenchService.openSaved(
      name,
      mode: mode,
      passphrase: passphrase,
      encrypted: encrypted,
    );
    return db == null ? null : LocalAdminDatabase.of(db);
  }

  @override
  Future<AdminDatabase> create(
    String name, {
    required DatabaseMode mode,
    required bool persist,
    AdminEncryption encryption = AdminEncryption.none,
    String? passphrase,
  }) async => LocalAdminDatabase.of(
    await WorkbenchService.createDatabase(
      name,
      mode: mode,
      persist: persist,
      encryption: encryption,
      passphrase: passphrase,
    ),
  );

  @override
  Future<void> release(AdminDatabase db) => _db(db).close();

  @override
  Future<void> delete(String name) => WorkbenchService.deleteDatabase(name);

  @override
  Future<void> setEncryption(
    AdminDatabase db,
    AdminEncryption encryption, {
    String? passphrase,
  }) => WorkbenchService.setEncryption(
    _db(db),
    encryption,
    passphrase: passphrase,
  );

  @override
  Future<bool> hasStoredKey(String name) =>
      SecureKeyManager.hasAutoKey(dbName: name);

  @override
  Future<BenchmarkSuiteResult> runStandardBenchmark(
    AdminDatabase? db, {
    required int rowCount,
    required int warmup,
    required int iterations,
  }) => db == null
      ? runStandardDatabaseBenchmark(
          rowCount: rowCount,
          warmup: warmup,
          iterations: iterations,
        )
      : _db(db).runStandardBenchmark(
          rowCount: rowCount,
          warmup: warmup,
          iterations: iterations,
        );

  @override
  Future<QueryStats> benchmarkQuery(
    AdminDatabase db,
    String label,
    String sql, {
    required int warmup,
    required int iterations,
  }) => _db(
    db,
  ).benchmarkQuery(label, sql, warmup: warmup, iterations: iterations);

  @override
  Future<void> dispose() async {}

  static JustDatabase _db(AdminDatabase db) => (db as LocalAdminDatabase).db;
}

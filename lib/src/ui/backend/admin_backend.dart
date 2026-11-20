/// What the workbench needs of the databases it shows. The same screen
/// works on the app's own databases (`LocalAdminHost`) and on those of a
/// running app it is connected to (`RemoteAdminHost`, the DevTools
/// extension).
@internal
library;

import 'package:flutter/foundation.dart' show internal;

import '../../core/benchmark.dart';
import '../../core/database_change.dart';
import '../../core/database_manager.dart';
import '../../core/database_mode.dart';
import '../../core/query_result.dart';
import '../../core/workbench_service.dart' show AdminEncryption;
import '../../storage/schema.dart';

/// An open database the workbench shows: what `JustDatabase` offers that
/// the screen uses.
///
/// The getters answer at once, as `JustDatabase`'s do; a remote one answers
/// from a snapshot that every call and change event brings up to date.
abstract interface class AdminDatabase {
  String get name;
  DatabaseMode get mode;
  bool get persist;
  bool get isOpen;
  int get openerCount;
  bool get inTransaction;

  /// Why the last save failed, or null.
  Object? get saveError;

  List<String> get tableNames;
  List<String> get viewNames;
  List<String> get triggerNames;
  TableSchema? getTableSchema(String table);
  String? getViewSql(String view);
  String? getTriggerSql(String trigger);
  String? getTriggerTable(String trigger);
  List<String> triggerNamesForTable(String table);
  List<IndexInfo> indexesForTable(String table);
  List<String> indexNamesForTable(String table);
  int rowCount(String table);
  int get totalRows;
  int get estimatedSizeBytes;

  /// After each committed change; done when the database closes.
  Stream<DatabaseChange> get changes;

  Future<QueryResult> execute(String sql, [Object? parameters]);
  Future<QueryResult> query(String sql, [Object? parameters]);
  Future<List<QueryResult>> executeScript(String sql);

  /// Deletes the rows [rowids] of [table] in one transaction; fails, and
  /// deletes nothing, when one of them is gone.
  Future<void> deleteRows(String table, List<int> rowids);

  /// Waits until every committed change is saved.
  Future<void> flush();

  Future<String> exportSql();
  Future<Map<String, Object?>> exportJson();
  Future<void> importSql(String sql);
  Future<void> importJson(Map<String, Object?> json);
}

/// Where the workbench's databases live: this app, or a running app the
/// workbench is connected to.
abstract interface class AdminHost {
  /// Whether the databases are in another app (so, for example, a seed
  /// callback cannot run on them).
  bool get isRemote;

  /// Fires when databases are created, opened, closed or deleted.
  Stream<void> get listChanges;

  /// Every database: the open ones and the saved ones.
  Future<List<DatabaseInfo>> listDatabases();

  /// The open database [name], or null.
  AdminDatabase? findOpen(String name);

  /// Every open database.
  List<AdminDatabase> get openDatabases;

  /// Opens the saved database [name] in [mode] with [passphrase], or with
  /// the random key stored for it when it is [encrypted]. Returns null when
  /// it needs a passphrase nobody gave. The workbench holds a reference
  /// until [release].
  Future<AdminDatabase?> open(
    String name, {
    required DatabaseMode mode,
    String? passphrase,
    required bool encrypted,
  });

  /// Creates the database [name] (held until [release]).
  Future<AdminDatabase> create(
    String name, {
    required DatabaseMode mode,
    required bool persist,
    AdminEncryption encryption = AdminEncryption.none,
    String? passphrase,
  });

  /// Gives back the reference [open] or [create] took.
  Future<void> release(AdminDatabase db);

  /// Closes [name] for everyone, deletes its file and its stored key.
  Future<void> delete(String name);

  /// Encrypts, re-keys or decrypts [db].
  Future<void> setEncryption(
    AdminDatabase db,
    AdminEncryption encryption, {
    String? passphrase,
  });

  /// Whether a random key is stored for [name].
  Future<bool> hasStoredKey(String name);

  /// The standard benchmark, on [db] or (null) a scratch database.
  Future<BenchmarkSuiteResult> runStandardBenchmark(
    AdminDatabase? db, {
    required int rowCount,
    required int warmup,
    required int iterations,
  });

  /// Times the SELECT [sql] on [db].
  Future<QueryStats> benchmarkQuery(
    AdminDatabase db,
    String label,
    String sql, {
    required int warmup,
    required int iterations,
  });

  /// Gives back what [open] and [create] took and stops listening.
  Future<void> dispose();
}

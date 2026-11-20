/// What an app and a workbench connected to it (the just_database DevTools
/// extension) send each other: the JSON forms of values, results, errors,
/// listings and snapshots of open databases.
@internal
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show internal;

import '../sql/sql_exception.dart';
import '../storage/schema.dart';
import 'benchmark.dart';
import 'database_change.dart';
import 'database_manager.dart';
import 'database_mode.dart';
import 'just_database.dart';
import 'query_result.dart';

/// The protocol's version. A workbench refuses an app that speaks another.
const int workbenchProtocol = 1;

/// The one service extension an app registers; its parameters are
/// `method` and `args` (a JSON object).
const String workbenchExtension = 'ext.just_database.call';

/// The kind of every event an app posts starts with this.
const String workbenchEventPrefix = 'just_database.';

/// Event kind: databases were created, opened, closed or deleted.
const String workbenchListEvent = '${workbenchEventPrefix}list';

/// Event kind: an open database changed (`database`, `change`, `snapshot`).
const String workbenchChangeEvent = '${workbenchEventPrefix}change';

// -----------------------------------------------------------------------------
// Values
// -----------------------------------------------------------------------------

/// The largest integer a JavaScript number holds exactly.
const int _maxSafeInt = 9007199254740991;

/// [value] (null, an int, a double, a String or a Uint8List) as JSON. What
/// JSON cannot carry exactly is tagged: blobs, non-finite doubles, and
/// integers a JavaScript number would round.
Object? encodeValue(Object? value) => switch (value) {
  null || String() || bool() => value,
  int() when value > _maxSafeInt || value < -_maxSafeInt => {r'$int': '$value'},
  int() => value,
  double() when !value.isFinite => {r'$real': '$value'},
  double() => value,
  Uint8List() => {r'$blob': base64Encode(value)},
  _ => '$value',
};

/// The value [json] (written by [encodeValue]) stands for.
Object? decodeValue(Object? json) => switch (json) {
  {r'$int': final String text} => int.parse(text),
  {r'$real': final String text} => double.parse(text),
  {r'$blob': final String text} => base64Decode(text),
  _ => json,
};

/// Statement parameters (null, a list, or a map of names) as JSON.
Object? encodeParameters(Object? parameters) => switch (parameters) {
  null => null,
  List() => [for (final v in parameters) encodeValue(v)],
  Map() => {
    for (final MapEntry(:key, :value) in parameters.entries)
      '$key': encodeValue(value),
  },
  _ => throw ArgumentError(
    'parameters must be a List or a Map, not ${parameters.runtimeType}',
  ),
};

/// The parameters [json] (written by [encodeParameters]) stands for.
Object? decodeParameters(Object? json) => switch (json) {
  null => null,
  List() => [for (final v in json) decodeValue(v)],
  Map() => {
    for (final MapEntry(:key, :value) in json.entries)
      '$key': decodeValue(value),
  },
  _ => throw const FormatException('parameters must be a list or an object'),
};

// -----------------------------------------------------------------------------
// Results and errors
// -----------------------------------------------------------------------------

/// [error] as JSON.
Map<String, Object?> encodeSqlException(SqlException error) => {
  'message': error.message,
  'kind': error.kind.name,
  if (error.sql != null) 'sql': error.sql,
  if (error.offset != null) 'offset': error.offset,
};

/// The [SqlException] [json] (written by [encodeSqlException]) stands for.
SqlException decodeSqlException(Map<String, Object?> json) => SqlException(
  json['message'] as String? ?? 'the statement failed',
  kind: SqlErrorKind.values.asNameMap()[json['kind']] ?? SqlErrorKind.error,
  sql: json['sql'] as String?,
  offset: json['offset'] as int?,
);

/// [result] as JSON.
Map<String, Object?> encodeResult(QueryResult result) => {
  'columns': result.columns,
  'values': [
    for (final row in result.values) [for (final v in row) encodeValue(v)],
  ],
  'affectedRows': result.affectedRows,
  if (result.lastInsertRowId != null)
    'lastInsertRowId': encodeValue(result.lastInsertRowId),
  if (result.error != null) 'error': encodeSqlException(result.error!),
  'elapsedUs': result.elapsed.inMicroseconds,
};

/// The [QueryResult] [json] (written by [encodeResult]) stands for.
QueryResult decodeResult(Map<String, Object?> json) {
  final elapsed = Duration(microseconds: json['elapsedUs'] as int? ?? 0);
  final error = json['error'];
  if (error is Map<String, Object?>) {
    return QueryResult.failure(decodeSqlException(error), elapsed: elapsed);
  }
  return QueryResult.success(
    columns: [for (final c in json['columns'] as List? ?? const []) '$c'],
    values: [
      for (final row in json['values'] as List? ?? const [])
        [for (final v in row as List) decodeValue(v)],
    ],
    affectedRows: json['affectedRows'] as int? ?? 0,
    lastInsertRowId: decodeValue(json['lastInsertRowId']) as int?,
    elapsed: elapsed,
  );
}

/// [error], thrown by the app, as JSON, so the workbench can throw the same
/// kind of error with the same message.
Map<String, Object?> encodeError(Object error) => switch (error) {
  SqlException() => {'type': 'sql', ...encodeSqlException(error)},
  StateError() => {'type': 'state', 'message': error.message},
  ArgumentError() => {'type': 'argument', 'message': '${error.message}'},
  FormatException() => {'type': 'format', 'message': error.message},
  _ => {'type': 'other', 'message': '$error'},
};

/// The error [json] (written by [encodeError]) stands for.
Object decodeError(Map<String, Object?> json) {
  final message = json['message'] as String? ?? 'the app reported an error';
  return switch (json['type']) {
    'sql' => decodeSqlException(json),
    'state' => StateError(message),
    'argument' => ArgumentError(message),
    'format' => FormatException(message),
    _ => WorkbenchRemoteError(message),
  };
}

/// An error the app reported that has no kind of its own here.
final class WorkbenchRemoteError implements Exception {
  const WorkbenchRemoteError(this.message);

  final String message;

  @override
  String toString() => message;
}

// -----------------------------------------------------------------------------
// Listings, changes and benchmarks
// -----------------------------------------------------------------------------

/// [info] as JSON.
Map<String, Object?> encodeDatabaseInfo(DatabaseInfo info) => {
  'name': info.name,
  'isOpen': info.isOpen,
  'isPersisted': info.isPersisted,
  'isEncrypted': info.isEncrypted,
  'sizeBytes': info.sizeBytes,
  if (info.mode != null) 'mode': info.mode!.name,
  if (info.tableCount != null) 'tableCount': info.tableCount,
  if (info.totalRows != null) 'totalRows': info.totalRows,
};

/// The [DatabaseInfo] [json] (written by [encodeDatabaseInfo]) stands for.
DatabaseInfo decodeDatabaseInfo(Map<String, Object?> json) => DatabaseInfo(
  name: json['name'] as String,
  isOpen: json['isOpen'] as bool? ?? false,
  isPersisted: json['isPersisted'] as bool? ?? false,
  isEncrypted: json['isEncrypted'] as bool? ?? false,
  sizeBytes: json['sizeBytes'] as int? ?? 0,
  mode: DatabaseMode.values.asNameMap()[json['mode']],
  tableCount: json['tableCount'] as int?,
  totalRows: json['totalRows'] as int?,
);

/// [change] as JSON.
Map<String, Object?> encodeChange(DatabaseChange change) => {
  'tables': [...change.tables],
  'schemaChanged': change.schemaChanged,
};

/// The [DatabaseChange] [json] (written by [encodeChange]) stands for.
DatabaseChange decodeChange(Map<String, Object?> json) => DatabaseChange(
  tables: {for (final t in json['tables'] as List? ?? const []) '$t'},
  schemaChanged: json['schemaChanged'] as bool? ?? false,
);

/// [stats] as JSON.
Map<String, Object?> encodeQueryStats(QueryStats stats) => {
  'label': stats.label,
  'iterations': stats.iterations,
  'timesUs': [for (final t in stats.times) t.inMicroseconds],
};

/// The [QueryStats] [json] (written by [encodeQueryStats]) stands for.
QueryStats decodeQueryStats(Map<String, Object?> json) => QueryStats(
  label: json['label'] as String? ?? '',
  iterations: json['iterations'] as int? ?? 0,
  times: [
    for (final t in json['timesUs'] as List? ?? const [])
      Duration(microseconds: t as int),
  ],
);

/// [result] as JSON.
Map<String, Object?> encodeSuiteResult(BenchmarkSuiteResult result) => {
  'suiteName': result.suiteName,
  'results': [for (final r in result.results) encodeQueryStats(r)],
  'runAt': result.runAt.toIso8601String(),
};

/// The [BenchmarkSuiteResult] [json] (written by [encodeSuiteResult])
/// stands for.
BenchmarkSuiteResult decodeSuiteResult(Map<String, Object?> json) =>
    BenchmarkSuiteResult(
      suiteName: json['suiteName'] as String? ?? '',
      results: [
        for (final r in json['results'] as List? ?? const [])
          decodeQueryStats(r as Map<String, Object?>),
      ],
      runAt:
          DateTime.tryParse(json['runAt'] as String? ?? '') ?? DateTime.now(),
    );

// -----------------------------------------------------------------------------
// Snapshots
// -----------------------------------------------------------------------------

/// A table in a [DatabaseSnapshot].
final class TableSnapshot {
  const TableSnapshot({
    required this.schema,
    required this.rowCount,
    required this.indexes,
  });

  final TableSchema schema;
  final int rowCount;

  /// Constraint indexes included, as `JustDatabase.indexesForTable` gives
  /// them.
  final List<IndexInfo> indexes;
}

/// A view or a trigger in a [DatabaseSnapshot].
final class ObjectSnapshot {
  const ObjectSnapshot({required this.name, required this.sql, this.table});

  final String name;
  final String sql;

  /// A trigger's table or view; null for a view.
  final String? table;
}

/// What a workbench knows of an open database between calls: its state,
/// schema and counts, so it can answer the same questions the app's
/// `JustDatabase` answers at once.
final class DatabaseSnapshot {
  const DatabaseSnapshot({
    required this.name,
    required this.mode,
    required this.persist,
    required this.isOpen,
    required this.openerCount,
    required this.inTransaction,
    required this.saveError,
    required this.estimatedSizeBytes,
    required this.tables,
    required this.views,
    required this.triggers,
  });

  /// The snapshot of [db] now.
  factory DatabaseSnapshot.of(JustDatabase db) => DatabaseSnapshot(
    name: db.name,
    mode: db.mode,
    persist: db.persist,
    isOpen: db.isOpen,
    openerCount: db.openerCount,
    inTransaction: db.inTransaction,
    saveError: db.saveError,
    estimatedSizeBytes: db.estimatedSizeBytes,
    tables: [
      for (final name in db.tableNames)
        if (db.getTableSchema(name) case final schema?)
          TableSnapshot(
            schema: schema,
            rowCount: db.rowCount(name),
            indexes: db.indexesForTable(name),
          ),
    ],
    views: [
      for (final name in db.viewNames)
        ObjectSnapshot(name: name, sql: db.getViewSql(name) ?? ''),
    ],
    triggers: [
      for (final name in db.triggerNames)
        ObjectSnapshot(
          name: name,
          sql: db.getTriggerSql(name) ?? '',
          table: db.getTriggerTable(name),
        ),
    ],
  );

  final String name;
  final DatabaseMode mode;
  final bool persist;
  final bool isOpen;
  final int openerCount;
  final bool inTransaction;

  /// Why the last save failed (an error object), or null.
  final Object? saveError;
  final int estimatedSizeBytes;
  final List<TableSnapshot> tables;
  final List<ObjectSnapshot> views;

  /// In creation order.
  final List<ObjectSnapshot> triggers;

  Map<String, Object?> toJson() => {
    'name': name,
    'mode': mode.name,
    'persist': persist,
    'isOpen': isOpen,
    'openerCount': openerCount,
    'inTransaction': inTransaction,
    if (saveError != null) 'saveError': encodeError(saveError!),
    'estimatedSizeBytes': estimatedSizeBytes,
    'tables': [
      for (final t in tables)
        {
          'schema': t.schema.toJson(),
          'rowCount': t.rowCount,
          'indexes': [
            for (final i in t.indexes)
              {
                'name': i.name,
                'table': i.table,
                'columns': i.columns,
                'unique': i.unique,
                'origin': i.origin.name,
              },
          ],
        },
    ],
    'views': [
      for (final v in views) {'name': v.name, 'sql': v.sql},
    ],
    'triggers': [
      for (final t in triggers)
        {'name': t.name, 'sql': t.sql, 'table': t.table},
    ],
  };

  /// Reads the form written by [toJson].
  factory DatabaseSnapshot.fromJson(Map<String, Object?> json) {
    List<Map<String, Object?>> list(String key) => [
      for (final e in json[key] as List? ?? const []) e as Map<String, Object?>,
    ];
    final saveError = json['saveError'];
    return DatabaseSnapshot(
      name: json['name'] as String,
      mode:
          DatabaseMode.values.asNameMap()[json['mode']] ??
          DatabaseMode.standard,
      persist: json['persist'] as bool? ?? false,
      isOpen: json['isOpen'] as bool? ?? false,
      openerCount: json['openerCount'] as int? ?? 0,
      inTransaction: json['inTransaction'] as bool? ?? false,
      saveError: saveError is Map<String, Object?>
          ? decodeError(saveError)
          : null,
      estimatedSizeBytes: json['estimatedSizeBytes'] as int? ?? 0,
      tables: [
        for (final t in list('tables'))
          TableSnapshot(
            schema: TableSchema.fromJson(t['schema'] as Map<String, Object?>),
            rowCount: t['rowCount'] as int? ?? 0,
            indexes: [
              for (final i in t['indexes'] as List? ?? const [])
                if (i case final Map<String, Object?> i)
                  IndexInfo(
                    name: i['name'] as String,
                    table: i['table'] as String,
                    columns: [
                      for (final c in i['columns'] as List? ?? const []) '$c',
                    ],
                    unique: i['unique'] as bool? ?? false,
                    origin:
                        IndexOrigin.values.asNameMap()[i['origin']] ??
                        IndexOrigin.manual,
                  ),
            ],
          ),
      ],
      views: [
        for (final v in list('views'))
          ObjectSnapshot(name: v['name'] as String, sql: v['sql'] as String),
      ],
      triggers: [
        for (final t in list('triggers'))
          ObjectSnapshot(
            name: t['name'] as String,
            sql: t['sql'] as String,
            table: t['table'] as String?,
          ),
      ],
    );
  }
}

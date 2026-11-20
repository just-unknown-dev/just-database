import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, internal;

import '../storage/catalog.dart';
import '../storage/index.dart';
import '../storage/schema.dart';
import '../storage/table.dart';
import '../storage/values.dart';

/// The newest file format this version writes and reads.
@internal
const int currentFormatVersion = 2;

/// Encodes everything [catalog] holds as the JSON of file format 2.
///
/// ```json
/// {"format": "just_database", "version": 2, "userVersion": 0,
///  "tables": [{"schema": {…}, "sequence": 0, "rows": [[rowid, v…], …],
///              "indexes": [{"name": …, "columns": […], "unique": false}],
///              "spatial": [{"name": …, "x": "lng", "y": "lat"}]}],
///  "views": [{"name": …, "sql": "CREATE VIEW …"}],
///  "triggers": [{"name": …, "table": …, "sql": "CREATE TRIGGER …"}]}
/// ```
///
/// Values are JSON numbers and strings; a blob is `{"$blob": base64}` and
/// an infinite real is `{"$real": "Infinity"}` / `"-Infinity"`.
@internal
Map<String, Object?> encodeCatalog(Catalog catalog) => {
  'format': 'just_database',
  'version': currentFormatVersion,
  if (catalog.userVersion != 0) 'userVersion': catalog.userVersion,
  'tables': [for (final t in catalog.tables) _encodeTable(t)],
  'views': [
    for (final v in catalog.views) {'name': v.name, 'sql': v.sql},
  ],
  'triggers': [
    for (final t in catalog.triggers)
      {'name': t.name, 'table': t.table, 'sql': t.sql},
  ],
};

/// [encodeCatalog] as UTF-8 JSON bytes.
@internal
Uint8List encodeCatalogBytes(Catalog catalog) =>
    Uint8List.fromList(utf8.encode(jsonEncode(encodeCatalog(catalog))));

Map<String, Object?> _encodeTable(TableData t) {
  final cols = t.schema.columns;
  return {
    'schema': t.schema.toJson(),
    if (t.sequence != 0) 'sequence': t.sequence,
    'rows': [
      for (final e in t.entries)
        [e.key, for (final v in e.value) _encodeValue(v)],
    ],
    'indexes': [
      for (final i in t.indexes)
        if (i.origin == IndexOrigin.manual)
          {
            'name': i.name,
            'columns': [for (final c in i.columns) cols[c].name],
            if (i.unique) 'unique': true,
            if (i.collations.any((c) => c != Collation.binary))
              'collations': [
                for (final c in i.collations) c.name.toUpperCase(),
              ],
          },
    ],
    if (t.spatialIndexes.isNotEmpty)
      'spatial': [
        for (final s in t.spatialIndexes)
          {
            'name': s.name,
            'x': cols[s.xColumn].name,
            'y': cols[s.yColumn].name,
          },
      ],
  };
}

Object? _encodeValue(Object? v) => switch (v) {
  Uint8List() => {r'$blob': base64.encode(v)},
  double() when v.isInfinite => {r'$real': v > 0 ? 'Infinity' : '-Infinity'},
  double() when v.isNaN => null,
  _ => v,
};

Object? _decodeValue(Object? v) {
  if (v is Map) {
    if (v.containsKey(r'$blob')) return base64.decode(v[r'$blob'] as String);
    if (v.containsKey(r'$real')) {
      return v[r'$real'] == 'Infinity'
          ? double.infinity
          : double.negativeInfinity;
    }
    throw const FormatException('unknown value marker');
  }
  return v;
}

/// Decodes a database written in format 1 (just_database 1.x) or 2 into a
/// new catalog. Throws [FormatException] for a file written by a newer
/// version or one that is not a database.
@internal
Catalog decodeCatalog(Map<String, Object?> json) {
  final version = json['version'];
  if (version is! int) {
    throw const FormatException('not a just_database file (no version)');
  }
  if (version > currentFormatVersion) {
    throw FormatException(
      'database file format $version was written by a newer just_database; '
      'this version reads up to $currentFormatVersion',
    );
  }
  if (version < 2) return _decodeV1(json);
  final catalog = Catalog();
  catalog.loadUserVersion(json['userVersion'] as int? ?? 0);
  for (final raw in json['tables'] as List) {
    final tj = raw as Map<String, Object?>;
    final schema = TableSchema.fromJson(tj['schema'] as Map<String, Object?>);
    final t = TableData(schema, catalog.log)
      ..sequence = tj['sequence'] as int? ?? 0;
    for (final r in tj['rows'] as List) {
      final row = r as List;
      t.loadRow(row[0] as int, [
        for (var i = 1; i < row.length; i++) _decodeValue(row[i]),
      ]);
    }
    for (final ij in (tj['indexes'] as List?) ?? const []) {
      final m = ij as Map<String, Object?>;
      final positions = [
        for (final c in m['columns'] as List) schema.indexOf(c as String)!,
      ];
      final colls = (m['collations'] as List?)?.cast<String>();
      t.indexes.add(
        TableIndex(
          name: m['name'] as String,
          columns: positions,
          collations: [
            for (var k = 0; k < positions.length; k++)
              colls == null
                  ? Collation.binary
                  : (Collation.parse(colls[k]) ?? Collation.binary),
          ],
          unique: m['unique'] as bool? ?? false,
          origin: IndexOrigin.manual,
        ),
      );
    }
    for (final sj in (tj['spatial'] as List?) ?? const []) {
      final m = sj as Map<String, Object?>;
      t.spatialIndexes.add(
        SpatialIndex(
          name: m['name'] as String,
          xColumn: schema.indexOf(m['x'] as String)!,
          yColumn: schema.indexOf(m['y'] as String)!,
        ),
      );
    }
    final broken = t.rebuildIndexes();
    if (broken != null) {
      throw FormatException(
        'table ${schema.name} breaks its unique index $broken',
      );
    }
    catalog.loadTable(t);
  }
  for (final raw in (json['views'] as List?) ?? const []) {
    final m = raw as Map<String, Object?>;
    catalog.loadView(
      ViewDefinition(name: m['name'] as String, sql: m['sql'] as String),
    );
  }
  for (final raw in (json['triggers'] as List?) ?? const []) {
    final m = raw as Map<String, Object?>;
    catalog.loadTrigger(
      TriggerDefinition(
        name: m['name'] as String,
        table: m['table'] as String,
        sql: m['sql'] as String,
      ),
    );
  }
  return catalog;
}

// -----------------------------------------------------------------------------
// Format 1 (just_database 1.x)
// -----------------------------------------------------------------------------

const _v1Types = {
  'integer': 'INTEGER',
  'text': 'TEXT',
  'real': 'REAL',
  'blob': 'BLOB',
  'boolean': 'BOOLEAN',
  'datetime': 'DATETIME',
};

Object? _v1Value(Object? v) {
  if (v is bool) return v ? 1 : 0;
  if (v is Map) {
    if (v['__type'] == 'blob') return base64.decode(v['data'] as String);
    if (v['__type'] == 'datetime') {
      return DateTime.parse(v['data'] as String).toUtc().toIso8601String();
    }
  }
  return v;
}

Catalog _decodeV1(Map<String, Object?> json) {
  final catalog = Catalog();
  final tables = json['tables'] as Map<String, Object?>? ?? const {};
  for (final entry in tables.entries) {
    final tj = entry.value as Map<String, Object?>;
    final sj = tj['schema'] as Map<String, Object?>;
    final name = sj['tableName'] as String;
    final rawCols = [
      for (final c in sj['columns'] as List) c as Map<String, Object?>,
    ];
    final rawRows = [
      for (final r in (tj['rows'] as List?) ?? const [])
        [for (final v in r as List) _v1Value(v)],
    ];
    var columns = <ColumnDefinition>[];
    final constraints = <TableConstraint>[];
    for (final c in rawCols) {
      final k = (c['constraints'] as Map<String, Object?>?) ?? const {};
      final hasDefault = k['hasDefault'] as bool? ?? false;
      columns.add(
        ColumnDefinition(
          name: c['name'] as String,
          type: _v1Types[c['type']] ?? 'TEXT',
          notNull: k['notNull'] as bool? ?? false,
          primaryKey: k['primaryKey'] as bool? ?? false,
          autoIncrement: k['autoIncrement'] as bool? ?? false,
          unique: k['unique'] as bool? ?? false,
          defaultSql: hasDefault
              ? sqlLiteral(_v1Value(k['defaultValue']))
              : null,
        ),
      );
      final fkTable = k['foreignKeyTable'] as String?;
      if (fkTable != null) {
        final fkCol = k['foreignKeyColumn'] as String?;
        constraints.add(
          TableConstraint(
            kind: TableConstraintKind.foreignKey,
            columns: [c['name'] as String],
            foreignKey: ForeignKeyDefinition(
              columns: [c['name'] as String],
              parentTable: fkTable,
              parentColumns: fkCol == null ? const [] : [fkCol],
              onDelete: ForeignKeyAction.fromName(k['onDelete'] as String?),
              onUpdate: ForeignKeyAction.fromName(k['onUpdate'] as String?),
            ),
          ),
        );
      }
    }
    for (final raw in (sj['tableConstraints'] as List?) ?? const []) {
      final m = raw as Map<String, Object?>;
      final kind = m['type'] == 'primaryKey'
          ? TableConstraintKind.primaryKey
          : (m['type'] == 'unique' ? TableConstraintKind.unique : null);
      if (kind == null) continue;
      constraints.add(
        TableConstraint(
          kind: kind,
          name: m['name'] as String?,
          columns: (m['columns'] as List).cast<String>(),
        ),
      );
    }
    // Only one primary key: a column-level one wins, as 1.x read it.
    if (columns.where((c) => c.primaryKey).isNotEmpty) {
      constraints.removeWhere((c) => c.kind == TableConstraintKind.primaryKey);
      var seen = false;
      columns = [
        for (final c in columns)
          if (c.primaryKey && seen)
            c.copyWith(primaryKey: false)
          else
            () {
              if (c.primaryKey) seen = true;
              return c;
            }(),
      ];
    }
    var schema = TableSchema(
      name: name,
      columns: columns,
      constraints: constraints,
    );
    // An INTEGER PRIMARY KEY becomes the rowid, as in SQLite; 1.x let it
    // hold NULLs, non-integers and duplicates, which a rowid cannot.
    var alias = schema.rowidAlias;
    if (alias != null) {
      final seenIds = <int>{};
      var ok = true;
      for (final r in rawRows) {
        final v = alias < r.length ? r[alias] : null;
        if (v is! int || !seenIds.add(v)) {
          if (v != null) ok = false;
        }
      }
      if (!ok) {
        schema = _demote(schema, [schema.columns[alias].name], 'rowid');
        alias = null;
      }
    }
    // Keys 1.x failed to enforce may already hold duplicates: keep the
    // rows and drop the constraint, with a warning.
    for (final key in schema.uniqueKeys) {
      final positions = [for (final c in key) schema.indexOf(c)!];
      final seen = <Object>{};
      for (final r in rawRows) {
        final parts = [for (final p in positions) p < r.length ? r[p] : null];
        if (parts.contains(null)) continue;
        if (!seen.add(CompositeKey([for (final v in parts) keyOf(v)]))) {
          schema = _demote(schema, key, 'unique');
          break;
        }
      }
    }
    final t = TableData(schema, catalog.log);
    final used = <int>{
      if (alias != null)
        for (final r in rawRows)
          if (alias < r.length && r[alias] is int) r[alias] as int,
    };
    var next = 1;
    for (final r in rawRows) {
      final values = [
        for (var i = 0; i < schema.columns.length; i++)
          i < r.length ? r[i] : null,
      ];
      final aliasValue = alias == null ? null : values[alias];
      int rowid;
      if (aliasValue is int) {
        rowid = aliasValue;
      } else {
        while (used.contains(next)) {
          next++;
        }
        rowid = next++;
        used.add(rowid);
        if (alias != null) values[alias] = rowid;
      }
      t.loadRow(rowid, values);
    }
    if (schema.autoIncrement) {
      final seq = tj['autoIncrement'] as int? ?? 0;
      t.sequence = seq;
    }
    for (final raw in (tj['indices'] as List?) ?? const []) {
      final m = raw as Map<String, Object?>;
      final type = m['type'] as String?;
      final cols = (m['columns'] as List).cast<String>();
      final positions = [for (final c in cols) schema.indexOf(c)];
      if (positions.contains(null)) continue;
      if (type == 'manual') {
        t.indexes.add(
          TableIndex(
            name: m['name'] as String,
            columns: positions.cast<int>(),
            collations: [for (final _ in positions) Collation.binary],
            unique: m['unique'] as bool? ?? false,
            origin: IndexOrigin.manual,
          ),
        );
      } else if (type == 'spatial' && positions.length == 2) {
        t.spatialIndexes.add(
          SpatialIndex(
            name: m['name'] as String,
            xColumn: positions[0]!,
            yColumn: positions[1]!,
          ),
        );
      }
    }
    final broken = t.rebuildIndexes();
    if (broken != null) {
      // A unique manual index the data breaks: keep it, not unique.
      final i = t.indexes.indexWhere((x) => x.name == broken);
      final old = t.indexes[i];
      t.indexes[i] = TableIndex(
        name: old.name,
        columns: old.columns,
        collations: old.collations,
        unique: false,
        origin: old.origin,
      );
      t.rebuildIndexes();
      debugPrint(
        'just_database: index $broken of $name is no longer unique (duplicate values)',
      );
    }
    catalog.loadTable(t);
  }
  return catalog;
}

/// [schema] without the key on [columns] (and its rowid alias), logged.
TableSchema _demote(TableSchema schema, List<String> columns, String what) {
  final lower = [for (final c in columns) c.toLowerCase()];
  debugPrint(
    'just_database: ${schema.name}(${columns.join(', ')}) holds duplicate or '
    'non-integer values, so its $what constraint was dropped when the 1.x '
    'file was read',
  );
  bool same(List<String> cs) =>
      cs.length == lower.length &&
      [for (final c in cs) c.toLowerCase()].join('\u0000') ==
          lower.join('\u0000');
  return schema.copyWith(
    columns: [
      for (final c in schema.columns)
        if (lower.length == 1 && c.name.toLowerCase() == lower.single)
          ColumnDefinition(
            name: c.name,
            type: what == 'rowid' && c.type.toUpperCase() == 'INTEGER'
                ? 'INT'
                : c.type,
            notNull: c.notNull,
            primaryKey: what == 'rowid' ? c.primaryKey : false,
            autoIncrement: false,
            unique: false,
            defaultSql: c.defaultSql,
            collation: c.collation,
          )
        else
          c,
    ],
    constraints: [
      for (final c in schema.constraints)
        if (!((c.kind == TableConstraintKind.primaryKey ||
                c.kind == TableConstraintKind.unique) &&
            same(c.columns)))
          c,
    ],
  );
}

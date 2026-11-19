import 'dart:collection';

import 'package:flutter/foundation.dart' show internal;

import 'index.dart';
import 'schema.dart';
import 'undo_log.dart';
import 'values.dart';

/// The largest rowid.
@internal
final int maxRowId = maxInt64;

/// The rows of one table, kept by rowid in rowid order, with the indexes
/// that enforce its keys and those created by `CREATE INDEX`.
///
/// The SQL engine validates a change before making it (NOT NULL, CHECK,
/// UNIQUE, foreign keys); these methods only apply it, keep every index
/// current, and record the undo of each change in the [UndoLog].
@internal
final class TableData {
  /// Creates an empty table with [schema].
  TableData(TableSchema schema, this._log) : _schema = schema {
    _constraintIndexes();
    ensureForeignKeyIndexes();
  }

  final UndoLog _log;
  TableSchema _schema;
  final SplayTreeMap<int, List<Object?>> _rows =
      SplayTreeMap<int, List<Object?>>();

  /// AUTOINCREMENT's high-water mark: the largest rowid ever used.
  int sequence = 0;

  /// Every index, constraint indexes first.
  final List<TableIndex> indexes = [];

  /// Every spatial index.
  final List<SpatialIndex> spatialIndexes = [];

  /// The table's schema.
  TableSchema get schema => _schema;

  /// The table's name.
  String get name => _schema.name;

  /// The number of rows.
  int get rowCount => _rows.length;

  /// The rows, by rowid, in rowid order. The lists are the stored rows; do
  /// not change them.
  Iterable<MapEntry<int, List<Object?>>> get entries => _rows.entries;

  /// The rowids, in order.
  Iterable<int> get rowids => _rows.keys;

  /// The stored row with [rowid], or null. Do not change it.
  List<Object?>? row(int rowid) => _rows[rowid];

  /// The rowid for a new row: one past the largest rowid (or past the
  /// AUTOINCREMENT high-water mark). Throws [StateError] when the rowid
  /// space is used up.
  int newRowId() {
    var base = _rows.isEmpty ? 0 : _rows.lastKey()!;
    if (_schema.autoIncrement && sequence > base) base = sequence;
    if (base < maxRowId) return base + 1;
    if (_schema.autoIncrement) {
      throw StateError('database or disk is full (AUTOINCREMENT exhausted)');
    }
    // As SQLite: look for an unused rowid.
    var candidate = 1;
    for (final k in _rows.keys) {
      if (k > candidate) return candidate;
      if (k == candidate) candidate++;
    }
    throw StateError('database or disk is full (no rowid left)');
  }

  // ---------------------------------------------------------------------------
  // Row changes
  // ---------------------------------------------------------------------------

  /// Stores [values] under [rowid], which must be unused.
  void insert(int rowid, List<Object?> values) {
    assert(!_rows.containsKey(rowid));
    _rawInsert(rowid, values);
    if (rowid > sequence && _schema.autoIncrement) {
      final old = sequence;
      sequence = rowid;
      _log.record(() => sequence = old);
    }
    _log.record(() => _rawDelete(rowid));
  }

  /// Deletes the row with [rowid] and returns it.
  List<Object?> delete(int rowid) {
    final old = _rawDelete(rowid);
    _log.record(() => _rawInsert(rowid, old));
    return old;
  }

  /// Replaces the row with [rowid] by [values], moving it to [newRowid]
  /// when that differs (the rowid alias changed).
  void update(int rowid, List<Object?> values, {int? newRowid}) {
    final target = newRowid ?? rowid;
    final old = _rawDelete(rowid);
    _rawInsert(target, values);
    if (target > sequence && _schema.autoIncrement) {
      final oldSeq = sequence;
      sequence = target;
      _log.record(() => sequence = oldSeq);
    }
    _log.record(() {
      _rawDelete(target);
      _rawInsert(rowid, old);
    });
  }

  void _rawInsert(int rowid, List<Object?> values) {
    _rows[rowid] = values;
    for (final i in indexes) {
      i.add(values, rowid);
    }
    for (final s in spatialIndexes) {
      s.add(values, rowid);
    }
  }

  List<Object?> _rawDelete(int rowid) {
    final old = _rows.remove(rowid);
    if (old == null) throw StateError('No row $rowid in $name');
    for (final i in indexes) {
      i.remove(old, rowid);
    }
    for (final s in spatialIndexes) {
      s.remove(old, rowid);
    }
    return old;
  }

  /// Deletes every row (the truncate optimisation of `DELETE FROM t`).
  int clear() {
    final saved = SplayTreeMap<int, List<Object?>>.of(_rows);
    final n = _rows.length;
    _rows.clear();
    _rebuildAll();
    _log.record(() {
      _rows
        ..clear()
        ..addAll(saved);
      _rebuildAll();
    });
    return n;
  }

  // ---------------------------------------------------------------------------
  // Validation helpers
  // ---------------------------------------------------------------------------

  /// The first NOT NULL column that [values] leaves NULL, or null.
  ColumnDefinition? notNullViolation(List<Object?> values) {
    final cols = _schema.columns;
    for (var i = 0; i < cols.length; i++) {
      if (cols[i].notNull && values[i] == null) return cols[i];
    }
    return null;
  }

  /// The first unique index another row already holds [values]' key in,
  /// with that row's rowid; null when [values] conflicts with no row other
  /// than [except].
  (TableIndex, int)? uniqueConflict(List<Object?> values, {int? except}) {
    for (final i in indexes) {
      if (!i.unique) continue;
      final other = i.conflict(values, except: except);
      if (other != null) return (i, other);
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Schema changes (each records its own undo)
  // ---------------------------------------------------------------------------

  /// Replaces the schema without touching rows or indexes (renames).
  void setSchema(TableSchema schema) {
    final old = _schema;
    _schema = schema;
    _log.record(() => _schema = old);
  }

  /// Appends a column to the schema and [value] to every row.
  void addColumn(ColumnDefinition column, Object? value) {
    final oldSchema = _schema;
    final oldRows = Map<int, List<Object?>>.of(_rows);
    _schema = _schema.copyWith(columns: [..._schema.columns, column]);
    for (final k in oldRows.keys) {
      _rows[k] = [...oldRows[k]!, value];
    }
    _log.record(() {
      _schema = oldSchema;
      _rows.addAll(oldRows);
    });
  }

  /// Removes the column at [position] from the schema and every row.
  /// Indexes must not reference it.
  void dropColumn(int position, TableSchema newSchema) {
    final oldSchema = _schema;
    final oldRows = Map<int, List<Object?>>.of(_rows);
    for (final k in oldRows.keys) {
      _rows[k] = [...oldRows[k]!]..removeAt(position);
    }
    _schema = newSchema;
    void shift(int delta) {
      for (final i in indexes) {
        i.columns = [for (final c in i.columns) c > position ? c + delta : c];
      }
      for (final s in spatialIndexes) {
        if (s.xColumn > position) s.xColumn += delta;
        if (s.yColumn > position) s.yColumn += delta;
      }
    }

    shift(-1);
    _log.record(() {
      _schema = oldSchema;
      shift(1);
      _rows.addAll(oldRows);
    });
  }

  /// Adds [index] and fills it. Returns the rowids of two rows sharing a
  /// key when [index] is unique and the rows are not; the index is then not
  /// added.
  (int, int)? addIndex(TableIndex index) {
    final dup = index.rebuild(_rows.entries);
    if (dup != null) return dup;
    indexes.add(index);
    _log.record(() => indexes.remove(index));
    return null;
  }

  /// Removes [index].
  void dropIndex(TableIndex index) {
    final at = indexes.indexOf(index);
    if (at < 0) return;
    indexes.removeAt(at);
    _log.record(() => indexes.insert(at, index));
  }

  /// Adds [index] and fills it.
  void addSpatialIndex(SpatialIndex index) {
    index.rebuild(_rows.entries);
    spatialIndexes.add(index);
    _log.record(() => spatialIndexes.remove(index));
  }

  /// Removes [index].
  void dropSpatialIndex(SpatialIndex index) {
    final at = spatialIndexes.indexOf(index);
    if (at < 0) return;
    spatialIndexes.removeAt(at);
    _log.record(() => spatialIndexes.insert(at, index));
  }

  /// Renames an index (used by `ALTER TABLE … RENAME TO`).
  void renameIndex(TableIndex index, String name) {
    final old = index.name;
    index.name = name;
    _log.record(() => index.name = old);
  }

  /// Describes every index, for introspection.
  List<IndexInfo> describeIndexes() => [
    for (final i in indexes)
      if (i.origin != IndexOrigin.foreignKey)
        IndexInfo(
          name: i.name,
          table: name,
          columns: [for (final c in i.columns) _schema.columns[c].name],
          unique: i.unique,
          origin: i.origin,
        ),
    for (final s in spatialIndexes)
      IndexInfo(
        name: s.name,
        table: name,
        columns: [
          _schema.columns[s.xColumn].name,
          _schema.columns[s.yColumn].name,
        ],
        unique: false,
        origin: IndexOrigin.spatial,
      ),
  ];

  // ---------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------

  /// Stores a row read from a file, without recording undo. The caller
  /// rebuilds the indexes afterwards with [rebuildIndexes].
  void loadRow(int rowid, List<Object?> values) {
    _rows[rowid] = values;
  }

  /// Refills every index from the rows; returns the name of a unique index
  /// the rows violate, or null.
  String? rebuildIndexes() {
    for (final i in indexes) {
      if (i.rebuild(_rows.entries) != null) return i.name;
    }
    for (final s in spatialIndexes) {
      s.rebuild(_rows.entries);
    }
    return null;
  }

  void _rebuildAll() {
    for (final i in indexes) {
      i.rebuild(_rows.entries);
    }
    for (final s in spatialIndexes) {
      s.rebuild(_rows.entries);
    }
  }

  /// The internal index on [columns] (positions) kept for a foreign key,
  /// or null.
  TableIndex? foreignKeyIndex(List<int> columns) {
    for (final i in indexes) {
      if (i.columns.length != columns.length) continue;
      var same = true;
      for (var k = 0; k < columns.length; k++) {
        if (i.columns[k] != columns[k]) same = false;
      }
      if (same) return i;
    }
    return null;
  }

  /// Adds the internal indexes on foreign key columns that do not have
  /// one yet (after CREATE TABLE, loading, or ADD COLUMN … REFERENCES).
  void ensureForeignKeyIndexes() {
    var n = indexes.where((i) => i.origin == IndexOrigin.foreignKey).length;
    for (final fk in _schema.foreignKeys) {
      final positions = <int>[];
      for (final c in fk.columns) {
        final p = _schema.indexOf(c);
        if (p == null) break;
        positions.add(p);
      }
      if (positions.length != fk.columns.length) continue;
      if (foreignKeyIndex(positions) != null) continue;
      n++;
      final index = TableIndex(
        name: 'sqlite_fkindex_${_schema.name}_$n',
        columns: positions,
        collations: [for (final _ in positions) Collation.binary],
        unique: false,
        origin: IndexOrigin.foreignKey,
      );
      index.rebuild(_rows.entries);
      indexes.add(index);
      _log.record(() => indexes.remove(index));
    }
  }

  /// Creates the indexes that enforce the primary key and UNIQUE
  /// constraints, named `sqlite_autoindex_<table>_<n>` as in SQLite.
  void _constraintIndexes() {
    var n = 0;
    final pk = _schema.primaryKey;
    for (final key in _schema.uniqueKeys) {
      n++;
      final positions = [for (final c in key) _schema.indexOf(c)!];
      final isPk =
          pk.length == key.length &&
          [
                for (var i = 0; i < key.length; i++) key[i].toLowerCase(),
              ].join('\u0000') ==
              [for (final c in pk) c.toLowerCase()].join('\u0000');
      indexes.add(
        TableIndex(
          name: 'sqlite_autoindex_${_schema.name}_$n',
          columns: positions,
          collations: [
            for (final p in positions)
              Collation.parse(_schema.columns[p].collation) ?? Collation.binary,
          ],
          unique: true,
          origin: isPk ? IndexOrigin.primaryKey : IndexOrigin.unique,
        ),
      );
    }
  }
}

import 'package:flutter/foundation.dart' show internal;

import 'rtree.dart';
import 'schema.dart';
import 'values.dart';

/// A hash index over one or more columns of a table.
///
/// Keys are built with [keyOf], so values SQLite treats as equal (1 and
/// 1.0; text equal under the column's collation) share a key. Rows with a
/// NULL in any key column are not indexed: NULL never equals anything, so
/// they can neither conflict in a UNIQUE index nor match an equality
/// lookup.
@internal
final class TableIndex {
  /// Creates an empty index.
  TableIndex({
    required this.name,
    required this.columns,
    required this.collations,
    required this.unique,
    required this.origin,
  }) : assert(columns.length == collations.length);

  /// The index's name.
  String name;

  /// The positions of the indexed columns in the row, in key order.
  List<int> columns;

  /// The collation of each key column.
  final List<Collation> collations;

  /// Whether two rows may not share a key.
  final bool unique;

  /// What created the index.
  final IndexOrigin origin;

  // key → rowid (int) for a single row, or Set<int> for several.
  final Map<Object, Object> _map = {};

  /// Whether this index enforces a constraint (PRIMARY KEY or UNIQUE).
  bool get isConstraint =>
      origin == IndexOrigin.primaryKey || origin == IndexOrigin.unique;

  /// The number of distinct keys.
  int get keyCount => _map.length;

  /// The key of [row], or null when a key column is NULL.
  Object? keyOfRow(List<Object?> row) {
    if (columns.length == 1) {
      final v = row[columns[0]];
      return v == null ? null : keyOf(v, collations[0]);
    }
    final parts = <Object>[];
    for (var i = 0; i < columns.length; i++) {
      final v = row[columns[i]];
      if (v == null) return null;
      parts.add(keyOf(v, collations[i]));
    }
    return CompositeKey(parts);
  }

  /// The key of [values], given in key-column order, or null when one is
  /// NULL.
  Object? keyOfValues(List<Object?> values) {
    if (values.length == 1) {
      final v = values[0];
      return v == null ? null : keyOf(v, collations[0]);
    }
    final parts = <Object>[];
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v == null) return null;
      parts.add(keyOf(v, collations[i]));
    }
    return CompositeKey(parts);
  }

  /// Adds [row] under [rowid].
  void add(List<Object?> row, int rowid) {
    final key = keyOfRow(row);
    if (key == null) return;
    final existing = _map[key];
    if (existing == null) {
      _map[key] = rowid;
    } else if (existing is int) {
      _map[key] = <int>{existing, rowid};
    } else {
      (existing as Set<int>).add(rowid);
    }
  }

  /// Removes [row] stored under [rowid].
  void remove(List<Object?> row, int rowid) {
    final key = keyOfRow(row);
    if (key == null) return;
    final existing = _map[key];
    if (existing == null) return;
    if (existing is int) {
      if (existing == rowid) _map.remove(key);
      return;
    }
    final set = existing as Set<int>;
    set.remove(rowid);
    if (set.length == 1) {
      _map[key] = set.first;
    } else if (set.isEmpty) {
      _map.remove(key);
    }
  }

  /// The rowids stored under [key], in no particular order.
  Iterable<int> lookup(Object key) {
    final e = _map[key];
    if (e == null) return const [];
    if (e is int) return [e];
    return e as Set<int>;
  }

  /// For a unique index: the rowid of another row with the same key as
  /// [row], ignoring [except]; null when there is none.
  int? conflict(List<Object?> row, {int? except}) {
    final key = keyOfRow(row);
    if (key == null) return null;
    for (final r in lookup(key)) {
      if (r != except) return r;
    }
    return null;
  }

  /// Rebuilds the index from [rows]. Returns the first key found twice, as
  /// a pair of rowids, for a unique index; null when the rows are unique.
  (int, int)? rebuild(Iterable<MapEntry<int, List<Object?>>> rows) {
    _map.clear();
    for (final e in rows) {
      if (unique) {
        final other = conflict(e.value);
        if (other != null) return (other, e.key);
      }
      add(e.value, e.key);
    }
    return null;
  }
}

/// An R-tree over points stored in two numeric columns, built by
/// `CREATE SPATIAL INDEX name ON table (x, y)`.
@internal
final class SpatialIndex {
  /// Creates an empty spatial index over the columns at [xColumn] and
  /// [yColumn].
  SpatialIndex({
    required this.name,
    required this.xColumn,
    required this.yColumn,
  });

  /// The index's name.
  String name;

  /// The position of the x (longitude) column.
  int xColumn;

  /// The position of the y (latitude) column.
  int yColumn;

  final RTree<int> _tree = RTree<int>();

  /// The number of indexed points.
  int get size => _tree.size;

  Rect? _pointOf(List<Object?> row) {
    final x = row[xColumn], y = row[yColumn];
    if (x is! num || y is! num) return null;
    final dx = x.toDouble(), dy = y.toDouble();
    if (!dx.isFinite || !dy.isFinite) return null;
    return Rect.point(dx, dy);
  }

  /// Adds [row] under [rowid]; rows without two finite numbers are skipped.
  void add(List<Object?> row, int rowid) {
    final p = _pointOf(row);
    if (p != null) _tree.insert(p, rowid);
  }

  /// Removes [row] stored under [rowid].
  void remove(List<Object?> row, int rowid) {
    final p = _pointOf(row);
    if (p != null) _tree.remove(p, rowid);
  }

  /// The rowids of points inside [area] (borders included).
  List<int> search(Rect area) => _tree.search(area);

  /// Rebuilds the index from [rows].
  void rebuild(Iterable<MapEntry<int, List<Object?>>> rows) {
    _tree.clear();
    for (final e in rows) {
      add(e.value, e.key);
    }
  }
}

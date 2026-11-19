part of 'engine.dart';

/// A compiled expression: reads the current rows from a frame.
typedef _Eval = Object? Function(_Frame f);

/// One row source visible to an expression: a table, a view or subquery,
/// or a trigger's NEW/OLD row.
final class _Source {
  _Source({
    required this.name,
    required this.columns,
    required this.affinities,
    required this.collations,
    required this.declaredTypes,
    this.table,
    this.qualifiedOnly = false,
  });

  /// The source for a table, named by [alias] or its own name.
  factory _Source.table(TableData t, String? alias) => _Source(
    name: alias ?? t.name,
    columns: [for (final c in t.schema.columns) c.name],
    affinities: [for (final c in t.schema.columns) c.affinity],
    collations: [
      for (final c in t.schema.columns)
        Collation.parse(c.collation) ?? Collation.binary,
    ],
    declaredTypes: [for (final c in t.schema.columns) c.type],
    table: t,
  );

  /// The name that qualifies its columns (`name.column`).
  final String? name;
  final List<String> columns;

  /// Each column's affinity; null for a subquery column with none.
  final List<Affinity?> affinities;
  final List<Collation> collations;
  final List<String> declaredTypes;

  /// The table, for a base table (which has a rowid).
  final TableData? table;

  /// NEW and OLD: only reachable as `new.x` / `old.x`.
  final bool qualifiedOnly;

  /// Columns a USING or NATURAL join merged into the left side: hidden
  /// from `*` and from unqualified names.
  final Set<int> merged = {};

  /// The position of [column], or null.
  int? indexOf(String column) {
    final lower = column.toLowerCase();
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].toLowerCase() == lower) return i;
    }
    return null;
  }

  bool matches(String qualifier) =>
      name != null && name!.toLowerCase() == qualifier.toLowerCase();
}

/// The sources an expression can see, and the scope of the query it is
/// nested in.
final class _Scope {
  _Scope(this.sources, this.parent);
  final List<_Source> sources;
  final _Scope? parent;
}

/// The current row of every source of a scope while a query runs.
final class _Frame {
  _Frame(int n, this.parent)
    : rows = List<List<Object?>?>.filled(n, null),
      rowids = List<int?>.filled(n, null);

  /// The current row of each source; null for a NULL-padded outer join row.
  final List<List<Object?>?> rows;

  /// The current rowid of each table source.
  final List<int?> rowids;

  /// The enclosing query's frame, for correlated subqueries and triggers.
  final _Frame? parent;

  /// Aggregate results of the current group.
  List<Object?>? aggs;

  /// The result columns of the current row (for ORDER BY on an alias).
  List<Object?>? outputs;
}

/// Where a column reference points: [depth] scopes out, source [source],
/// column [column] (-1 for the rowid).
final class _Ref {
  _Ref(this.depth, this.source, this.column, this.info);
  final int depth, source, column;
  final _Source info;

  Affinity? get affinity =>
      column < 0 ? Affinity.integer : info.affinities[column];

  Collation get collation =>
      column < 0 ? Collation.binary : info.collations[column];
}

const _rowidNames = {'rowid', 'oid', '_rowid_'};

/// Resolves a column reference in [scope] and its parents. Throws
/// [SqlException] when it matches nothing or is ambiguous.
_Ref _resolve(_Scope scope, String? table, String column) {
  var depth = 0;
  _Scope? s = scope;
  while (s != null) {
    final found = _resolveIn(s, table, column, depth);
    if (found != null) return found;
    s = s.parent;
    depth++;
  }
  final name = table == null ? column : '$table.$column';
  throw SqlException.schema('no such column: $name');
}

_Ref? _resolveIn(_Scope scope, String? table, String column, int depth) {
  final sources = scope.sources;
  if (table != null) {
    for (var i = 0; i < sources.length; i++) {
      final src = sources[i];
      if (!src.matches(table)) continue;
      final c = src.indexOf(column);
      if (c != null) return _Ref(depth, i, c, src);
      if (src.table != null && _rowidNames.contains(column.toLowerCase())) {
        return _Ref(depth, i, -1, src);
      }
      throw SqlException.schema('no such column: $table.$column');
    }
    return null;
  }
  _Ref? hit;
  for (var i = 0; i < sources.length; i++) {
    final src = sources[i];
    if (src.qualifiedOnly) continue;
    final c = src.indexOf(column);
    if (c == null || src.merged.contains(c)) continue;
    if (hit != null) {
      throw SqlException.schema('ambiguous column name: $column');
    }
    hit = _Ref(depth, i, c, src);
  }
  if (hit != null) return hit;
  if (_rowidNames.contains(column.toLowerCase())) {
    _Ref? rowid;
    for (var i = 0; i < sources.length; i++) {
      if (sources[i].table == null || sources[i].qualifiedOnly) continue;
      if (rowid != null) {
        throw SqlException.schema('ambiguous column name: $column');
      }
      rowid = _Ref(depth, i, -1, sources[i]);
    }
    return rowid;
  }
  return null;
}

/// Reads the value [ref] points at.
_Eval _readRef(_Ref ref) {
  final d = ref.depth, s = ref.source, c = ref.column;
  if (d == 0) {
    if (c < 0) return (f) => f.rowids[s];
    return (f) {
      final r = f.rows[s];
      return r == null ? null : r[c];
    };
  }
  return (f) {
    var x = f;
    for (var i = 0; i < d; i++) {
      x = x.parent!;
    }
    if (c < 0) return x.rowids[s];
    final r = x.rows[s];
    return r == null ? null : r[c];
  };
}

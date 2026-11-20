part of 'engine.dart';

/// A compiled SELECT, simple or compound.
final class _SelectPlan {
  _SelectPlan({
    required this.columnNames,
    required this.rawNames,
    required this.affinities,
    required this.collations,
    required this.declaredTypes,
    required this.outerRefs,
    required this.runner,
  });

  /// Result column names, made unique.
  final List<String> columnNames;

  /// Result column names as SQLite gives them (may repeat).
  final List<String> rawNames;

  /// Each result column's affinity (null for none).
  final List<Affinity?> affinities;
  final List<Collation> collations;

  /// The declared type of result columns that are plain table columns.
  final List<String> declaredTypes;

  /// References to enclosing scopes: (depth, source).
  final Set<(int, int)> outerRefs;

  final List<List<Object?>> Function(_Frame?, int?) runner;

  /// Runs the query in [parent]'s context; returns at most [limit] rows.
  List<List<Object?>> run(_Frame? parent, {int? limit}) =>
      runner(parent, limit);

  /// A copy whose columns are named [names].
  _SelectPlan renamed(List<String> names) => _SelectPlan(
    columnNames: names,
    rawNames: names,
    affinities: affinities,
    collations: collations,
    declaredTypes: declaredTypes,
    outerRefs: outerRefs,
    runner: runner,
  );
}

/// One entry of a flattened FROM clause.
final class _FromEntry {
  _FromEntry(this.source, {this.table, this.plan});
  final _Source source;
  final TableData? table;
  final _SelectPlan? plan;
  JoinKind kind = JoinKind.inner;
  Expr? on;
  List<String>? using;
  bool natural = false;
}

/// A WHERE conjunct with what it references.
final class _Conjunct {
  _Conjunct(this.expr, this.compiled, this.sources, this.volatile);
  final Expr expr;
  final _Compiled compiled;
  final Set<int> sources;
  final bool volatile;
}

/// An equality on one column of the first source: `col = v`, `col IS v`
/// or `col IN (…)`; column -1 is the rowid.
final class _Lookup {
  _Lookup(this.column, this.values, this.convert, this.collation);
  final int column;
  final List<_Compiled> values;
  final Object? Function(Object?)? convert;
  final Collation collation;
}

/// A spatial lookup: candidates from an R-tree search of [area], widened
/// by [distance].
final class _SpatialLookup {
  _SpatialLookup(this.index, this.area, this.distance);
  final SpatialIndex index;
  final _Compiled area;
  final _Compiled? distance;
}

/// An equi-join key of a level: a value over earlier sources and the
/// column of this level's source it must equal.
typedef _JoinKey = ({
  _Eval left,
  int column,
  Object? Function(Object?)? convertLeft,
  Object? Function(Object?)? convertRight,
  Collation collation,
});

/// How one level of the join finds and filters its rows.
final class _Level {
  _Level(this.entry);
  final _FromEntry entry;

  /// The ON condition (with USING/NATURAL equalities), or null.
  _Eval? condition;

  /// WHERE conjuncts checked once this level's row is set.
  final List<_Eval> filters = [];

  /// Equi-join keys, for a hash join or index lookup.
  final List<_JoinKey> keys = [];

  /// First level only: a rowid lookup, an index lookup, or a spatial one.
  _Lookup? rowidLookup;
  (TableIndex, List<_Lookup>)? indexLookup;
  _SpatialLookup? spatial;

  bool get isRightOuter =>
      entry.kind == JoinKind.right || entry.kind == JoinKind.full;
  bool get isLeftOuter =>
      entry.kind == JoinKind.left || entry.kind == JoinKind.full;
}

/// The state of one level during one run.
final class _LevelRun {
  List<MapEntry<int, List<Object?>>>? rows;
  Map<Object, List<MapEntry<int, List<Object?>>>>? hash;
  Set<int>? matched;
}

final class _StopScan implements Exception {
  const _StopScan();
}

List<Expr> _conjuncts(Expr? e) {
  if (e == null) return const [];
  if (e is Binary && e.op == 'AND') {
    return [..._conjuncts(e.left), ..._conjuncts(e.right)];
  }
  return [e];
}

/// Makes result names unique: a repeated name gets `:1`, `:2`, ….
List<String> _uniqueNames(List<String> names) {
  final counts = <String, int>{};
  final taken = {for (final n in names) n.toLowerCase()};
  final out = <String>[];
  for (final n in names) {
    final lower = n.toLowerCase();
    final k = counts[lower];
    if (k == null) {
      counts[lower] = 0;
      out.add(n);
      continue;
    }
    var i = k + 1;
    while (taken.contains('$lower:$i')) {
      i++;
    }
    counts[lower] = i;
    taken.add('$lower:$i');
    out.add('$n:$i');
  }
  return out;
}

/// Compares two ORDER BY keys: NULLs first ascending and last descending
/// unless [nullsFirst] says otherwise.
int _orderCompare(
  Object? a,
  Object? b,
  bool desc,
  bool? nullsFirst,
  Collation coll,
) {
  if (a == null || b == null) {
    if (a == null && b == null) return 0;
    final nf = nullsFirst ?? !desc;
    return (a == null) == nf ? -1 : 1;
  }
  final c = compareValues(a, b, coll);
  return desc ? -c : c;
}

int? _limitOf(Object? v) {
  if (v == null) return null;
  if (v is String && parseNumericText(v) == null) {
    throw const SqlException('datatype mismatch in LIMIT');
  }
  final i = castValue(v, 'INTEGER') as int;
  return i < 0 ? null : i;
}

int _offsetOf(Object? v) {
  if (v == null) return 0;
  if (v is String && parseNumericText(v) == null) {
    throw const SqlException('datatype mismatch in OFFSET');
  }
  final i = castValue(v, 'INTEGER') as int;
  return i < 0 ? 0 : i;
}

List<List<Object?>> _window(List<List<Object?>> rows, int offset, int? limit) {
  if (offset == 0 && (limit == null || limit >= rows.length)) return rows;
  final start = math.min(offset, rows.length);
  final end = limit == null
      ? rows.length
      : math.min(rows.length, start + limit);
  return rows.sublist(start, end);
}

String _ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  return switch (n % 10) {
    1 => '${n}st',
    2 => '${n}nd',
    3 => '${n}rd',
    _ => '${n}th',
  };
}

typedef _OrderTerm = ({
  _Eval eval,
  bool desc,
  bool? nullsFirst,
  Collation collation,
});

extension _Select on Engine {
  /// The name SQLite gives a result column with no alias: a column's own
  /// name, otherwise the expression's text.
  String _columnName(Expr e) {
    if (e is ColumnRef) return e.column;
    if (e.start >= 0 && e.end <= _source.length && e.start < e.end) {
      return _source.substring(e.start, e.end);
    }
    return 'expr';
  }

  /// Compiles [stmt] in [parent] (the enclosing query's scope, or null).
  _SelectPlan _compileSelect(SelectStatement stmt, _Scope? parent) {
    if (stmt.cores.length == 1) {
      return _compileCore(
        stmt.cores.single,
        parent,
        stmt.hints,
        orderBy: stmt.orderBy,
        limit: stmt.limit,
        offset: stmt.offset,
      );
    }
    return _compileCompound(stmt, parent);
  }

  _SelectPlan _compileCompound(SelectStatement stmt, _Scope? parent) {
    final plans = [
      for (final c in stmt.cores) _compileCore(c, parent, stmt.hints),
    ];
    final width = plans.first.columnNames.length;
    for (var i = 1; i < plans.length; i++) {
      if (plans[i].columnNames.length != width) {
        final op = switch (stmt.ops[i - 1]) {
          CompoundOp.union => 'UNION',
          CompoundOp.unionAll => 'UNION ALL',
          CompoundOp.intersect => 'INTERSECT',
          CompoundOp.except => 'EXCEPT',
        };
        throw SqlException(
          'SELECTs to the left and right of $op do not have the same number of result columns',
        );
      }
    }
    final first = plans.first;
    final outer = <(int, int)>{for (final p in plans) ...p.outerRefs};
    final collations = first.collations;
    final order = <(int, bool, bool?, Collation)>[];
    for (var t = 0; t < stmt.orderBy.length; t++) {
      final term = stmt.orderBy[t];
      var e = term.expr;
      Collation? coll;
      if (e is Collate) {
        coll = Collation.parse(e.collation);
        if (coll == null) {
          throw SqlException('no such collation sequence: ${e.collation}');
        }
        e = e.expr;
      }
      int? col;
      if (e is Literal && e.value is int) {
        col = (e.value as int) - 1;
        if (col < 0 || col >= width) {
          throw SqlException(
            '${_ordinal(t + 1)} ORDER BY term out of range - should be between 1 and $width',
          );
        }
      } else if (e is ColumnRef && e.table == null) {
        final lower = e.column.toLowerCase();
        for (var i = 0; i < width; i++) {
          if (first.rawNames[i].toLowerCase() == lower) {
            col = i;
            break;
          }
        }
      }
      if (col == null) {
        throw SqlException(
          '${_ordinal(t + 1)} ORDER BY term does not match any column in the result set',
        );
      }
      order.add((
        col,
        term.descending,
        term.nullsFirst,
        coll ?? collations[col],
      ));
    }
    final limitCtx = _Ctx(_Scope(const [], parent));
    final limitC = stmt.limit == null ? null : _compile(stmt.limit!, limitCtx);
    final offsetC = stmt.offset == null
        ? null
        : _compile(stmt.offset!, limitCtx);
    outer.addAll(limitCtx.outer);
    final ops = stmt.ops;
    return _SelectPlan(
      columnNames: first.columnNames,
      rawNames: first.rawNames,
      affinities: first.affinities,
      collations: collations,
      declaredTypes: first.declaredTypes,
      outerRefs: outer,
      runner: (parentFrame, cap) {
        Object rowKey(List<Object?> r) => CompositeKey([
          for (var i = 0; i < r.length; i++) keyOf(r[i], collations[i]),
        ]);
        var result = plans.first.run(parentFrame);
        for (var i = 0; i < ops.length; i++) {
          final right = plans[i + 1].run(parentFrame);
          switch (ops[i]) {
            case CompoundOp.unionAll:
              result = [...result, ...right];
            case CompoundOp.union:
              final seen = <Object>{};
              result = [
                for (final r in [...result, ...right])
                  if (seen.add(rowKey(r))) r,
              ];
            case CompoundOp.intersect:
              final keep = {for (final r in right) rowKey(r)};
              final seen = <Object>{};
              result = [
                for (final r in result)
                  if (keep.contains(rowKey(r)) && seen.add(rowKey(r))) r,
              ];
            case CompoundOp.except:
              final drop = {for (final r in right) rowKey(r)};
              final seen = <Object>{};
              result = [
                for (final r in result)
                  if (!drop.contains(rowKey(r)) && seen.add(rowKey(r))) r,
              ];
          }
        }
        if (order.isNotEmpty) {
          final indexed = [
            for (var i = 0; i < result.length; i++) (i, result[i]),
          ];
          indexed.sort((a, b) {
            for (final (col, desc, nullsFirst, coll) in order) {
              final c = _orderCompare(
                a.$2[col],
                b.$2[col],
                desc,
                nullsFirst,
                coll,
              );
              if (c != 0) return c;
            }
            return a.$1.compareTo(b.$1);
          });
          result = [for (final (_, r) in indexed) r];
        }
        final f = _Frame(0, parentFrame);
        var lim = _limitOf(limitC?.eval(f));
        if (cap != null) lim = lim == null ? cap : math.min(lim, cap);
        return _window(result, _offsetOf(offsetC?.eval(f)), lim);
      },
    );
  }

  _SelectPlan _compileCore(
    SelectCore core,
    _Scope? parent,
    List<QueryHint> hints, {
    List<OrderingTerm> orderBy = const [],
    Expr? limit,
    Expr? offset,
  }) {
    if (core.values != null) {
      return _compileValues(core.values!, parent, orderBy, limit, offset);
    }

    // FROM.
    final entries = <_FromEntry>[];
    if (core.from != null) _flatten(core.from!, parent, entries, first: true);
    final scope = _Scope([for (final e in entries) e.source], parent);
    final outer = <(int, int)>{};
    for (final e in entries) {
      if (e.plan != null) outer.addAll(e.plan!.outerRefs);
    }
    final levels = [for (final e in entries) _Level(e)];
    final hasRightOuter = levels.any((l) => l.isRightOuter);

    // Join conditions.
    for (var i = 1; i < levels.length; i++) {
      final e = entries[i];
      final prefix = _Scope(scope.sources.sublist(0, i + 1), parent);
      final conds = <_Eval>[];
      if (e.natural || e.using != null) {
        final names =
            e.using ??
            [
              for (final c in e.source.columns)
                if (_leftColumn(scope.sources, i, c) != null) c,
            ];
        for (final name in names) {
          final rc = e.source.indexOf(name);
          final left = _leftColumn(scope.sources, i, name);
          if (rc == null || left == null) {
            throw SqlException(
              'cannot join using column $name - column not present in both tables',
            );
          }
          final lRef = _Ref(0, left.$1, left.$2, scope.sources[left.$1]);
          final rRef = _Ref(0, i, rc, e.source);
          final l = _Compiled(
            _readRef(lRef),
            affinity: lRef.affinity,
            collation: lRef.collation,
            ref: lRef,
          );
          final r = _Compiled(
            _readRef(rRef),
            affinity: rRef.affinity,
            collation: rRef.collation,
            ref: rRef,
          );
          final cmp = _comparator(l, r);
          final le = l.eval, re = r.eval;
          conds.add((f) => cmp(le(f), re(f)) == 0 ? 1 : 0);
          _addJoinKey(levels[i], l, r, rc);
          e.source.merged.add(rc);
        }
      }
      for (final c in _conjuncts(e.on)) {
        if (_containsAggregate(c)) {
          throw const SqlException(
            'aggregate functions are not allowed in the ON clause',
          );
        }
        final ctx = _Ctx(prefix);
        conds.add(_compile(c, ctx).eval);
        outer.addAll(ctx.outer);
        if (!ctx.volatile) _maybeJoinKey(levels[i], c, prefix, i);
      }
      if (conds.isNotEmpty) {
        levels[i].condition = conds.length == 1
            ? conds.single
            : (f) {
                for (final c in conds) {
                  if (truthOf(c(f)) != true) return 0;
                }
                return 1;
              };
      }
    }

    // Result columns (their aliases are visible to WHERE).
    final aggregate =
        core.groupBy.isNotEmpty ||
        core.having != null ||
        core.columns.any(
          (c) => c is ExprColumn && _containsAggregate(c.expr),
        ) ||
        orderBy.any((t) => _containsAggregate(t.expr));
    final aliases = <_Alias>[];
    final outputExprs = <Expr?>[];
    final starRefs = <_Ref?>[];
    final rawNames = <String>[];
    for (final rc in core.columns) {
      switch (rc) {
        case StarColumn():
          for (final r in _expandStar(rc.table, scope)) {
            outputExprs.add(null);
            starRefs.add(r);
            rawNames.add(r.info.columns[r.column]);
          }
        case ExprColumn():
          if (rc.alias != null) {
            aliases.add(_Alias(rc.alias!, rc.expr, outputExprs.length));
          }
          outputExprs.add(rc.expr);
          starRefs.add(null);
          rawNames.add(rc.alias ?? _columnName(rc.expr));
      }
    }

    // WHERE.
    final conjuncts = <_Conjunct>[];
    for (final c in _conjuncts(core.where)) {
      if (_containsAggregate(c)) {
        throw const SqlException('misuse of aggregate function in WHERE');
      }
      final ctx = _Ctx(scope, aliases: aliases);
      final compiled = _compile(c, ctx);
      outer.addAll(ctx.outer);
      conjuncts.add(_Conjunct(c, compiled, ctx.sources, ctx.volatile));
    }
    final finalFilters = <_Eval>[];
    for (final c in conjuncts) {
      if (levels.isEmpty || hasRightOuter) {
        finalFilters.add(c.compiled.eval);
        continue;
      }
      final at = c.sources.isEmpty ? 0 : c.sources.reduce(math.max);
      levels[at].filters.add(c.compiled.eval);
      final k = entries[at].kind;
      if (at > 0 &&
          (k == JoinKind.inner || k == JoinKind.cross) &&
          !c.volatile) {
        _maybeJoinKey(levels[at], c.expr, scope, at);
      }
    }
    if (levels.isNotEmpty && !hasRightOuter) {
      _planFirstLevel(levels.first, conjuncts, scope, hints);
    }

    // Outputs.
    final aggs = aggregate ? <_AggSpec>[] : null;
    final outCtx = _Ctx(scope, aggs: aggs, aliases: aliases);
    final outputs = <_Compiled>[];
    final affinities = <Affinity?>[];
    final collations = <Collation>[];
    final declaredTypes = <String>[];
    for (var i = 0; i < outputExprs.length; i++) {
      final e = outputExprs[i];
      _Compiled c;
      if (e == null) {
        final r = starRefs[i]!;
        outCtx.note(r);
        c = _Compiled(
          _readRef(r),
          affinity: r.affinity,
          collation: r.collation,
          ref: r,
        );
      } else {
        c = _compile(e, outCtx);
      }
      outputs.add(c);
      affinities.add(c.affinity);
      collations.add(
        c.explicitCollation || c.ref != null ? c.collation : Collation.binary,
      );
      final ref = c.ref;
      declaredTypes.add(
        ref != null && ref.column >= 0
            ? ref.info.declaredTypes[ref.column]
            : '',
      );
    }
    outer.addAll(outCtx.outer);

    // GROUP BY and HAVING.
    final groupBy = <(_Eval, Collation)>[];
    for (final g in core.groupBy) {
      var ge = g;
      if (g is Literal && g.value is int) {
        final k = (g.value as int) - 1;
        if (k < 0 || k >= outputExprs.length || outputExprs[k] == null) {
          throw SqlException(
            'GROUP BY term out of range - should be between 1 and ${outputExprs.length}',
          );
        }
        ge = outputExprs[k]!;
      }
      if (_containsAggregate(ge)) {
        throw const SqlException(
          'aggregate functions are not allowed in the GROUP BY clause',
        );
      }
      final ctx = _Ctx(scope, aliases: aliases);
      final c = _compile(ge, ctx);
      outer.addAll(ctx.outer);
      groupBy.add((
        c.eval,
        c.explicitCollation || c.ref != null ? c.collation : Collation.binary,
      ));
    }
    _Eval? having;
    if (core.having != null) {
      final ctx = _Ctx(scope, aggs: aggs, aliases: aliases);
      having = _compile(core.having!, ctx).eval;
      outer.addAll(ctx.outer);
    }

    // ORDER BY: a position or an output alias reads the output; anything
    // else is computed from the source rows.
    final orderTerms = <_OrderTerm>[];
    for (var t = 0; t < orderBy.length; t++) {
      final term = orderBy[t];
      var e = term.expr;
      Collation? explicit;
      if (e is Collate) {
        explicit = Collation.parse(e.collation);
        if (explicit == null) {
          throw SqlException('no such collation sequence: ${e.collation}');
        }
        e = e.expr;
      }
      int? outIndex;
      if (e is Literal && e.value is int) {
        outIndex = (e.value as int) - 1;
        if (outIndex < 0 || outIndex >= outputs.length) {
          throw SqlException(
            '${_ordinal(t + 1)} ORDER BY term out of range - should be between 1 and ${outputs.length}',
          );
        }
      } else if (e is ColumnRef && e.table == null) {
        final name = e.column.toLowerCase();
        for (final a in aliases) {
          if (a.name.toLowerCase() == name) {
            outIndex = a.index;
            break;
          }
        }
      }
      if (outIndex != null) {
        final k = outIndex;
        orderTerms.add((
          eval: (f) => f.outputs![k],
          desc: term.descending,
          nullsFirst: term.nullsFirst,
          collation: explicit ?? collations[k],
        ));
        continue;
      }
      final ctx = _Ctx(scope, aggs: aggs, aliases: aliases);
      final c = _compile(e, ctx);
      outer.addAll(ctx.outer);
      orderTerms.add((
        eval: c.eval,
        desc: term.descending,
        nullsFirst: term.nullsFirst,
        collation:
            explicit ??
            (c.explicitCollation || c.ref != null
                ? c.collation
                : Collation.binary),
      ));
    }

    // LIMIT and OFFSET.
    final limitCtx = _Ctx(_Scope(const [], parent));
    final limitC = limit == null ? null : _compile(limit, limitCtx).eval;
    final offsetC = offset == null ? null : _compile(offset, limitCtx).eval;
    outer.addAll(limitCtx.outer);

    final names = _uniqueNames(rawNames);
    final n = entries.length;
    final distinct = core.distinct;
    final outEvals = [for (final o in outputs) o.eval];
    final specs = aggs ?? const <_AggSpec>[];
    final singleMinMax =
        specs.length == 1 && (specs[0].name == 'MIN' || specs[0].name == 'MAX');

    return _SelectPlan(
      columnNames: names,
      rawNames: rawNames,
      affinities: affinities,
      collations: collations,
      declaredTypes: declaredTypes,
      outerRefs: outer,
      runner: (parentFrame, cap) {
        final f = _Frame(n, parentFrame);
        final pf = _Frame(0, parentFrame);
        var lim = limitC == null ? null : _limitOf(limitC(pf));
        if (cap != null) lim = lim == null ? cap : math.min(lim, cap);
        final off = offsetC == null ? 0 : _offsetOf(offsetC(pf));
        if (lim == 0) return const [];
        final stopAfter = (orderTerms.isEmpty && !aggregate && lim != null)
            ? lim + off
            : null;
        final collected = <(List<Object?>, List<Object?>)>[];
        final seen = <Object>{};

        void addRow() {
          final out = List<Object?>.filled(outEvals.length, null);
          for (var i = 0; i < outEvals.length; i++) {
            out[i] = outEvals[i](f);
          }
          if (distinct) {
            final key = CompositeKey([
              for (var i = 0; i < out.length; i++) keyOf(out[i], collations[i]),
            ]);
            if (!seen.add(key)) return;
          }
          f.outputs = out;
          final keys = orderTerms.isEmpty
              ? const <Object?>[]
              : [for (final t in orderTerms) t.eval(f)];
          collected.add((out, keys));
          if (stopAfter != null && collected.length >= stopAfter) {
            throw const _StopScan();
          }
        }

        final groups = <Object, (List<_Accumulator>, List<Object?>)>{};
        const single = Object();
        void accumulate() {
          final key = groupBy.isEmpty
              ? single
              : (groupBy.length == 1
                    ? keyOf(groupBy.single.$1(f), groupBy.single.$2)
                    : CompositeKey([
                        for (final (g, coll) in groupBy) keyOf(g(f), coll),
                      ]));
          var g = groups[key];
          if (g == null) {
            g = ([for (final s in specs) _newAccumulator(s)], <Object?>[null]);
            groups[key] = g;
          }
          var took = false;
          for (var k = 0; k < specs.length; k++) {
            final spec = specs[k];
            final args = List<Object?>.filled(spec.args.length, null);
            for (var j = 0; j < args.length; j++) {
              args[j] = spec.args[j].eval(f);
            }
            if (g.$1[k].step(args)) took = true;
          }
          // Bare columns read the group's last row, or the row holding the
          // single MIN/MAX, as in SQLite.
          if (!singleMinMax || took || g.$2[0] == null) {
            g.$2[0] = (
              List<List<Object?>?>.of(f.rows),
              List<int?>.of(f.rowids),
            );
          }
        }

        final emit = aggregate ? accumulate : addRow;
        final runs = [
          for (final l in levels)
            _LevelRun()..matched = l.isRightOuter ? <int>{} : null,
        ];
        try {
          if (n == 0) {
            if (_passesAll(finalFilters, f)) emit();
          } else {
            _scan(levels, runs, 0, f, emit, finalFilters);
            _emitUnmatchedRight(levels, runs, f, emit, finalFilters);
          }
        } on _StopScan {
          // Enough rows for the LIMIT.
        }

        if (aggregate) {
          if (groups.isEmpty && groupBy.isEmpty) {
            groups[single] = (
              [for (final s in specs) _newAccumulator(s)],
              <Object?>[null],
            );
          }
          try {
            for (final g in groups.values) {
              final snap = g.$2[0] as (List<List<Object?>?>, List<int?>)?;
              for (var i = 0; i < n; i++) {
                f.rows[i] = snap?.$1[i];
                f.rowids[i] = snap?.$2[i];
              }
              f.aggs = [for (final a in g.$1) a.result];
              if (having != null && truthOf(having(f)) != true) continue;
              addRow();
            }
          } on _StopScan {
            // Enough rows for the LIMIT.
          }
        }

        var rows = [for (final r in collected) r.$1];
        if (orderTerms.isNotEmpty) {
          final indexed = [
            for (var i = 0; i < collected.length; i++) (i, collected[i]),
          ];
          indexed.sort((a, b) {
            for (var t = 0; t < orderTerms.length; t++) {
              final term = orderTerms[t];
              final c = _orderCompare(
                a.$2.$2[t],
                b.$2.$2[t],
                term.desc,
                term.nullsFirst,
                term.collation,
              );
              if (c != 0) return c;
            }
            return a.$1.compareTo(b.$1);
          });
          rows = [for (final (_, r) in indexed) r.$1];
        }
        return _window(rows, off, lim);
      },
    );
  }

  _SelectPlan _compileValues(
    List<List<Expr>> rows,
    _Scope? parent,
    List<OrderingTerm> orderBy,
    Expr? limit,
    Expr? offset,
  ) {
    final ctx = _Ctx(_Scope(const [], parent));
    final compiled = [
      for (final r in rows) [for (final e in r) _compile(e, ctx).eval],
    ];
    final width = rows.first.length;
    final names = [for (var i = 1; i <= width; i++) 'column$i'];
    final order = <(int, bool, bool?)>[];
    for (var t = 0; t < orderBy.length; t++) {
      final e = orderBy[t].expr;
      int? col;
      if (e is Literal && e.value is int) col = (e.value as int) - 1;
      if (e is ColumnRef && e.table == null) {
        final name = e.column.toLowerCase();
        final i = names.indexWhere((x) => x == name);
        if (i >= 0) col = i;
      }
      if (col == null || col < 0 || col >= width) {
        throw SqlException(
          '${_ordinal(t + 1)} ORDER BY term does not match any column in the result set',
        );
      }
      order.add((col, orderBy[t].descending, orderBy[t].nullsFirst));
    }
    final limitC = limit == null ? null : _compile(limit, ctx).eval;
    final offsetC = offset == null ? null : _compile(offset, ctx).eval;
    return _SelectPlan(
      columnNames: names,
      rawNames: names,
      affinities: List.filled(width, null),
      collations: List.filled(width, Collation.binary),
      declaredTypes: List.filled(width, ''),
      outerRefs: ctx.outer,
      runner: (parentFrame, cap) {
        final f = _Frame(0, parentFrame);
        var result = [
          for (final r in compiled) [for (final e in r) e(f)],
        ];
        if (order.isNotEmpty) {
          final indexed = [
            for (var i = 0; i < result.length; i++) (i, result[i]),
          ];
          indexed.sort((a, b) {
            for (final (col, desc, nf) in order) {
              final c = _orderCompare(
                a.$2[col],
                b.$2[col],
                desc,
                nf,
                Collation.binary,
              );
              if (c != 0) return c;
            }
            return a.$1.compareTo(b.$1);
          });
          result = [for (final (_, r) in indexed) r];
        }
        var lim = limitC == null ? null : _limitOf(limitC(f));
        if (cap != null) lim = lim == null ? cap : math.min(lim, cap);
        return _window(
          result,
          offsetC == null ? 0 : _offsetOf(offsetC(f)),
          lim,
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // FROM
  // ---------------------------------------------------------------------------

  void _flatten(
    FromItem item,
    _Scope? parent,
    List<_FromEntry> out, {
    bool first = false,
    JoinKind kind = JoinKind.inner,
    Expr? on,
    List<String>? using,
    bool natural = false,
  }) {
    void setJoin(_FromEntry e) {
      e
        ..kind = kind
        ..on = on
        ..using = using
        ..natural = natural;
      out.add(e);
    }

    switch (item) {
      case TableSource():
        setJoin(_tableEntry(item.name, item.alias));
      case SubquerySource():
        final plan = _compileSelect(item.query, parent);
        setJoin(
          _FromEntry(
            _Source(
              name: item.alias,
              columns: plan.columnNames,
              affinities: plan.affinities,
              collations: plan.collations,
              declaredTypes: plan.declaredTypes,
            ),
            plan: plan,
          ),
        );
      case JoinSource():
        if (!first &&
            (on != null ||
                using != null ||
                natural ||
                kind != JoinKind.inner)) {
          throw const SqlException(
            'a parenthesised join is only supported as a plain inner join',
          );
        }
        _flatten(
          item.left,
          parent,
          out,
          first: first,
          kind: kind,
          on: on,
          using: using,
          natural: natural,
        );
        _flatten(
          item.right,
          parent,
          out,
          kind: item.kind,
          on: item.on,
          using: item.using,
          natural: item.natural,
        );
    }
  }

  _FromEntry _tableEntry(String name, String? alias) {
    final t = catalog.table(name);
    if (t != null) return _FromEntry(_Source.table(t, alias), table: t);
    final v = catalog.view(name);
    if (v != null) {
      final plan = _viewPlan(v);
      return _FromEntry(
        _Source(
          name: alias ?? v.name,
          columns: plan.columnNames,
          affinities: plan.affinities,
          collations: plan.collations,
          declaredTypes: plan.declaredTypes,
        ),
        plan: plan,
      );
    }
    throw SqlException.schema('no such table: $name');
  }

  (int, int)? _leftColumn(List<_Source> sources, int i, String name) {
    for (var s = 0; s < i; s++) {
      final c = sources[s].indexOf(name);
      if (c != null && !sources[s].merged.contains(c)) return (s, c);
    }
    return null;
  }

  List<_Ref> _expandStar(String? table, _Scope scope) {
    if (scope.sources.isEmpty) throw const SqlException('no tables specified');
    final out = <_Ref>[];
    for (var s = 0; s < scope.sources.length; s++) {
      final src = scope.sources[s];
      if (src.qualifiedOnly) continue;
      if (table != null && !src.matches(table)) continue;
      for (var c = 0; c < src.columns.length; c++) {
        if (table == null && src.merged.contains(c)) continue;
        out.add(_Ref(0, s, c, src));
      }
      if (table != null) return out;
    }
    if (table != null) throw SqlException.schema('no such table: $table');
    return out;
  }

  /// A view's compiled query, named by its column list.
  _SelectPlan _viewPlan(ViewDefinition v) {
    final key = v.name.toLowerCase();
    final cached = _viewPlans[key];
    if (cached != null) return cached;
    if (!_viewsBeingCompiled.add(key)) {
      throw SqlException('view ${v.name} is circularly defined');
    }
    try {
      final parsed = Parser.parseOne(v.sql);
      final stmt = parsed.statement as CreateViewStatement;
      var plan = _withSource(
        parsed.source,
        () => _compileSelect(stmt.query, null),
      );
      final cols = stmt.columns;
      if (cols != null) {
        if (cols.length != plan.columnNames.length) {
          throw SqlException(
            "expected ${cols.length} columns for '${v.name}' but got ${plan.columnNames.length}",
          );
        }
        plan = plan.renamed(cols);
      }
      _viewPlans[key] = plan;
      return plan;
    } finally {
      _viewsBeingCompiled.remove(key);
    }
  }

  // ---------------------------------------------------------------------------
  // Access paths
  // ---------------------------------------------------------------------------

  void _addJoinKey(_Level level, _Compiled left, _Compiled right, int column) {
    final (cl, cr) = _comparisonConverters(left.affinity, right.affinity);
    level.keys.add((
      left: left.eval,
      column: column,
      convertLeft: cl,
      convertRight: cr,
      collation: _comparisonCollation(left, right),
    ));
  }

  /// Records `this.col = <earlier sources>` (either way round) as an
  /// equi-join key of [level], the level of source [i].
  void _maybeJoinKey(_Level level, Expr c, _Scope scope, int i) {
    if (c is! Binary || c.op != '=') return;
    for (final (a, b) in [(c.left, c.right), (c.right, c.left)]) {
      if (a is! ColumnRef) continue;
      _Ref ref;
      try {
        ref = _resolve(scope, a.table, a.column);
      } on SqlException {
        continue;
      }
      if (ref.depth != 0 || ref.source != i || ref.column < 0) continue;
      final ctx = _Ctx(scope);
      _Compiled other;
      try {
        other = _compile(b, ctx);
      } on SqlException {
        continue;
      }
      if (ctx.volatile || ctx.sources.any((s) => s >= i)) continue;
      final right = _Compiled(
        _readRef(ref),
        affinity: ref.affinity,
        collation: ref.collation,
        ref: ref,
      );
      _addJoinKey(level, other, right, ref.column);
      return;
    }
  }

  /// Picks a rowid, index or spatial lookup for the first source from the
  /// WHERE conjuncts that reference only it.
  void _planFirstLevel(
    _Level level,
    List<_Conjunct> conjuncts,
    _Scope scope,
    List<QueryHint> hints,
  ) {
    final table = level.entry.table;
    if (table == null) return;
    final src = level.entry.source;
    bool applies(QueryHint h) =>
        h.table == null ||
        src.matches(h.table!) ||
        h.table!.toLowerCase() == table.name.toLowerCase();
    if (hints.any(
      (h) =>
          (h.kind == HintKind.fullScan || h.kind == HintKind.noIndex) &&
          applies(h),
    )) {
      return;
    }
    final forced = {
      for (final h in hints)
        if (h.kind == HintKind.forceIndex && h.index != null && applies(h))
          h.index!.toLowerCase(),
    };
    final lookups = <_Lookup>[];
    final spatial = <_SpatialLookup>[];
    for (final c in conjuncts) {
      if (c.volatile || c.sources.any((s) => s != 0)) continue;
      final l = _lookupOf(c.expr, scope);
      if (l != null) lookups.add(l);
      final sp = _spatialOf(c.expr, scope, table);
      if (sp != null) spatial.add(sp);
    }
    for (final l in lookups) {
      if (l.column == -1) {
        level.rowidLookup = l;
        return;
      }
    }
    TableIndex? best;
    List<_Lookup>? bestParts;
    for (final idx in table.indexes) {
      final parts = <_Lookup>[];
      for (var k = 0; k < idx.columns.length; k++) {
        final match = lookups.where(
          (l) => l.column == idx.columns[k] && l.collation == idx.collations[k],
        );
        if (match.isEmpty) break;
        parts.add(match.first);
      }
      if (parts.length != idx.columns.length) continue;
      if (parts.where((p) => p.values.length > 1).length > 1) continue;
      final isForced = forced.contains(idx.name.toLowerCase());
      final bestForced =
          best != null && forced.contains(best.name.toLowerCase());
      final better =
          best == null ||
          (isForced && !bestForced) ||
          (!bestForced &&
              ((idx.unique && !best.unique) ||
                  (idx.unique == best.unique &&
                      idx.columns.length > best.columns.length)));
      if (better) {
        best = idx;
        bestParts = parts;
      }
    }
    if (best != null) {
      level.indexLookup = (best, bestParts!);
      return;
    }
    if (spatial.isNotEmpty) level.spatial = spatial.first;
  }

  /// `col = v`, `col IS v` or `col IN (…)` on source 0, with `v` free of
  /// this query's sources.
  _Lookup? _lookupOf(Expr e, _Scope scope) {
    Expr? colSide;
    List<Expr>? values;
    if (e is Binary && (e.op == '=' || e.op == 'IS')) {
      if (_lookupColumn(e.left, scope) != null) {
        colSide = e.left;
        values = [e.right];
      } else if (_lookupColumn(e.right, scope) != null) {
        colSide = e.right;
        values = [e.left];
      }
    } else if (e is InList && !e.not && e.items.isNotEmpty) {
      colSide = e.expr;
      values = e.items;
    }
    if (colSide == null || values == null) return null;
    final ref = _lookupColumn(colSide, scope);
    if (ref == null) return null;
    final ctx = _Ctx(scope);
    final compiled = <_Compiled>[];
    try {
      for (final v in values) {
        compiled.add(_compile(v, ctx));
      }
    } on SqlException {
      return null;
    }
    if (ctx.sources.isNotEmpty || ctx.volatile) return null;
    final explicit = colSide is Collate
        ? Collation.parse(colSide.collation)
        : null;
    final col = _Compiled(
      _readRef(ref),
      affinity: ref.affinity,
      collation: explicit ?? ref.collation,
      explicitCollation: explicit != null,
      ref: ref,
    );
    Object? Function(Object?)? convert;
    Collation? coll;
    for (final v in compiled) {
      final (cl, cr) = _comparisonConverters(col.affinity, v.affinity);
      if (cl != null) return null;
      if (convert != null && cr != null && !identical(convert, cr)) {
        // Different conversions per item: fine as long as one applies.
      }
      convert ??= cr;
      final c = _comparisonCollation(col, v);
      if (coll != null && coll != c) return null;
      coll = c;
    }
    return _Lookup(ref.column, compiled, convert, coll ?? Collation.binary);
  }

  _Ref? _lookupColumn(Expr e, _Scope scope) {
    final c = e is Collate ? e.expr : e;
    if (c is! ColumnRef) return null;
    try {
      final ref = _resolve(scope, c.table, c.column);
      return ref.depth == 0 && ref.source == 0 ? ref : null;
    } on SqlException {
      return null;
    }
  }

  /// `ST_WITHIN(ST_MAKEPOINT(x, y), area)`, `ST_INTERSECTS(…)` either way
  /// round, `ST_CONTAINS(area, ST_MAKEPOINT(x, y))` or
  /// `ST_DWITHIN(ST_MAKEPOINT(x, y), g, d)` over a spatially indexed pair
  /// of columns of the first source.
  _SpatialLookup? _spatialOf(Expr e, _Scope scope, TableData table) {
    if (table.spatialIndexes.isEmpty || e is! FunctionCall) return null;
    Expr? point, area, distance;
    final args = e.args;
    switch (e.name) {
      case 'ST_WITHIN':
        if (args.length == 2 && _isPointCall(args[0])) {
          point = args[0];
          area = args[1];
        }
      case 'ST_INTERSECTS':
        if (args.length == 2 && _isPointCall(args[0])) {
          point = args[0];
          area = args[1];
        } else if (args.length == 2 && _isPointCall(args[1])) {
          point = args[1];
          area = args[0];
        }
      case 'ST_CONTAINS':
        if (args.length == 2 && _isPointCall(args[1])) {
          point = args[1];
          area = args[0];
        }
      case 'ST_DWITHIN':
        if (args.length == 3 && _isPointCall(args[0])) {
          point = args[0];
          area = args[1];
          distance = args[2];
        }
    }
    if (point == null || area == null) return null;
    final p = point as FunctionCall;
    final xr = _lookupColumn(p.args[0], scope);
    final yr = _lookupColumn(p.args[1], scope);
    if (xr == null || yr == null) return null;
    SpatialIndex? index;
    for (final s in table.spatialIndexes) {
      if (s.xColumn == xr.column && s.yColumn == yr.column) index = s;
    }
    if (index == null) return null;
    final ctx = _Ctx(scope);
    try {
      final a = _compile(area, ctx);
      final d = distance == null ? null : _compile(distance, ctx);
      if (ctx.sources.isNotEmpty || ctx.volatile) return null;
      return _SpatialLookup(index, a, d);
    } on SqlException {
      return null;
    }
  }

  bool _isPointCall(Expr e) =>
      e is FunctionCall &&
      (e.name == 'ST_MAKEPOINT' || e.name == 'ST_POINT') &&
      e.args.length == 2;

  /// The candidate rows of the first level, or null for a full scan.
  List<MapEntry<int, List<Object?>>>? _firstLevelRows(_Level level, _Frame f) {
    final table = level.entry.table;
    if (table == null) return null;
    final rowid = level.rowidLookup;
    if (rowid != null) {
      final ids = <int>{};
      for (final v in rowid.values) {
        final x = applyAffinity(v.eval(f), Affinity.numeric);
        if (x is int) ids.add(x);
      }
      return _rowsFor(table, ids);
    }
    final indexLookup = level.indexLookup;
    if (indexLookup != null) {
      final (index, parts) = indexLookup;
      final choices = [
        for (final p in parts)
          [
            for (final v in p.values)
              if (v.eval(f) case final x?)
                p.convert == null ? x : p.convert!(x),
          ],
      ];
      final ids = <int>{};
      void probe(int k, List<Object?> acc) {
        if (k == parts.length) {
          final key = index.keyOfValues(acc);
          if (key != null) ids.addAll(index.lookup(key));
          return;
        }
        for (final v in choices[k]) {
          probe(k + 1, [...acc, v]);
        }
      }

      probe(0, const []);
      return _rowsFor(table, ids);
    }
    final sp = level.spatial;
    if (sp != null) {
      final g = _geometry(sp.area.eval(f));
      if (g == null) return const [];
      var b = g.bounds;
      if (sp.distance != null) {
        final d = _coordinate(sp.distance!.eval(f));
        if (d == null || d < 0) return const [];
        b = Rect(b.minX - d, b.minY - d, b.maxX + d, b.maxY + d);
      }
      return _rowsFor(table, sp.index.search(b));
    }
    return null;
  }

  List<MapEntry<int, List<Object?>>> _rowsFor(TableData t, Iterable<int> ids) {
    final sorted = ids.toSet().toList()..sort();
    return [
      for (final id in sorted)
        if (t.row(id) case final r?) MapEntry(id, r),
    ];
  }

  // ---------------------------------------------------------------------------
  // Scanning
  // ---------------------------------------------------------------------------

  bool _passesAll(List<_Eval> filters, _Frame f) {
    for (final filter in filters) {
      if (truthOf(filter(f)) != true) return false;
    }
    return true;
  }

  /// Runs the nested loops from level [i], calling [emit] for each
  /// complete row that passes [finals].
  void _scan(
    List<_Level> levels,
    List<_LevelRun> runs,
    int i,
    _Frame f,
    void Function() emit,
    List<_Eval> finals,
  ) {
    if (i == levels.length) {
      if (_passesAll(finals, f)) emit();
      return;
    }
    final level = levels[i];
    final run = runs[i];
    final rows = _levelRows(level, run, i, f);
    var matched = false;
    for (final r in rows) {
      f.rows[i] = r.value;
      f.rowids[i] = r.key < 0 ? null : r.key;
      final cond = level.condition;
      if (cond != null && truthOf(cond(f)) != true) continue;
      matched = true;
      run.matched?.add(r.key);
      if (_passesAll(level.filters, f)) {
        _scan(levels, runs, i + 1, f, emit, finals);
      }
    }
    if (!matched && level.isLeftOuter) {
      f.rows[i] = null;
      f.rowids[i] = null;
      if (_passesAll(level.filters, f)) {
        _scan(levels, runs, i + 1, f, emit, finals);
      }
    }
    f.rows[i] = null;
    f.rowids[i] = null;
  }

  /// The rows level [i] goes through for the current earlier rows.
  Iterable<MapEntry<int, List<Object?>>> _levelRows(
    _Level level,
    _LevelRun run,
    int i,
    _Frame f,
  ) {
    if (i == 0) {
      final picked = _firstLevelRows(level, f);
      if (picked != null) return picked;
    }
    final all = run.rows ??= _allRows(level.entry, f);
    if (i == 0 || level.keys.isEmpty || level.isRightOuter) return all;
    final hash = run.hash ??= _hashRows(level, all);
    final parts = <Object>[];
    for (final k in level.keys) {
      var v = k.left(f);
      if (v == null) return const [];
      if (k.convertLeft != null) v = k.convertLeft!(v);
      parts.add(keyOf(v, k.collation));
    }
    return hash[parts.length == 1 ? parts.single : CompositeKey(parts)] ??
        const [];
  }

  Map<Object, List<MapEntry<int, List<Object?>>>> _hashRows(
    _Level level,
    List<MapEntry<int, List<Object?>>> all,
  ) {
    final h = <Object, List<MapEntry<int, List<Object?>>>>{};
    rows:
    for (final r in all) {
      final parts = <Object>[];
      for (final k in level.keys) {
        var v = r.value[k.column];
        if (v == null) continue rows;
        if (k.convertRight != null) v = k.convertRight!(v);
        parts.add(keyOf(v, k.collation));
      }
      (h[parts.length == 1 ? parts.single : CompositeKey(parts)] ??= []).add(r);
    }
    return h;
  }

  List<MapEntry<int, List<Object?>>> _allRows(_FromEntry e, _Frame f) {
    if (e.table != null) return e.table!.entries.toList(growable: false);
    var k = -1;
    return [for (final r in e.plan!.run(f.parent)) MapEntry(k--, r)];
  }

  /// Emits the rows of RIGHT and FULL joins that matched nothing, with the
  /// earlier sources NULL.
  void _emitUnmatchedRight(
    List<_Level> levels,
    List<_LevelRun> runs,
    _Frame f,
    void Function() emit,
    List<_Eval> finals,
  ) {
    for (var i = 0; i < levels.length; i++) {
      final matched = runs[i].matched;
      if (matched == null) continue;
      final all = runs[i].rows ??= _allRows(levels[i].entry, f);
      for (final r in all) {
        if (matched.contains(r.key)) continue;
        for (var j = 0; j < i; j++) {
          f.rows[j] = null;
          f.rowids[j] = null;
        }
        f.rows[i] = r.value;
        f.rowids[i] = r.key < 0 ? null : r.key;
        if (_passesAll(levels[i].filters, f)) {
          _scan(levels, runs, i + 1, f, emit, finals);
        }
      }
      f.rows[i] = null;
      f.rowids[i] = null;
    }
  }
}

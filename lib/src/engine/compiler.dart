part of 'engine.dart';

/// A compiled expression and what is known about it.
final class _Compiled {
  _Compiled(
    this.eval, {
    this.affinity,
    this.collation = Collation.binary,
    this.explicitCollation = false,
    this.ref,
    this.isConstant = false,
  });

  final _Eval eval;

  /// The expression's affinity: a column's, a CAST's, or null for none.
  final Affinity? affinity;
  final Collation collation;

  /// Whether [collation] came from a COLLATE operator.
  final bool explicitCollation;

  /// Set when the expression is a plain column reference.
  final _Ref? ref;

  /// Whether the value is fixed for one execution (no columns, no
  /// subqueries, no random()).
  final bool isConstant;
}

/// An aggregate call found while compiling an aggregate query.
final class _AggSpec {
  _AggSpec(this.name, this.args, this.distinct, this.collation);
  final String name;
  final List<_Compiled> args;
  final bool distinct;
  final Collation collation;
}

/// An output column alias visible to WHERE, GROUP BY, HAVING and ORDER BY.
final class _Alias {
  _Alias(this.name, this.expr, this.index);
  final String name;
  final Expr expr;
  final int index;
}

/// The context an expression is compiled in.
final class _Ctx {
  _Ctx(
    this.scope, {
    this.aggs,
    this.aliases = const [],
    this.inAggregateArg = false,
  });

  final _Scope scope;

  /// Where aggregate calls are collected; null where they are not allowed.
  final List<_AggSpec>? aggs;

  /// Output aliases a bare name may fall back to.
  final List<_Alias> aliases;

  /// Inside an aggregate's argument (where another aggregate is misuse).
  final bool inAggregateArg;

  /// Sources of this scope that were referenced.
  final Set<int> sources = {};

  /// References to enclosing scopes: (depth, source).
  final Set<(int, int)> outer = {};

  /// Whether a non-deterministic function was used.
  bool volatile = false;

  final Set<String> _expanding = {};

  void note(_Ref ref) {
    if (ref.depth == 0) {
      sources.add(ref.source);
    } else {
      outer.add((ref.depth, ref.source));
    }
  }

  /// Records the outer references of a nested plan compiled in this
  /// context.
  void absorb(Set<(int, int)> nestedOuter) {
    for (final (d, s) in nestedOuter) {
      if (d == 1) {
        sources.add(s);
      } else {
        outer.add((d - 1, s));
      }
    }
  }

  _Alias? alias(String name) {
    final lower = name.toLowerCase();
    for (final a in aliases) {
      if (a.name.toLowerCase() == lower) return a;
    }
    return null;
  }

  _Ctx argContext() =>
      _Ctx(scope, aliases: aliases, inAggregateArg: true).._link(this);

  _Ctx? _parent;
  void _link(_Ctx parent) => _parent = parent;

  /// Pushes this context's findings into the one it was derived from.
  void flush() {
    final p = _parent;
    if (p == null) return;
    p.sources.addAll(sources);
    p.outer.addAll(outer);
    if (volatile) p.volatile = true;
  }
}

const _aggregateNames = {
  'COUNT',
  'SUM',
  'TOTAL',
  'AVG',
  'GROUP_CONCAT',
  'STRING_AGG',
};

/// Whether [e] calls an aggregate function.
bool _isAggregateCall(FunctionCall e) =>
    _aggregateNames.contains(e.name) ||
    ((e.name == 'MIN' || e.name == 'MAX') && e.args.length == 1);

/// Whether [e] contains an aggregate call outside any subquery.
bool _containsAggregate(Expr e) {
  switch (e) {
    case FunctionCall():
      if (_isAggregateCall(e)) return true;
      return e.args.any(_containsAggregate);
    case Unary():
      return _containsAggregate(e.operand);
    case Binary():
      return _containsAggregate(e.left) || _containsAggregate(e.right);
    case Collate():
      return _containsAggregate(e.expr);
    case Like():
      return _containsAggregate(e.left) ||
          _containsAggregate(e.pattern) ||
          (e.escape != null && _containsAggregate(e.escape!));
    case Between():
      return _containsAggregate(e.expr) ||
          _containsAggregate(e.low) ||
          _containsAggregate(e.high);
    case InList():
      return _containsAggregate(e.expr) || e.items.any(_containsAggregate);
    case InSelect():
      return _containsAggregate(e.expr);
    case Case():
      return (e.base != null && _containsAggregate(e.base!)) ||
          e.whens.any(
            (w) => _containsAggregate(w.$1) || _containsAggregate(w.$2),
          ) ||
          (e.otherwise != null && _containsAggregate(e.otherwise!));
    case Cast():
      return _containsAggregate(e.expr);
    case RowValue():
      return e.items.any(_containsAggregate);
    default:
      return false;
  }
}

const bool _isWeb = identical(0, 0.0);
const int _minInt = minInt64;

Object? _negate(Object? v) {
  if (v == null) return null;
  final n = v is num ? v : toNumber(v);
  if (n is int) return n == _minInt ? -(n.toDouble()) : -n;
  return -n;
}

Object _addInt(int a, int b) {
  final r = a + b;
  if (!_isWeb && ((a ^ r) & (b ^ r)) < 0) return a.toDouble() + b.toDouble();
  return r;
}

Object _subInt(int a, int b) {
  final r = a - b;
  if (!_isWeb && ((a ^ b) & (a ^ r)) < 0) return a.toDouble() - b.toDouble();
  return r;
}

Object _mulInt(int a, int b) {
  if (_isWeb || a == 0 || b == 0) return a * b;
  final r = a * b;
  if ((a == -1 && b == _minInt) || (b == -1 && a == _minInt) || r ~/ b != a) {
    return a.toDouble() * b.toDouble();
  }
  return r;
}

int _toI64(double d) {
  if (d.isNaN) return 0;
  if (d >= 9223372036854775807.0) return maxInt64;
  if (d <= -9223372036854775808.0) return _minInt;
  return d.truncate();
}

/// `a op b` for `+ - * / %`, with SQLite's NULL, text and overflow rules.
Object? _arithmetic(String op, Object? a, Object? b) {
  if (a == null || b == null) return null;
  final x = a is num ? a : toNumber(a);
  final y = b is num ? b : toNumber(b);
  if (x is int && y is int) {
    switch (op) {
      case '+':
        return _addInt(x, y);
      case '-':
        return _subInt(x, y);
      case '*':
        return _mulInt(x, y);
      case '/':
        if (y == 0) return null;
        if (x == _minInt && y == -1) return -(x.toDouble());
        return x ~/ y;
      default:
        if (y == 0) return null;
        if (y == -1) return 0;
        return x.remainder(y);
    }
  }
  final dx = x.toDouble(), dy = y.toDouble();
  double r;
  switch (op) {
    case '+':
      r = dx + dy;
    case '-':
      r = dx - dy;
    case '*':
      r = dx * dy;
    case '/':
      if (dy == 0.0) return null;
      r = dx / dy;
    default:
      final ix = _toI64(dx), iy = _toI64(dy);
      if (iy == 0) return null;
      r = (iy == -1 ? 0 : ix.remainder(iy)).toDouble();
  }
  return r.isNaN ? null : r;
}

int? _asInteger(Object? v) => v == null ? null : castValue(v, 'INTEGER') as int;

Object? _bitwise(String op, Object? a, Object? b) {
  final x = _asInteger(a), y = _asInteger(b);
  if (x == null || y == null) return null;
  switch (op) {
    case '&':
      return x & y;
    case '|':
      return x | y;
    case '<<':
      return _shift(x, y);
    default:
      return _shift(x, y == _minInt ? 64 : -y);
  }
}

int _shift(int x, int by) {
  if (by >= 64) return 0;
  if (by <= -64) return x < 0 ? -1 : 0;
  if (by >= 0) return x << by;
  return x >> -by;
}

/// Kleene AND over SQL truth values (null, true, false).
bool? _and3(bool? a, bool? b) {
  if (a == false || b == false) return false;
  if (a == null || b == null) return null;
  return true;
}

/// How a comparison converts its operands (SQLite section 4.2): numeric
/// affinity wins over text/blob/none; text affinity wins over none.
(Object? Function(Object?)?, Object? Function(Object?)?) _comparisonConverters(
  Affinity? l,
  Affinity? r,
) {
  Object? numeric(Object? v) => applyAffinity(v, Affinity.numeric);
  Object? text(Object? v) => applyAffinity(v, Affinity.text);
  final ln = l?.isNumeric ?? false, rn = r?.isNumeric ?? false;
  if (ln && !rn) return (null, numeric);
  if (rn && !ln) return (numeric, null);
  if (l == Affinity.text && r == null) return (null, text);
  if (r == Affinity.text && l == null) return (text, null);
  return (null, null);
}

/// The collation a comparison uses: an explicit COLLATE (left first), else
/// a column's (left first), else BINARY.
Collation _comparisonCollation(_Compiled l, _Compiled r) {
  if (l.explicitCollation) return l.collation;
  if (r.explicitCollation) return r.collation;
  if (l.ref != null) return l.collation;
  if (r.ref != null) return r.collation;
  return Collation.binary;
}

/// A three-way comparison of two expressions with conversions and
/// collation applied; returns null when either side is NULL.
typedef _Comparator = int? Function(Object? a, Object? b);

_Comparator _comparator(_Compiled l, _Compiled r) {
  final (cl, cr) = _comparisonConverters(l.affinity, r.affinity);
  final coll = _comparisonCollation(l, r);
  return (a, b) {
    if (a == null || b == null) return null;
    final x = cl == null ? a : cl(a);
    final y = cr == null ? b : cr(b);
    return compareValues(x, y, coll);
  };
}

extension _Compile on Engine {
  _Compiled _compile(Expr e, _Ctx ctx) {
    switch (e) {
      case Literal():
        final v = e.value;
        return _Compiled((_) => v, isConstant: true);
      case CurrentTime():
        final k = e.keyword;
        return _Compiled((_) => _currentTime(k), isConstant: true);
      case Param():
        final i = e.index - 1;
        return _Compiled((_) => _params[i], isConstant: true);
      case ColumnRef():
        return _columnRef(e, ctx);
      case Unary():
        return _unary(e, ctx);
      case Binary():
        return _binary(e, ctx);
      case Collate():
        final inner = _compile(e.expr, ctx);
        final c = Collation.parse(e.collation);
        if (c == null) {
          throw SqlException('no such collation sequence: ${e.collation}');
        }
        return _Compiled(
          inner.eval,
          affinity: inner.affinity,
          collation: c,
          explicitCollation: true,
          ref: inner.ref,
          isConstant: inner.isConstant,
        );
      case Like():
        return _like(e, ctx);
      case Between():
        return _between(e, ctx);
      case InList():
        return _inList(e, ctx);
      case InSelect():
        return _inSelect(e, ctx);
      case Exists():
        return _exists(e, ctx);
      case ScalarSubquery():
        return _scalarSubquery(e, ctx);
      case Case():
        return _case(e, ctx);
      case Cast():
        final inner = _compile(e.expr, ctx);
        final type = e.type;
        final ev = inner.eval;
        return _Compiled(
          (f) => castValue(ev(f), type),
          affinity: Affinity.of(type),
          collation: inner.collation,
          explicitCollation: inner.explicitCollation,
          isConstant: inner.isConstant,
        );
      case FunctionCall():
        return _function(e, ctx);
      case Raise():
        final kind = e.kind, message = e.message;
        return _Compiled((_) => throw _Raise(kind, message));
      case RowValue():
        throw const SqlException('row value misused');
    }
  }

  _Compiled _columnRef(ColumnRef e, _Ctx ctx) {
    _Ref ref;
    try {
      ref = _resolve(ctx.scope, e.table, e.column);
    } on SqlException {
      // An output alias, as SQLite allows in WHERE, GROUP BY and HAVING.
      final alias = e.table == null ? ctx.alias(e.column) : null;
      if (alias == null) rethrow;
      final key = alias.name.toLowerCase();
      if (!ctx._expanding.add(key)) rethrow;
      try {
        return _compile(alias.expr, ctx);
      } finally {
        ctx._expanding.remove(key);
      }
    }
    ctx.note(ref);
    return _Compiled(
      _readRef(ref),
      affinity: ref.affinity,
      collation: ref.collation,
      ref: ref,
    );
  }

  _Compiled _unary(Unary e, _Ctx ctx) {
    final x = _compile(e.operand, ctx);
    final ev = x.eval;
    switch (e.op) {
      case '-':
        return _Compiled((f) => _negate(ev(f)), isConstant: x.isConstant);
      case '+':
        // Unary + drops the column's affinity and index, as in SQLite.
        return _Compiled(
          ev,
          collation: x.collation,
          explicitCollation: x.explicitCollation,
          isConstant: x.isConstant,
        );
      case '~':
        return _Compiled((f) {
          final v = _asInteger(ev(f));
          return v == null ? null : ~v;
        }, isConstant: x.isConstant);
      default: // NOT
        return _Compiled((f) {
          final t = truthOf(ev(f));
          return t == null ? null : (t ? 0 : 1);
        }, isConstant: x.isConstant);
    }
  }

  _Compiled _binary(Binary e, _Ctx ctx) {
    final op = e.op;
    if (op == 'AND' || op == 'OR') {
      final l = _compile(e.left, ctx), r = _compile(e.right, ctx);
      final le = l.eval, re = r.eval;
      final constant = l.isConstant && r.isConstant;
      if (op == 'AND') {
        return _Compiled((f) {
          final a = truthOf(le(f));
          if (a == false) return 0;
          final b = truthOf(re(f));
          if (b == false) return 0;
          if (a == null || b == null) return null;
          return 1;
        }, isConstant: constant);
      }
      return _Compiled((f) {
        final a = truthOf(le(f));
        if (a == true) return 1;
        final b = truthOf(re(f));
        if (b == true) return 1;
        if (a == null || b == null) return null;
        return 0;
      }, isConstant: constant);
    }
    final l = _compile(e.left, ctx), r = _compile(e.right, ctx);
    final le = l.eval, re = r.eval;
    final constant = l.isConstant && r.isConstant;
    switch (op) {
      case '=':
      case '!=':
      case '<':
      case '<=':
      case '>':
      case '>=':
        final cmp = _comparator(l, r);
        final bool Function(int) test = switch (op) {
          '=' => (c) => c == 0,
          '!=' => (c) => c != 0,
          '<' => (c) => c < 0,
          '<=' => (c) => c <= 0,
          '>' => (c) => c > 0,
          _ => (c) => c >= 0,
        };
        return _Compiled((f) {
          final c = cmp(le(f), re(f));
          return c == null ? null : (test(c) ? 1 : 0);
        }, isConstant: constant);
      case 'IS':
      case 'IS NOT':
        final cmp = _comparator(l, r);
        final want = op == 'IS';
        return _Compiled((f) {
          final a = le(f), b = re(f);
          final eq = (a == null || b == null)
              ? (a == null && b == null)
              : cmp(a, b) == 0;
          return eq == want ? 1 : 0;
        }, isConstant: constant);
      case '||':
        return _Compiled((f) {
          final a = le(f);
          if (a == null) return null;
          final b = re(f);
          if (b == null) return null;
          return textOf(a) + textOf(b);
        }, isConstant: constant);
      case '+':
      case '-':
      case '*':
      case '/':
      case '%':
        return _Compiled(
          (f) => _arithmetic(op, le(f), re(f)),
          isConstant: constant,
        );
      default: // & | << >>
        return _Compiled(
          (f) => _bitwise(op, le(f), re(f)),
          isConstant: constant,
        );
    }
  }

  _Compiled _like(Like e, _Ctx ctx) {
    final l = _compile(e.left, ctx);
    final p = _compile(e.pattern, ctx);
    final esc = e.escape == null ? null : _compile(e.escape!, ctx);
    final glob = e.op == 'GLOB';
    final not = e.not;
    final le = l.eval, pe = p.eval, ee = esc?.eval;
    String? lastPattern;
    int? lastEscape;
    bool Function(String)? matcher;
    return _Compiled((f) {
      final a = le(f), pat = pe(f);
      if (a == null || pat == null) return null;
      int? escChar;
      if (ee != null) {
        final ev = ee(f);
        if (ev == null) return null;
        final s = textOf(ev);
        if (s.runes.length != 1) {
          throw const SqlException(
            'ESCAPE expression must be a single character',
          );
        }
        escChar = s.runes.first;
      }
      final ps = textOf(pat);
      if (matcher == null || ps != lastPattern || escChar != lastEscape) {
        matcher = glob ? _globMatcher(ps) : _likeMatcher(ps, escChar);
        lastPattern = ps;
        lastEscape = escChar;
      }
      final m = matcher!(textOf(a));
      return m != not ? 1 : 0;
    }, isConstant: l.isConstant && p.isConstant && (esc?.isConstant ?? true));
  }

  _Compiled _between(Between e, _Ctx ctx) {
    final x = _compile(e.expr, ctx);
    final lo = _compile(e.low, ctx), hi = _compile(e.high, ctx);
    final cLo = _comparator(x, lo), cHi = _comparator(x, hi);
    final xe = x.eval, le = lo.eval, he = hi.eval;
    final not = e.not;
    return _Compiled((f) {
      final v = xe(f);
      final a = cLo(v, le(f));
      final b = cHi(v, he(f));
      final r = _and3(a == null ? null : a >= 0, b == null ? null : b <= 0);
      if (r == null) return null;
      return (r != not) ? 1 : 0;
    }, isConstant: x.isConstant && lo.isConstant && hi.isConstant);
  }

  _Compiled _inList(InList e, _Ctx ctx) {
    final x = _compile(e.expr, ctx);
    final items = [for (final i in e.items) _compile(i, ctx)];
    final not = e.not;
    final xe = x.eval;
    if (items.isEmpty) {
      return _Compiled((_) => not ? 1 : 0, isConstant: true);
    }
    final allConstant = items.every((i) => i.isConstant);
    if (allConstant) {
      // One hashed set per execution.
      final (cl, cr) = _comparisonConverters(x.affinity, null);
      final coll = x.explicitCollation || x.ref != null
          ? x.collation
          : Collation.binary;
      var builtFor = -1;
      Set<Object> keys = {};
      var hasNull = false;
      return _Compiled((f) {
        if (builtFor != _execId) {
          keys = {};
          hasNull = false;
          for (final i in items) {
            final v = i.eval(f);
            if (v == null) {
              hasNull = true;
            } else {
              keys.add(keyOf(cr == null ? v : cr(v), coll));
            }
          }
          builtFor = _execId;
        }
        final v = xe(f);
        if (v == null) return null;
        if (keys.contains(keyOf(cl == null ? v : cl(v), coll))) {
          return not ? 0 : 1;
        }
        if (hasNull) return null;
        return not ? 1 : 0;
      }, isConstant: x.isConstant);
    }
    final cmps = [for (final i in items) _comparator(x, i)];
    return _Compiled((f) {
      final v = xe(f);
      if (v == null) return null;
      var sawNull = false;
      for (var k = 0; k < items.length; k++) {
        final c = cmps[k](v, items[k].eval(f));
        if (c == null) {
          sawNull = true;
        } else if (c == 0) {
          return not ? 0 : 1;
        }
      }
      if (sawNull) return null;
      return not ? 1 : 0;
    });
  }

  _Compiled _inSelect(InSelect e, _Ctx ctx) {
    final x = _compile(e.expr, ctx);
    final plan = _compileSelect(e.query, ctx.scope);
    ctx.absorb(plan.outerRefs);
    if (plan.columnNames.length != 1) {
      throw SqlException(
        'sub-select returns ${plan.columnNames.length} columns - expected 1',
      );
    }
    final (cl, cr) = _comparisonConverters(x.affinity, plan.affinities[0]);
    final coll = x.explicitCollation || x.ref != null
        ? x.collation
        : plan.collations[0];
    final not = e.not;
    final xe = x.eval;
    var builtFor = -1;
    Set<Object> keys = {};
    var hasNull = false;
    var empty = true;
    final correlated = plan.outerRefs.isNotEmpty;
    return _Compiled((f) {
      if (correlated || builtFor != _execId) {
        keys = {};
        hasNull = false;
        final rows = plan.run(f);
        empty = rows.isEmpty;
        for (final r in rows) {
          final v = r[0];
          if (v == null) {
            hasNull = true;
          } else {
            keys.add(keyOf(cr == null ? v : cr(v), coll));
          }
        }
        builtFor = _execId;
      }
      if (empty) return not ? 1 : 0;
      final v = xe(f);
      if (v == null) return null;
      if (keys.contains(keyOf(cl == null ? v : cl(v), coll))) {
        return not ? 0 : 1;
      }
      if (hasNull) return null;
      return not ? 1 : 0;
    });
  }

  _Compiled _exists(Exists e, _Ctx ctx) {
    final plan = _compileSelect(e.query, ctx.scope);
    ctx.absorb(plan.outerRefs);
    final not = e.not;
    final correlated = plan.outerRefs.isNotEmpty;
    var builtFor = -1;
    var cached = false;
    return _Compiled((f) {
      if (correlated || builtFor != _execId) {
        cached = plan.run(f, limit: 1).isNotEmpty;
        builtFor = _execId;
      }
      return cached != not ? 1 : 0;
    });
  }

  _Compiled _scalarSubquery(ScalarSubquery e, _Ctx ctx) {
    final plan = _compileSelect(e.query, ctx.scope);
    ctx.absorb(plan.outerRefs);
    if (plan.columnNames.length != 1) {
      throw SqlException(
        'sub-select returns ${plan.columnNames.length} columns - expected 1',
      );
    }
    final correlated = plan.outerRefs.isNotEmpty;
    var builtFor = -1;
    Object? cached;
    return _Compiled((f) {
      if (correlated || builtFor != _execId) {
        final rows = plan.run(f, limit: 1);
        cached = rows.isEmpty ? null : rows.first[0];
        builtFor = _execId;
      }
      return cached;
    }, affinity: plan.affinities[0]);
  }

  _Compiled _case(Case e, _Ctx ctx) {
    final base = e.base == null ? null : _compile(e.base!, ctx);
    final whens = [
      for (final (w, t) in e.whens) (_compile(w, ctx), _compile(t, ctx)),
    ];
    final otherwise = e.otherwise == null ? null : _compile(e.otherwise!, ctx);
    final oe = otherwise?.eval;
    final constant =
        (base?.isConstant ?? true) &&
        whens.every((w) => w.$1.isConstant && w.$2.isConstant) &&
        (otherwise?.isConstant ?? true);
    if (base != null) {
      final be = base.eval;
      final cmps = [for (final (w, _) in whens) _comparator(base, w)];
      return _Compiled((f) {
        final b = be(f);
        if (b != null) {
          for (var i = 0; i < whens.length; i++) {
            if (cmps[i](b, whens[i].$1.eval(f)) == 0) {
              return whens[i].$2.eval(f);
            }
          }
        }
        return oe?.call(f);
      }, isConstant: constant);
    }
    return _Compiled((f) {
      for (final (w, t) in whens) {
        if (truthOf(w.eval(f)) == true) return t.eval(f);
      }
      return oe?.call(f);
    }, isConstant: constant);
  }

  _Compiled _function(FunctionCall e, _Ctx ctx) {
    final name = e.name;
    if (_isAggregateCall(e)) return _aggregate(e, ctx);
    if (e.distinct) {
      throw SqlException(
        'DISTINCT is only allowed in aggregate functions ($name)',
      );
    }
    if (e.star) {
      throw SqlException('wrong number of arguments to function $name()');
    }
    final args = [for (final a in e.args) _compile(a, ctx)];
    final evals = [for (final a in args) a.eval];
    final allConstant = args.every((a) => a.isConstant);
    switch (name) {
      case 'COALESCE':
      case 'IFNULL':
        if (args.length < 2 || (name == 'IFNULL' && args.length != 2)) {
          throw SqlException(
            'wrong number of arguments to function ${name.toLowerCase()}()',
          );
        }
        return _Compiled((f) {
          for (final ev in evals) {
            final v = ev(f);
            if (v != null) return v;
          }
          return null;
        }, isConstant: allConstant);
      case 'IIF':
        if (args.length != 3) {
          throw const SqlException(
            'wrong number of arguments to function iif()',
          );
        }
        return _Compiled(
          (f) => truthOf(evals[0](f)) == true ? evals[1](f) : evals[2](f),
          isConstant: allConstant,
        );
    }
    final def = _scalarFunctions[name];
    if (def == null) throw SqlException('no such function: $name');
    if (args.length < def.minArgs ||
        (def.maxArgs >= 0 && args.length > def.maxArgs)) {
      throw SqlException(
        'wrong number of arguments to function ${name.toLowerCase()}()',
      );
    }
    if (!def.deterministic) ctx.volatile = true;
    final impl = def.impl;
    final n = evals.length;
    return _Compiled((f) {
      final values = List<Object?>.filled(n, null);
      for (var i = 0; i < n; i++) {
        values[i] = evals[i](f);
      }
      return impl(this, values);
    }, isConstant: allConstant && def.deterministic);
  }

  _Compiled _aggregate(FunctionCall e, _Ctx ctx) {
    final name = e.name;
    final aggs = ctx.aggs;
    if (aggs == null || ctx.inAggregateArg) {
      throw SqlException(
        'misuse of aggregate function ${name.toLowerCase()}()',
      );
    }
    final argCtx = ctx.argContext();
    final args = [for (final a in e.args) _compile(a, argCtx)];
    argCtx.flush();
    switch (name) {
      case 'COUNT':
        if (args.length > 1) {
          throw const SqlException(
            'wrong number of arguments to function count()',
          );
        }
      case 'GROUP_CONCAT':
        if (args.isEmpty || args.length > 2) {
          throw const SqlException(
            'wrong number of arguments to function group_concat()',
          );
        }
      case 'STRING_AGG':
        if (args.length != 2) {
          throw const SqlException(
            'wrong number of arguments to function string_agg()',
          );
        }
      default:
        if (args.length != 1) {
          throw SqlException(
            'wrong number of arguments to function ${name.toLowerCase()}()',
          );
        }
    }
    if (e.star && name != 'COUNT') {
      throw SqlException(
        'wrong number of arguments to function ${name.toLowerCase()}()',
      );
    }
    if (e.distinct && args.length != 1) {
      throw SqlException('DISTINCT aggregates must have exactly one argument');
    }
    final coll = args.isEmpty
        ? Collation.binary
        : (args[0].explicitCollation || args[0].ref != null
              ? args[0].collation
              : Collation.binary);
    final k = aggs.length;
    aggs.add(_AggSpec(name, args, e.distinct, coll));
    return _Compiled((f) => f.aggs![k]);
  }

  String _currentTime(String keyword) {
    final iso = _now.toIso8601String();
    final date = iso.substring(0, 10);
    final time = iso.substring(11, 19);
    return switch (keyword) {
      'CURRENT_DATE' => date,
      'CURRENT_TIME' => time,
      _ => '$date $time',
    };
  }
}

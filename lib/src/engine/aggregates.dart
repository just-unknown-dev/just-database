part of 'engine.dart';

/// The running state of one aggregate call for one group.
abstract class _Accumulator {
  /// Feeds one row's argument values. Returns true when MIN/MAX took a new
  /// extreme (so bare columns follow that row, as in SQLite).
  bool step(List<Object?> args);

  /// The aggregate's value.
  Object? get result;
}

_Accumulator _newAccumulator(_AggSpec spec) {
  final acc = switch (spec.name) {
    'COUNT' => spec.args.isEmpty ? _CountStar() : _Count(),
    'SUM' => _Sum(total: false),
    'TOTAL' => _Sum(total: true),
    'AVG' => _Avg(),
    'MIN' => _MinMax(max: false, collation: spec.collation),
    'MAX' => _MinMax(max: true, collation: spec.collation),
    'STRING_AGG' => _GroupConcat(),
    _ => _GroupConcat(),
  };
  return spec.distinct ? _Distinct(acc, spec.collation) : acc;
}

final class _CountStar extends _Accumulator {
  int n = 0;
  @override
  bool step(List<Object?> args) {
    n++;
    return false;
  }

  @override
  Object? get result => n;
}

final class _Count extends _Accumulator {
  int n = 0;
  @override
  bool step(List<Object?> args) {
    if (args[0] != null) n++;
    return false;
  }

  @override
  Object? get result => n;
}

final class _Sum extends _Accumulator {
  _Sum({required this.total});
  final bool total;
  int intSum = 0;
  double realSum = 0;
  bool isReal = false;
  bool any = false;

  @override
  bool step(List<Object?> args) {
    final v = args[0];
    if (v == null) return false;
    any = true;
    if (v is int && !isReal) {
      final r = _addInt(intSum, v);
      if (r is double) {
        if (!total) throw const SqlException('integer overflow');
        isReal = true;
        realSum = r;
      } else {
        intSum = r as int;
      }
      return false;
    }
    if (!isReal) {
      isReal = true;
      realSum = intSum.toDouble();
    }
    realSum += v is num ? v.toDouble() : toNumber(v).toDouble();
    return false;
  }

  @override
  Object? get result {
    if (total) return isReal ? realSum : intSum.toDouble();
    if (!any) return null;
    return isReal ? realSum : intSum;
  }
}

final class _Avg extends _Accumulator {
  double sum = 0;
  int n = 0;

  @override
  bool step(List<Object?> args) {
    final v = args[0];
    if (v == null) return false;
    sum += v is num ? v.toDouble() : toNumber(v).toDouble();
    n++;
    return false;
  }

  @override
  Object? get result => n == 0 ? null : sum / n;
}

final class _MinMax extends _Accumulator {
  _MinMax({required this.max, required this.collation});
  final bool max;
  final Collation collation;
  Object? best;

  @override
  bool step(List<Object?> args) {
    final v = args[0];
    if (v == null) return false;
    if (best == null) {
      best = v;
      return true;
    }
    final c = compareValues(v, best, collation);
    if (max ? c > 0 : c < 0) {
      best = v;
      return true;
    }
    return false;
  }

  @override
  Object? get result => best;
}

final class _GroupConcat extends _Accumulator {
  final StringBuffer buffer = StringBuffer();
  bool any = false;

  @override
  bool step(List<Object?> args) {
    final v = args[0];
    if (v == null) return false;
    if (any) {
      final sep = args.length > 1 ? args[1] : ',';
      if (sep != null) buffer.write(textOf(sep));
    }
    buffer.write(textOf(v));
    any = true;
    return false;
  }

  @override
  Object? get result => any ? buffer.toString() : null;
}

/// Wraps an accumulator so that each distinct non-NULL value counts once.
final class _Distinct extends _Accumulator {
  _Distinct(this.inner, this.collation);
  final _Accumulator inner;
  final Collation collation;
  final Set<Object> seen = {};

  @override
  bool step(List<Object?> args) {
    final v = args[0];
    if (v == null) return false;
    if (!seen.add(keyOf(v, collation))) return false;
    return inner.step(args);
  }

  @override
  Object? get result => inner.result;
}

part of 'engine.dart';

/// A scalar SQL function.
final class _FunctionDef {
  const _FunctionDef(
    this.minArgs,
    this.maxArgs,
    this.impl, {
    this.deterministic = true,
  });

  final int minArgs;

  /// The most arguments; -1 for any number.
  final int maxArgs;
  final Object? Function(Engine engine, List<Object?> args) impl;
  final bool deterministic;
}

final _random = math.Random.secure();

/// The built-in scalar functions, by upper-case name.
final Map<String, _FunctionDef> _scalarFunctions = {
  'ABS': _FunctionDef(1, 1, (_, a) => _abs(a[0])),
  'CHANGES': _FunctionDef(0, 0, (e, _) => e.lastChanges, deterministic: false),
  'CHAR': _FunctionDef(0, -1, (_, a) {
    final b = StringBuffer();
    for (final v in a) {
      final c = v == null ? 0 : (castValue(v, 'INTEGER') as int);
      if (c >= 0 && c <= 0x10FFFF) b.writeCharCode(c);
    }
    return b.toString();
  }),
  'CONCAT': _FunctionDef(1, -1, (_, a) {
    final b = StringBuffer();
    for (final v in a) {
      if (v != null) b.write(textOf(v));
    }
    return b.toString();
  }),
  'CONCAT_WS': _FunctionDef(2, -1, (_, a) {
    if (a[0] == null) return null;
    final sep = textOf(a[0]!);
    return [
      for (final v in a.skip(1))
        if (v != null) textOf(v),
    ].join(sep);
  }),
  'GLOB': _FunctionDef(2, 2, (_, a) {
    if (a[0] == null || a[1] == null) return null;
    return _globMatcher(textOf(a[0]!))(textOf(a[1]!)) ? 1 : 0;
  }),
  'HEX': _FunctionDef(1, 1, (_, a) {
    final v = a[0];
    if (v == null) return '';
    if (v is Uint8List) return hexOf(v);
    return hexOf(Uint8List.fromList(utf8.encode(textOf(v))));
  }),
  'INSTR': _FunctionDef(2, 2, (_, a) {
    final x = a[0], y = a[1];
    if (x == null || y == null) return null;
    if (x is Uint8List && y is Uint8List) {
      outer:
      for (var i = 0; i + y.length <= x.length; i++) {
        for (var j = 0; j < y.length; j++) {
          if (x[i + j] != y[j]) continue outer;
        }
        return i + 1;
      }
      return 0;
    }
    final hay = textOf(x), needle = textOf(y);
    final at = hay.indexOf(needle);
    if (at < 0) return 0;
    return hay.substring(0, at).runes.length + 1;
  }),
  'LAST_INSERT_ROWID': _FunctionDef(
    0,
    0,
    (e, _) => e.lastInsertRowId,
    deterministic: false,
  ),
  'LENGTH': _FunctionDef(1, 1, (_, a) {
    final v = a[0];
    if (v == null) return null;
    if (v is Uint8List) return v.length;
    if (v is String) return v.runes.length;
    return textOf(v).length;
  }),
  'OCTET_LENGTH': _FunctionDef(1, 1, (_, a) {
    final v = a[0];
    if (v == null) return null;
    if (v is Uint8List) return v.length;
    return utf8.encode(textOf(v)).length;
  }),
  'LIKE': _FunctionDef(2, 3, (_, a) {
    if (a[0] == null || a[1] == null) return null;
    int? esc;
    if (a.length == 3) {
      if (a[2] == null) return null;
      final s = textOf(a[2]!);
      if (s.runes.length != 1) {
        throw const SqlException(
          'ESCAPE expression must be a single character',
        );
      }
      esc = s.runes.first;
    }
    return _likeMatcher(textOf(a[0]!), esc)(textOf(a[1]!)) ? 1 : 0;
  }),
  'LIKELY': _FunctionDef(1, 1, (_, a) => a[0]),
  'UNLIKELY': _FunctionDef(1, 1, (_, a) => a[0]),
  'LIKELIHOOD': _FunctionDef(2, 2, (_, a) => a[0]),
  'LOWER': _FunctionDef(1, 1, (_, a) {
    final v = a[0];
    return v == null ? null : asciiLower(textOf(v));
  }),
  'UPPER': _FunctionDef(1, 1, (_, a) {
    final v = a[0];
    return v == null ? null : _asciiUpper(textOf(v));
  }),
  'LTRIM': _FunctionDef(1, 2, (_, a) => _trim(a, left: true, right: false)),
  'RTRIM': _FunctionDef(1, 2, (_, a) => _trim(a, left: false, right: true)),
  'TRIM': _FunctionDef(1, 2, (_, a) => _trim(a, left: true, right: true)),
  'MAX': _FunctionDef(2, -1, (_, a) => _extreme(a, max: true)),
  'MIN': _FunctionDef(2, -1, (_, a) => _extreme(a, max: false)),
  'NULLIF': _FunctionDef(2, 2, (_, a) {
    final x = a[0], y = a[1];
    if (x != null && y != null && compareValues(x, y) == 0) return null;
    return x;
  }),
  'PRINTF': _FunctionDef(1, -1, (_, a) => _printf(a)),
  'FORMAT': _FunctionDef(1, -1, (_, a) => _printf(a)),
  'QUOTE': _FunctionDef(1, 1, (_, a) => sqlLiteral(a[0])),
  'RANDOM': _FunctionDef(0, 0, (_, _) {
    final hi = _random.nextInt(1 << 32), lo = _random.nextInt(1 << 32);
    return _isWeb ? (hi - (1 << 31)) * 4294967296 + lo : (hi << 32) | lo;
  }, deterministic: false),
  'RANDOMBLOB': _FunctionDef(1, 1, (_, a) {
    var n = a[0] == null ? 1 : (castValue(a[0], 'INTEGER') as int);
    if (n < 1) n = 1;
    return Uint8List.fromList([
      for (var i = 0; i < n; i++) _random.nextInt(256),
    ]);
  }, deterministic: false),
  'REPLACE': _FunctionDef(3, 3, (_, a) {
    if (a[0] == null || a[1] == null || a[2] == null) return null;
    final s = textOf(a[0]!), find = textOf(a[1]!);
    if (find.isEmpty) return s;
    return s.replaceAll(find, textOf(a[2]!));
  }),
  'ROUND': _FunctionDef(1, 2, (_, a) => _round(a)),
  'SIGN': _FunctionDef(1, 1, (_, a) {
    final v = a[0];
    if (v == null) return null;
    final n = v is num ? v : (v is String ? parseNumericText(v) : null);
    if (n == null) return null;
    return n > 0 ? 1 : (n < 0 ? -1 : 0);
  }),
  'SUBSTR': _FunctionDef(2, 3, (_, a) => _substr(a)),
  'SUBSTRING': _FunctionDef(2, 3, (_, a) => _substr(a)),
  'TOTAL_CHANGES': _FunctionDef(
    0,
    0,
    (e, _) => e.totalChanges,
    deterministic: false,
  ),
  'TYPEOF': _FunctionDef(1, 1, (_, a) => typeOf(a[0])),
  'UNHEX': _FunctionDef(1, 2, (_, a) {
    final v = a[0];
    if (v == null) return null;
    var s = textOf(v);
    if (a.length == 2 && a[1] != null) {
      final ignore = textOf(a[1]!).runes.toSet();
      s = String.fromCharCodes(s.runes.where((r) => !ignore.contains(r)));
    }
    if (s.length.isOdd || !RegExp(r'^[0-9A-Fa-f]*$').hasMatch(s)) return null;
    return Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16),
    ]);
  }),
  'UNICODE': _FunctionDef(1, 1, (_, a) {
    final v = a[0];
    if (v == null) return null;
    final s = textOf(v);
    return s.isEmpty ? null : s.runes.first;
  }),
  'ZEROBLOB': _FunctionDef(1, 1, (_, a) {
    final n = a[0] == null ? 0 : (castValue(a[0], 'INTEGER') as int);
    return Uint8List(n < 0 ? 0 : n);
  }),
  // Math.
  'ACOS': _math1(math.acos),
  'ASIN': _math1(math.asin),
  'ATAN': _math1(math.atan),
  'ATAN2': _FunctionDef(2, 2, (_, a) {
    if (a[0] == null || a[1] == null) return null;
    return _finite(
      math.atan2(toNumber(a[0]!).toDouble(), toNumber(a[1]!).toDouble()),
    );
  }),
  'CEIL': _FunctionDef(
    1,
    1,
    (_, a) => _rounding(a[0], (d) => d.ceilToDouble()),
  ),
  'CEILING': _FunctionDef(
    1,
    1,
    (_, a) => _rounding(a[0], (d) => d.ceilToDouble()),
  ),
  'FLOOR': _FunctionDef(
    1,
    1,
    (_, a) => _rounding(a[0], (d) => d.floorToDouble()),
  ),
  'TRUNC': _FunctionDef(
    1,
    1,
    (_, a) => _rounding(a[0], (d) => d.truncateToDouble()),
  ),
  'COS': _math1(math.cos),
  'COSH': _math1((x) => (math.exp(x) + math.exp(-x)) / 2),
  'DEGREES': _math1((x) => x * 180 / math.pi),
  'RADIANS': _math1((x) => x * math.pi / 180),
  'EXP': _math1(math.exp),
  'LN': _math1(math.log),
  'LOG10': _math1((x) => math.log(x) / math.ln10),
  'LOG2': _math1((x) => math.log(x) / math.ln2),
  'LOG': _FunctionDef(1, 2, (_, a) {
    if (a.any((v) => v == null)) return null;
    if (a.length == 1) {
      return _finite(math.log(toNumber(a[0]!).toDouble()) / math.ln10);
    }
    final b = toNumber(a[0]!).toDouble(), x = toNumber(a[1]!).toDouble();
    return _finite(math.log(x) / math.log(b));
  }),
  'MOD': _FunctionDef(2, 2, (_, a) {
    if (a[0] == null || a[1] == null) return null;
    final x = toNumber(a[0]!).toDouble(), y = toNumber(a[1]!).toDouble();
    if (y == 0) return null;
    return _finite(x.remainder(y));
  }),
  'PI': _FunctionDef(0, 0, (_, _) => math.pi),
  'POW': _FunctionDef(2, 2, (_, a) => _pow(a)),
  'POWER': _FunctionDef(2, 2, (_, a) => _pow(a)),
  'SIN': _math1(math.sin),
  'SINH': _math1((x) => (math.exp(x) - math.exp(-x)) / 2),
  'SQRT': _math1(math.sqrt),
  'TAN': _math1(math.tan),
  'TANH': _math1((x) {
    final a = math.exp(x), b = math.exp(-x);
    return (a - b) / (a + b);
  }),
  // Date and time.
  'DATE': _FunctionDef(0, -1, (e, a) => _dateFunction(e, a, _DateOut.date)),
  'TIME': _FunctionDef(0, -1, (e, a) => _dateFunction(e, a, _DateOut.time)),
  'DATETIME': _FunctionDef(
    0,
    -1,
    (e, a) => _dateFunction(e, a, _DateOut.datetime),
  ),
  'JULIANDAY': _FunctionDef(
    0,
    -1,
    (e, a) => _dateFunction(e, a, _DateOut.julian),
  ),
  'UNIXEPOCH': _FunctionDef(
    0,
    -1,
    (e, a) => _dateFunction(e, a, _DateOut.unix),
  ),
  'STRFTIME': _FunctionDef(1, -1, (e, a) => _strftime(e, a)),
  // Geometry.
  ..._geometryFunctions,
};

_FunctionDef _math1(double Function(double) fn) => _FunctionDef(1, 1, (_, a) {
  final v = a[0];
  if (v == null) return null;
  return _finite(fn(toNumber(v).toDouble()));
});

double? _finite(double d) => d.isNaN ? null : d;

Object? _pow(List<Object?> a) {
  if (a[0] == null || a[1] == null) return null;
  return _finite(
    math.pow(toNumber(a[0]!).toDouble(), toNumber(a[1]!).toDouble()).toDouble(),
  );
}

Object? _rounding(Object? v, double Function(double) fn) {
  if (v == null) return null;
  final n = v is num ? v : toNumber(v);
  if (n is int) return n;
  return fn(n as double);
}

Object? _abs(Object? v) {
  if (v == null) return null;
  if (v is int) {
    if (v == _minInt) throw const SqlException('integer overflow');
    return v.abs();
  }
  if (v is double) return v.abs();
  return toNumber(v).toDouble().abs();
}

String _asciiUpper(String s) {
  final units = s.codeUnits;
  if (!units.any((u) => u >= 97 && u <= 122)) return s;
  return String.fromCharCodes([
    for (final u in units) (u >= 97 && u <= 122) ? u - 32 : u,
  ]);
}

Object? _trim(List<Object?> a, {required bool left, required bool right}) {
  final v = a[0];
  if (v == null) return null;
  final s = textOf(v);
  Set<int> chars;
  if (a.length == 2) {
    if (a[1] == null) return null;
    chars = textOf(a[1]!).runes.toSet();
  } else {
    chars = {0x20};
  }
  final runes = s.runes.toList();
  var from = 0, to = runes.length;
  if (left) {
    while (from < to && chars.contains(runes[from])) {
      from++;
    }
  }
  if (right) {
    while (to > from && chars.contains(runes[to - 1])) {
      to--;
    }
  }
  return String.fromCharCodes(runes.sublist(from, to));
}

Object? _extreme(List<Object?> a, {required bool max}) {
  Object? best;
  for (final v in a) {
    if (v == null) return null;
    if (best == null) {
      best = v;
    } else {
      final c = compareValues(v, best);
      if (max ? c > 0 : c < 0) best = v;
    }
  }
  return best;
}

Object? _round(List<Object?> a) {
  final v = a[0];
  if (v == null) return null;
  var digits = 0;
  if (a.length == 2) {
    if (a[1] == null) return null;
    digits = castValue(a[1], 'INTEGER') as int;
    if (digits < 0) digits = 0;
    if (digits > 30) digits = 30;
  }
  final x = toNumber(v).toDouble();
  if (!x.isFinite) return x;
  if (digits == 0) return x.roundToDouble();
  // Past ~15 significant digits a double has nothing left to round.
  if (digits >= 15 || x.abs() >= 1e15) return x;
  // Round half away from zero on the decimal text, as SQLite does, so
  // 2.675 rounds to 2.68 rather than the binary 2.67.
  final s = x.abs().toStringAsFixed(digits + 2);
  final dot = s.indexOf('.');
  final keep = s.substring(0, dot + 1 + digits);
  final next = s.codeUnitAt(dot + 1 + digits) - 48;
  var r = double.parse(keep);
  if (next >= 5) r += math.pow(10, -digits).toDouble();
  r = double.parse(r.toStringAsFixed(digits));
  return x < 0 ? -r : r;
}

Object? _substr(List<Object?> a) {
  final v = a[0];
  if (v == null || a[1] == null) return null;
  if (a.length == 3 && a[2] == null) return null;
  final isBlob = v is Uint8List;
  final List<int> items = isBlob ? v : textOf(v).runes.toList();
  final len = items.length;
  var p1 = castValue(a[1], 'INTEGER') as int;
  var p2 = a.length == 3 ? castValue(a[2], 'INTEGER') as int : len + 1;
  var negP2 = false;
  if (p2 < 0) {
    p2 = -p2;
    negP2 = true;
  }
  if (p1 < 0) {
    p1 += len;
    if (p1 < 0) {
      p2 += p1;
      if (p2 < 0) p2 = 0;
      p1 = 0;
    }
  } else if (p1 > 0) {
    p1--;
  } else if (p2 > 0) {
    p2--;
  }
  if (negP2) {
    p1 -= p2;
    if (p1 < 0) {
      p2 += p1;
      p1 = 0;
    }
  }
  if (p1 > len) p1 = len;
  if (p1 + p2 > len) p2 = len - p1;
  if (p2 < 0) p2 = 0;
  final part = items.sublist(p1, p1 + p2);
  return isBlob ? Uint8List.fromList(part) : String.fromCharCodes(part);
}

/// `printf(format, …)`: %d %i %u %f %e %E %g %G %x %X %o %c %s %q %Q %w %%
/// with flags (`-+ 0#`), width and precision.
Object? _printf(List<Object?> a) {
  if (a[0] == null) return null;
  final fmt = textOf(a[0]!);
  var argi = 1;
  Object? next() => argi < a.length ? a[argi++] : null;
  final out = StringBuffer();
  var i = 0;
  while (i < fmt.length) {
    final c = fmt[i];
    if (c != '%') {
      out.write(c);
      i++;
      continue;
    }
    i++;
    if (i >= fmt.length) break;
    var flags = '';
    while (i < fmt.length && '-+ 0#,!'.contains(fmt[i])) {
      flags += fmt[i++];
    }
    var width = 0;
    if (i < fmt.length && fmt[i] == '*') {
      width = (castValue(next() ?? 0, 'INTEGER') as int);
      i++;
    } else {
      while (i < fmt.length && '0123456789'.contains(fmt[i])) {
        width = width * 10 + (fmt.codeUnitAt(i++) - 48);
      }
    }
    int? precision;
    if (i < fmt.length && fmt[i] == '.') {
      i++;
      precision = 0;
      if (i < fmt.length && fmt[i] == '*') {
        precision = castValue(next() ?? 0, 'INTEGER') as int;
        i++;
      } else {
        while (i < fmt.length && '0123456789'.contains(fmt[i])) {
          precision = precision! * 10 + (fmt.codeUnitAt(i++) - 48);
        }
      }
    }
    while (i < fmt.length && 'lh'.contains(fmt[i])) {
      i++;
    }
    if (i >= fmt.length) break;
    final conv = fmt[i++];
    String body;
    var numeric = false;
    switch (conv) {
      case '%':
        out.write('%');
        continue;
      case 'd':
      case 'i':
      case 'u':
        numeric = true;
        final v = next();
        var n = v == null ? 0 : castValue(v, 'INTEGER') as int;
        if (conv == 'u' && n < 0) n = n.toUnsigned(64);
        body = n.abs().toString();
        if (precision != null) body = body.padLeft(precision, '0');
        if (flags.contains(',')) {
          body = body.replaceAllMapped(
            RegExp(r'\B(?=(\d{3})+(?!\d))'),
            (_) => ',',
          );
        }
        body =
            (n < 0
                ? '-'
                : (flags.contains('+')
                      ? '+'
                      : (flags.contains(' ') ? ' ' : ''))) +
            body;
      case 'f':
      case 'e':
      case 'E':
      case 'g':
      case 'G':
        numeric = true;
        final v = next();
        final d = v == null ? 0.0 : toNumber(v).toDouble();
        final p = precision ?? 6;
        if (conv == 'f') {
          body = d.abs().toStringAsFixed(p);
        } else if (conv == 'e' || conv == 'E') {
          body = d.abs().toStringAsExponential(p);
          body = body.replaceFirstMapped(
            RegExp(r'e([+-])(\d)$'),
            (m) => 'e${m[1]}0${m[2]}',
          );
          if (conv == 'E') body = body.toUpperCase();
        } else {
          body = d.abs().toStringAsPrecision(p == 0 ? 1 : p);
          if (!flags.contains('#') &&
              body.contains('.') &&
              !body.contains('e')) {
            body = body.replaceFirst(RegExp(r'\.?0+$'), '');
          }
          if (conv == 'G') body = body.toUpperCase();
        }
        body =
            (d < 0
                ? '-'
                : (flags.contains('+')
                      ? '+'
                      : (flags.contains(' ') ? ' ' : ''))) +
            body;
      case 'x':
      case 'X':
      case 'o':
        numeric = true;
        final v = next();
        final n = (v == null ? 0 : castValue(v, 'INTEGER') as int).toUnsigned(
          64,
        );
        body = n.toRadixString(conv == 'o' ? 8 : 16);
        if (conv == 'X') body = body.toUpperCase();
        if (precision != null) body = body.padLeft(precision, '0');
        if (flags.contains('#') && n != 0) {
          body = (conv == 'o' ? '0' : (conv == 'x' ? '0x' : '0X')) + body;
        }
      case 'c':
        final v = next();
        final s = v == null ? '' : textOf(v);
        body = s.isEmpty ? '' : String.fromCharCode(s.runes.first);
        if (precision != null && precision > 1) body = body * precision;
      case 's':
      case 'z':
        final v = next();
        body = v == null ? '' : textOf(v);
        if (precision != null && body.runes.length > precision) {
          body = String.fromCharCodes(body.runes.take(precision));
        }
      case 'q':
      case 'Q':
      case 'w':
        final v = next();
        if (v == null) {
          body = conv == 'Q' ? 'NULL' : (conv == 'w' ? '' : '(NULL)');
        } else {
          final quote = conv == 'w' ? '"' : "'";
          final s = textOf(v).replaceAll(quote, '$quote$quote');
          body = conv == 'Q' ? "'$s'" : s;
        }
      default:
        throw SqlException('unknown printf format %$conv');
    }
    if (body.length < width) {
      if (flags.contains('-')) {
        body = body.padRight(width);
      } else if (numeric && flags.contains('0')) {
        final sign = body.startsWith(RegExp(r'[-+ ]')) ? body[0] : '';
        body =
            sign +
            body.substring(sign.length).padLeft(width - sign.length, '0');
      } else {
        body = body.padLeft(width);
      }
    }
    out.write(body);
  }
  return out.toString();
}

// -----------------------------------------------------------------------------
// LIKE and GLOB
// -----------------------------------------------------------------------------

/// One element of a compiled LIKE/GLOB pattern.
final class _Wild {
  const _Wild.char(this.rune) : kind = 0, ranges = const [], negate = false;
  const _Wild.one() : kind = 1, rune = 0, ranges = const [], negate = false;
  const _Wild.many() : kind = 2, rune = 0, ranges = const [], negate = false;
  const _Wild.set(this.ranges, this.negate) : kind = 3, rune = 0;

  /// 0 literal, 1 any one, 2 any run, 3 character set.
  final int kind;
  final int rune;
  final List<(int, int)> ranges;
  final bool negate;

  bool accepts(int c) {
    switch (kind) {
      case 0:
        return c == rune;
      case 1:
        return true;
      default:
        var inSet = false;
        for (final (lo, hi) in ranges) {
          if (c >= lo && c <= hi) {
            inSet = true;
            break;
          }
        }
        return inSet != negate;
    }
  }
}

int _lowerRune(int r) => (r >= 65 && r <= 90) ? r + 32 : r;

bool _wildMatch(List<_Wild> p, List<int> s) {
  var pi = 0, si = 0, star = -1, mark = 0;
  while (si < s.length) {
    if (pi < p.length && p[pi].kind != 2 && p[pi].accepts(s[si])) {
      pi++;
      si++;
    } else if (pi < p.length && p[pi].kind == 2) {
      star = pi++;
      mark = si;
    } else if (star >= 0) {
      pi = star + 1;
      si = ++mark;
    } else {
      return false;
    }
  }
  while (pi < p.length && p[pi].kind == 2) {
    pi++;
  }
  return pi == p.length;
}

/// A LIKE matcher: `%` any run, `_` any one character, ASCII letters
/// compared without case, [escape] makes the next character literal.
bool Function(String) _likeMatcher(String pattern, int? escape) {
  final out = <_Wild>[];
  final runes = pattern.runes.toList();
  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    if (escape != null && r == escape) {
      if (i + 1 < runes.length) {
        out.add(_Wild.char(_lowerRune(runes[++i])));
      } else {
        out.add(_Wild.char(_lowerRune(r)));
      }
    } else if (r == 0x25) {
      if (out.isEmpty || out.last.kind != 2) out.add(const _Wild.many());
    } else if (r == 0x5F) {
      out.add(const _Wild.one());
    } else {
      out.add(_Wild.char(_lowerRune(r)));
    }
  }
  return (s) => _wildMatch(out, [for (final r in s.runes) _lowerRune(r)]);
}

/// A GLOB matcher: `*`, `?` and `[…]` sets (with ranges and `^`), case
/// sensitive.
bool Function(String) _globMatcher(String pattern) {
  final out = <_Wild>[];
  final runes = pattern.runes.toList();
  for (var i = 0; i < runes.length; i++) {
    final r = runes[i];
    if (r == 0x2A) {
      if (out.isEmpty || out.last.kind != 2) out.add(const _Wild.many());
    } else if (r == 0x3F) {
      out.add(const _Wild.one());
    } else if (r == 0x5B) {
      var j = i + 1;
      var negate = false;
      if (j < runes.length && runes[j] == 0x5E) {
        negate = true;
        j++;
      }
      final ranges = <(int, int)>[];
      if (j < runes.length && runes[j] == 0x5D) {
        ranges.add((0x5D, 0x5D));
        j++;
      }
      var closed = false;
      while (j < runes.length) {
        final c = runes[j];
        if (c == 0x5D) {
          closed = true;
          break;
        }
        if (j + 2 < runes.length &&
            runes[j + 1] == 0x2D &&
            runes[j + 2] != 0x5D) {
          ranges.add((c, runes[j + 2]));
          j += 3;
        } else {
          ranges.add((c, c));
          j++;
        }
      }
      if (!closed) {
        // An unterminated set matches nothing, as in SQLite.
        return (_) => false;
      }
      out.add(_Wild.set(ranges, negate));
      i = j;
    } else {
      out.add(_Wild.char(r));
    }
  }
  return (s) => _wildMatch(out, s.runes.toList());
}

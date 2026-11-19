/// SQL values and their semantics, following SQLite.
///
/// A value is one of five storage classes: NULL (`null`), INTEGER ([int]),
/// REAL ([double]), TEXT ([String]) or BLOB ([Uint8List]). Dart [bool]s and
/// [DateTime]s are accepted as parameters and stored as `1`/`0` and as
/// ISO-8601 UTC text (see [bindValue]).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show internal;

import 'schema.dart';

/// The smallest 64-bit integer.
@internal
const int minInt64 = -9223372036854775808;

/// The largest 64-bit integer. Computed, because JavaScript cannot hold the
/// literal; on the web it is the nearest double.
@internal
final int maxInt64 = -(minInt64 + 1);

/// Quotes [name] as an SQL identifier: `"name"`, doubling any `"`.
String quoteIdentifier(String name) => '"${name.replaceAll('"', '""')}"';

/// Formats [value] as an SQL literal: `NULL`, a number, a quoted string or
/// a blob literal `X'…'`. Infinities become `9e999`/`-9e999` and NaN
/// becomes `NULL`, which read back as the same value.
String sqlLiteral(Object? value) {
  final v = bindValue(value);
  return switch (v) {
    null => 'NULL',
    int() => '$v',
    double() when v.isNaN => 'NULL',
    double() when v.isInfinite => v > 0 ? '9e999' : '-9e999',
    double() => formatReal(v),
    String() => "'${v.replaceAll("'", "''")}'",
    Uint8List() => "X'${hexOf(v)}'",
    _ => throw ArgumentError.value(value, 'value', 'Not an SQL value'),
  };
}

/// Converts a Dart value passed in as a parameter or row value to a stored
/// value: `bool` → 1/0, [DateTime] → ISO-8601 UTC text, `List<int>` → blob,
/// NaN → NULL. Throws [ArgumentError] for any other type.
Object? bindValue(Object? value) => switch (value) {
  null || int() || String() || Uint8List() => value,
  double() => value.isNaN ? null : value,
  bool() => value ? 1 : 0,
  DateTime() => value.toUtc().toIso8601String(),
  List<int>() => Uint8List.fromList(value),
  _ => throw ArgumentError.value(
    value,
    'value',
    'Unsupported SQL value type ${value.runtimeType}',
  ),
};

/// Uppercase hex of [bytes], as SQLite's `hex()` gives it.
@internal
String hexOf(Uint8List bytes) {
  const digits = '0123456789ABCDEF';
  final b = StringBuffer();
  for (final x in bytes) {
    b
      ..write(digits[x >> 4])
      ..write(digits[x & 15]);
  }
  return b.toString();
}

/// SQLite's `typeof()`: `null`, `integer`, `real`, `text` or `blob`.
@internal
String typeOf(Object? v) => switch (v) {
  null => 'null',
  int() => 'integer',
  double() => 'real',
  String() => 'text',
  _ => 'blob',
};

/// Formats a REAL the way SQLite prints it: always with a decimal point or
/// an exponent (`5.0`, `0.1`, `1.0e+20`).
@internal
String formatReal(double v) {
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v > 0 ? 'Inf' : '-Inf';
  if (v == v.truncateToDouble() && v.abs() < 1e15) {
    return '${v.toInt()}.0';
  }
  var s = v.toStringAsPrecision(15);
  if (s.contains('e')) {
    // 1.00000000000000e+20 → 1.0e+20
    final parts = s.split('e');
    var mant = parts[0];
    if (mant.contains('.')) {
      mant = mant.replaceFirst(RegExp(r'0+$'), '');
      if (mant.endsWith('.')) mant = '${mant}0';
    } else {
      mant = '$mant.0';
    }
    final exp = int.parse(parts[1]);
    return '${mant}e${exp < 0 ? '-' : '+'}${exp.abs().toString().padLeft(2, '0')}';
  }
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = '${s}0';
  }
  return s;
}

/// The TEXT form of a value, as `CAST(v AS TEXT)` gives it.
@internal
String textOf(Object v) => switch (v) {
  String() => v,
  int() => '$v',
  double() => formatReal(v),
  Uint8List() => utf8.decode(v, allowMalformed: true),
  _ => '$v',
};

final _integerText = RegExp(r'^\s*[+-]?\d+\s*$');
final _realText = RegExp(r'^\s*[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?\s*$');
final _numericPrefix = RegExp(r'^\s*[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?');

/// Parses [s] as a number only if all of it is a well-formed numeric
/// literal (surrounding spaces allowed), as affinity conversion requires.
/// Integers that do not fit 64 bits become reals.
@internal
num? parseNumericText(String s) {
  if (_integerText.hasMatch(s)) {
    return int.tryParse(s.trim()) ?? double.tryParse(s.trim());
  }
  if (_realText.hasMatch(s)) return double.tryParse(s.trim());
  return null;
}

/// The number at the start of [s], or 0 when there is none, as SQLite's
/// arithmetic reads text (`'12abc'` → 12).
@internal
num numericPrefixOf(String s) {
  final m = _numericPrefix.firstMatch(s);
  if (m == null) return 0;
  final t = m.group(0)!.trim();
  if (m.group(2) == null && m.group(3) == null && !t.contains('.')) {
    return int.tryParse(t) ?? double.parse(t);
  }
  return double.parse(t);
}

/// A REAL that holds an integer and fits 64 bits, as an int; otherwise
/// null.
@internal
int? exactInt(double d) {
  if (!d.isFinite || d != d.truncateToDouble()) return null;
  if (d < -9223372036854775808.0 || d >= 9223372036854775808.0) return null;
  return d.toInt();
}

/// Applies a column's [affinity] to a value being stored (SQLite section
/// 3.0 rules).
@internal
Object? applyAffinity(Object? v, Affinity affinity) {
  if (v == null) return null;
  switch (affinity) {
    case Affinity.blob:
      return v;
    case Affinity.text:
      if (v is int || v is double) return textOf(v);
      return v;
    case Affinity.integer:
    case Affinity.numeric:
      if (v is String) {
        final n = parseNumericText(v);
        if (n == null) return v;
        if (n is double) return exactInt(n) ?? n;
        return n;
      }
      if (v is double) return exactInt(v) ?? v;
      return v;
    case Affinity.real:
      if (v is String) {
        final n = parseNumericText(v);
        return n == null ? v : n.toDouble();
      }
      if (v is int) return v.toDouble();
      return v;
  }
}

/// `CAST(v AS type)`.
@internal
Object? castValue(Object? v, String type) {
  if (v == null) return null;
  final affinity = Affinity.of(type);
  switch (affinity) {
    case Affinity.blob:
      if (v is Uint8List) return v;
      return Uint8List.fromList(utf8.encode(textOf(v)));
    case Affinity.text:
      return textOf(v);
    case Affinity.integer:
      final n = toNumber(v);
      if (n is int) return n;
      final d = n as double;
      if (d.isNaN) return 0;
      if (d >= 9223372036854775807.0) return maxInt64;
      if (d <= -9223372036854775808.0) return minInt64;
      return d.truncate();
    case Affinity.real:
      return toNumber(v).toDouble();
    case Affinity.numeric:
      final n = toNumber(v);
      if (n is double) return exactInt(n) ?? n;
      return n;
  }
}

/// The numeric value of [v] for arithmetic: numbers as they are, text by
/// its numeric prefix, blobs through their text. NULL is not handled here.
@internal
num toNumber(Object v) => switch (v) {
  int() => v,
  double() => v,
  String() => numericPrefixOf(v),
  Uint8List() => numericPrefixOf(utf8.decode(v, allowMalformed: true)),
  _ => 0,
};

/// The truth of a value in WHERE, CASE, AND/OR/NOT: NULL → null, otherwise
/// whether its numeric value is non-zero.
@internal
bool? truthOf(Object? v) {
  if (v == null) return null;
  if (v is int) return v != 0;
  if (v is double) return v != 0.0;
  return toNumber(v) != 0;
}

/// A collating sequence for TEXT comparisons.
@internal
enum Collation {
  /// Byte-wise (code unit) comparison. The default.
  binary,

  /// ASCII letters compare without regard to case.
  nocase,

  /// Trailing spaces are ignored.
  rtrim;

  /// The collation named [name] (case-insensitive); null when unknown.
  static Collation? parse(String? name) {
    if (name == null) return null;
    return switch (name.toUpperCase()) {
      'BINARY' => Collation.binary,
      'NOCASE' => Collation.nocase,
      'RTRIM' => Collation.rtrim,
      _ => null,
    };
  }

  /// [s] reduced to the form two equal strings share under this collation.
  String fold(String s) => switch (this) {
    Collation.binary => s,
    Collation.nocase => asciiLower(s),
    Collation.rtrim => s.replaceFirst(RegExp(r' +$'), ''),
  };

  /// Compares two strings under this collation.
  int compare(String a, String b) => switch (this) {
    Collation.binary => a.compareTo(b),
    _ => fold(a).compareTo(fold(b)),
  };
}

/// [s] with ASCII A–Z lowered and every other character kept, as SQLite's
/// NOCASE and LIKE fold case.
@internal
String asciiLower(String s) {
  var changed = false;
  final units = s.codeUnits;
  for (final u in units) {
    if (u >= 65 && u <= 90) {
      changed = true;
      break;
    }
  }
  if (!changed) return s;
  return String.fromCharCodes([
    for (final u in units) (u >= 65 && u <= 90) ? u + 32 : u,
  ]);
}

/// The rank of a storage class in SQLite's sort order: NULL, numbers, TEXT,
/// BLOB.
int _classRank(Object? v) => switch (v) {
  null => 0,
  int() || double() => 1,
  String() => 2,
  _ => 3,
};

/// Compares two numbers exactly, including 64-bit integers against reals.
@internal
int compareNumbers(num a, num b) {
  if (a is int && b is int) return a.compareTo(b);
  if (a is double && a.isNaN) return b is double && b.isNaN ? 0 : -1;
  if (b is double && b.isNaN) return 1;
  final da = a.toDouble(), db = b.toDouble();
  final c = da.compareTo(db);
  if (c != 0 || (a is double && b is double)) return c;
  // Equal as doubles: compare the exact integer against the real's integer.
  final i = a is int ? a : b as int;
  final d = a is double ? a : b as double;
  final di = exactInt(d);
  if (di == null) return c;
  final r = i.compareTo(di);
  return a is int ? r : -r;
}

/// Compares two values in SQLite's total order: NULL < numbers < TEXT <
/// BLOB. TEXT compares under [collation].
@internal
int compareValues(
  Object? a,
  Object? b, [
  Collation collation = Collation.binary,
]) {
  final ra = _classRank(a), rb = _classRank(b);
  if (ra != rb) return ra.compareTo(rb);
  switch (ra) {
    case 0:
      return 0;
    case 1:
      return compareNumbers(a as num, b as num);
    case 2:
      return collation.compare(a as String, b as String);
    default:
      final x = a as Uint8List, y = b as Uint8List;
      final n = x.length < y.length ? x.length : y.length;
      for (var i = 0; i < n; i++) {
        if (x[i] != y[i]) return x[i].compareTo(y[i]);
      }
      return x.length.compareTo(y.length);
  }
}

/// A hashable stand-in for a value, equal for values SQLite treats as
/// equal (1 and 1.0; strings equal under [collation]); used for GROUP BY,
/// DISTINCT, hash joins and indexes. NULL maps to a sentinel, so NULLs
/// group together.
@internal
Object keyOf(Object? v, [Collation collation = Collation.binary]) {
  return switch (v) {
    null => _nullKey,
    int() => v,
    double() => exactInt(v) ?? v,
    String() => collation == Collation.binary ? v : collation.fold(v),
    Uint8List() => BlobKey(v),
    _ => v,
  };
}

const _nullKey = _NullKey();

final class _NullKey {
  const _NullKey();
}

/// A blob compared by content.
@internal
final class BlobKey {
  /// Wraps [bytes].
  BlobKey(this.bytes);

  /// The blob.
  final Uint8List bytes;

  @override
  bool operator ==(Object other) {
    if (other is! BlobKey || other.bytes.length != bytes.length) return false;
    for (var i = 0; i < bytes.length; i++) {
      if (bytes[i] != other.bytes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(bytes);
}

/// Several keys as one, for multi-column GROUP BY, DISTINCT and indexes.
@internal
final class CompositeKey {
  /// Wraps [parts].
  CompositeKey(this.parts) : _hash = Object.hashAll(parts);

  /// The parts, each from [keyOf].
  final List<Object> parts;
  final int _hash;

  @override
  bool operator ==(Object other) {
    if (other is! CompositeKey || other.parts.length != parts.length) {
      return false;
    }
    for (var i = 0; i < parts.length; i++) {
      if (parts[i] != other.parts[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => _hash;
}

/// Copies a stored value so that callers cannot change the database through
/// a returned blob.
@internal
Object? copyValue(Object? v) => v is Uint8List ? Uint8List.fromList(v) : v;

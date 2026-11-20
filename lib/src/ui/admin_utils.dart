/// Formatting and validation helpers shared by the admin UI.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart' show IconData, Icons;

import '../core/database_mode.dart';
import '../core/just_database.dart';
import '../sql/sql_exception.dart';

/// Why [name] cannot be the name of a new database, or null when it can
/// (the rule `JustDatabase.open` enforces).
@internal
String? databaseNameProblem(String name) => JustDatabase.nameProblem(name);

/// A short, readable message for [error].
@internal
String describeError(Object error) => switch (error) {
  SqlException() => error.message,
  ArgumentError() => '${error.message}',
  StateError() => error.message,
  FormatException() => error.message,
  _ => '$error',
};

/// [bytes] as `12 B`, `3.4 KB` or `5.6 MB`.
@internal
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// `1 row`, `2 rows`.
@internal
String plural(int count, String noun, [String? pluralNoun]) =>
    '$count ${count == 1 ? noun : (pluralNoun ?? '${noun}s')}';

/// Uppercase hex of [bytes].
@internal
String hexOfBytes(Uint8List bytes) {
  const digits = '0123456789ABCDEF';
  final b = StringBuffer();
  for (final x in bytes) {
    b
      ..write(digits[x >> 4])
      ..write(digits[x & 15]);
  }
  return b.toString();
}

/// Parses hex digits (spaces allowed, an optional `X'...'` wrapper) into
/// bytes, or returns null when [text] is not hex.
@internal
Uint8List? parseHexBytes(String text) {
  var t = text.trim();
  final wrapped = RegExp(r"^[xX]'(.*)'$").firstMatch(t);
  if (wrapped != null) t = wrapped.group(1)!;
  t = t.replaceAll(RegExp(r'\s+'), '');
  if (t.length.isOdd || !RegExp(r'^[0-9A-Fa-f]*$').hasMatch(t)) return null;
  return Uint8List.fromList([
    for (var i = 0; i < t.length; i += 2)
      int.parse(t.substring(i, i + 2), radix: 16),
  ]);
}

/// A stored value as text for a table cell. DATETIME values are ISO-8601
/// text and are shown exactly as stored. Long text is cut at [maxLength].
@internal
String formatCellValue(Object? value, {int maxLength = 200}) {
  final String text = switch (value) {
    null => 'NULL',
    Uint8List() =>
      value.length <= 32
          ? "X'${hexOfBytes(value)}'"
          : 'BLOB (${formatBytes(value.length)})',
    double() => _formatDouble(value),
    _ => '$value',
  };
  final oneLine = text.replaceAll('\r\n', ' ').replaceAll('\n', ' ');
  if (oneLine.length <= maxLength) return oneLine;
  return '${oneLine.substring(0, maxLength - 1)}…';
}

String _formatDouble(double v) {
  if (v.isNaN) return 'NaN';
  if (v.isInfinite) return v > 0 ? 'Infinity' : '-Infinity';
  return '$v';
}

/// A stored value as editable text (no truncation).
@internal
String editableText(Object? value) => switch (value) {
  null => '',
  Uint8List() => hexOfBytes(value),
  double() => _formatDouble(value),
  _ => '$value',
};

/// The mode's display name.
@internal
String modeLabel(DatabaseMode mode) => switch (mode) {
  DatabaseMode.standard => 'Standard',
  DatabaseMode.readFast => 'Read fast',
  DatabaseMode.writeFast => 'Write fast',
};

/// A three-letter tag for the mode.
@internal
String modeShortLabel(DatabaseMode mode) => switch (mode) {
  DatabaseMode.standard => 'STD',
  DatabaseMode.readFast => 'READ',
  DatabaseMode.writeFast => 'WRITE',
};

/// What the mode does, in one sentence.
@internal
String modeDescription(DatabaseMode mode) => switch (mode) {
  DatabaseMode.standard =>
    'Statements run in order; every committed change is saved.',
  DatabaseMode.readFast =>
    'SELECTs run at once instead of waiting behind earlier writes.',
  DatabaseMode.writeFast =>
    'Saves are batched (at most one per 250 ms); call flush() to save at once.',
};

/// The mode's icon.
@internal
IconData modeIcon(DatabaseMode mode) => switch (mode) {
  DatabaseMode.standard => Icons.balance,
  DatabaseMode.readFast => Icons.menu_book_outlined,
  DatabaseMode.writeFast => Icons.edit_note,
};

/// A value as text for the clipboard: in full, BLOBs as `X'…'`.
@internal
String clipboardText(Object? value) => switch (value) {
  null => 'NULL',
  Uint8List() => "X'${hexOfBytes(value)}'",
  double() => _formatDouble(value),
  _ => '$value',
};

/// [rows] under [columns] as CSV (RFC 4180, CRLF line ends): NULL is an
/// empty field, a BLOB is hex.
@internal
String rowsToCsv(List<String> columns, List<List<Object?>> rows) {
  String field(Object? v) {
    final text = switch (v) {
      null => '',
      Uint8List() => hexOfBytes(v),
      double() => _formatDouble(v),
      _ => '$v',
    };
    final needsQuotes =
        text.contains(',') ||
        text.contains('"') ||
        text.contains('\n') ||
        text.contains('\r');
    return needsQuotes ? '"${text.replaceAll('"', '""')}"' : text;
  }

  final b = StringBuffer()..write(columns.map(field).join(','));
  for (final r in rows) {
    final fields = [
      for (var i = 0; i < columns.length; i++)
        field(i < r.length ? r[i] : null),
    ];
    b
      ..write('\r\n')
      ..write(fields.join(','));
  }
  return b.toString();
}

/// [rows] under [columns] as a JSON array of objects. A BLOB is
/// `{"$blob": base64}`; an infinite or NaN real is a string.
@internal
String rowsToJson(List<String> columns, List<List<Object?>> rows) {
  Object? json(Object? v) => switch (v) {
    Uint8List() => {r'$blob': base64Encode(v)},
    double() when !v.isFinite => _formatDouble(v),
    _ => v,
  };
  return const JsonEncoder.withIndent('  ').convert([
    for (final r in rows)
      {
        for (var i = 0; i < columns.length; i++)
          columns[i]: json(i < r.length ? r[i] : null),
      },
  ]);
}

/// A file name for an export of [name]: `name-20261120-1530.ext`.
@internal
String exportFileName(String name, String extension, [DateTime? at]) {
  final t = at ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '$name-${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}.$extension';
}

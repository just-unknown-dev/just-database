/// Formatting and validation helpers shared by the admin UI.
library;

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

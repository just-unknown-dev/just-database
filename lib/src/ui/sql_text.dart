/// SQL text helpers for the admin UI: highlighting, splitting a script into
/// statements, completion and parameter values.
@internal
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../sql/lexer.dart';
import '../sql/sql_exception.dart';
import 'admin_utils.dart';

/// SQL keywords, for highlighting and completion.
@internal
const Set<String> sqlKeywords = {
  'ABORT', 'ACTION', 'ADD', 'AFTER', 'ALL', 'ALTER', 'ANALYZE', 'AND', //
  'AS', 'ASC', 'AUTOINCREMENT', 'BEFORE', 'BEGIN', 'BETWEEN', 'BY', //
  'CASCADE', 'CASE', 'CAST', 'CHECK', 'COLLATE', 'COLUMN', 'COMMIT', //
  'CONFLICT', 'CONSTRAINT', 'CREATE', 'CROSS', 'CURRENT_DATE', //
  'CURRENT_TIME', 'CURRENT_TIMESTAMP', 'DEFAULT', 'DEFERRABLE', //
  'DEFERRED', 'DELETE', 'DESC', 'DISTINCT', 'DO', 'DROP', 'EACH', 'ELSE', //
  'END', 'ESCAPE', 'EXCEPT', 'EXCLUSIVE', 'EXISTS', 'FAIL', 'FOR', //
  'FOREIGN', 'FROM', 'FULL', 'GLOB', 'GROUP', 'HAVING', 'IF', 'IGNORE', //
  'IMMEDIATE', 'IN', 'INDEX', 'INITIALLY', 'INNER', 'INSERT', 'INSTEAD', //
  'INTERSECT', 'INTO', 'IS', 'ISNULL', 'JOIN', 'KEY', 'LEFT', 'LIKE', //
  'LIMIT', 'MATCH', 'NATURAL', 'NO', 'NOT', 'NOTHING', 'NOTNULL', 'NULL', //
  'NULLS', 'OF', 'OFFSET', 'ON', 'OR', 'ORDER', 'OUTER', 'PRAGMA', //
  'PRIMARY', 'RAISE', 'RECURSIVE', 'REFERENCES', 'REGEXP', 'RELEASE', //
  'RENAME', 'REPLACE', 'RESTRICT', 'RETURNING', 'RIGHT', 'ROLLBACK', 'ROW', //
  'ROWID', 'SAVEPOINT', 'SELECT', 'SET', 'SPATIAL', 'TABLE', 'TEMP', //
  'TEMPORARY', 'THEN', 'TO', 'TRANSACTION', 'TRIGGER', 'UNION', 'UNIQUE', //
  'UPDATE', 'USING', 'VALUES', 'VIEW', 'WHEN', 'WHERE', 'WITH', 'WITHOUT', //
  'FIRST', 'LAST', 'TRUE', 'FALSE',
};

/// Column types offered when designing a table.
@internal
const List<String> commonColumnTypes = [
  'INTEGER',
  'TEXT',
  'REAL',
  'NUMERIC',
  'BLOB',
  'BOOLEAN',
  'DATETIME',
];

/// [name] as SQL: bare when it is a plain identifier that is not a
/// keyword, else double-quoted.
@internal
String sqlName(String name) {
  final plain = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name);
  if (plain && !sqlKeywords.contains(name.toUpperCase())) return name;
  return '"${name.replaceAll('"', '""')}"';
}

// ---------------------------------------------------------------------------
// Highlighting
// ---------------------------------------------------------------------------

/// The colours of highlighted SQL.
@internal
final class SqlColors {
  const SqlColors({
    required this.keyword,
    required this.string,
    required this.number,
    required this.comment,
    required this.parameter,
    required this.function,
    required this.table,
    required this.symbol,
  });

  /// Colours from [scheme].
  factory SqlColors.of(ColorScheme scheme) => SqlColors(
    keyword: scheme.primary,
    string: scheme.tertiary,
    number: scheme.secondary,
    comment: scheme.onSurfaceVariant,
    parameter: scheme.tertiary,
    function: scheme.secondary,
    table: scheme.onSurface,
    symbol: scheme.onSurfaceVariant,
  );

  final Color keyword;
  final Color string;
  final Color number;
  final Color comment;
  final Color parameter;
  final Color function;
  final Color table;
  final Color symbol;
}

/// [sql] as styled spans: keywords, strings, numbers, comments, parameters,
/// function names and the names in [tables] each get their style. Text the
/// lexer cannot read (an unterminated string or comment) keeps the style of
/// what it most likely is.
@internal
List<TextSpan> highlightSql(
  String sql, {
  required SqlColors colors,
  Set<String> tables = const {},
}) {
  var readable = sql.length;
  List<Token> tokens;
  try {
    tokens = tokenize(sql);
  } on SqlException catch (e) {
    readable = (e.offset ?? 0).clamp(0, sql.length);
    try {
      tokens = tokenize(sql.substring(0, readable));
    } on SqlException {
      tokens = const [];
      readable = 0;
    }
  }
  final keyword = TextStyle(color: colors.keyword, fontWeight: FontWeight.w600);
  final string = TextStyle(color: colors.string);
  final number = TextStyle(color: colors.number);
  final comment = TextStyle(color: colors.comment, fontStyle: FontStyle.italic);
  final parameter = TextStyle(
    color: colors.parameter,
    fontWeight: FontWeight.w600,
  );
  final function = TextStyle(color: colors.function);
  final table = TextStyle(color: colors.table, fontWeight: FontWeight.w500);
  final symbol = TextStyle(color: colors.symbol);

  final spans = <TextSpan>[];
  var pos = 0;
  void gap(int to) {
    if (to <= pos) return;
    final text = sql.substring(pos, to);
    spans.add(
      TextSpan(text: text, style: text.trim().isEmpty ? null : comment),
    );
    pos = to;
  }

  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.kind == TokenKind.eof) break;
    gap(t.start);
    final TextStyle? style = switch (t.kind) {
      TokenKind.word =>
        sqlKeywords.contains(t.upper)
            ? keyword
            : (_nextIsOpenParen(sql, t.end)
                  ? function
                  : (tables.contains(t.text.toLowerCase()) ? table : null)),
      TokenKind.quotedIdentifier =>
        tables.contains(t.text.toLowerCase()) ? table : null,
      TokenKind.string || TokenKind.blob => string,
      TokenKind.integer || TokenKind.real => number,
      TokenKind.parameter => parameter,
      TokenKind.hint => comment,
      TokenKind.symbol => symbol,
      TokenKind.eof => null,
    };
    spans.add(TextSpan(text: sql.substring(t.start, t.end), style: style));
    pos = t.end;
  }
  gap(readable);
  if (pos < sql.length) {
    final rest = sql.substring(pos);
    final trimmed = rest.trimLeft();
    spans.add(
      TextSpan(
        text: rest,
        style: trimmed.startsWith('/*') || trimmed.startsWith('--')
            ? comment
            : string,
      ),
    );
  }
  return spans;
}

bool _nextIsOpenParen(String sql, int from) {
  for (var i = from; i < sql.length; i++) {
    final c = sql.codeUnitAt(i);
    if (c == 0x20 || c == 0x09) continue;
    return c == 0x28; // (
  }
  return false;
}

/// A text controller that highlights SQL.
@internal
class SqlEditingController extends TextEditingController {
  SqlEditingController({super.text});

  /// Names (lower case) shown in the table style.
  Set<String> tables = const {};

  String? _cachedText;
  ColorScheme? _cachedScheme;
  Set<String>? _cachedTables;
  List<TextSpan> _cachedSpans = const [];

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    // While an input method composes, keep its underline.
    if (withComposing &&
        value.isComposingRangeValid &&
        !value.composing.isCollapsed) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    if (_cachedText != text ||
        !identical(_cachedScheme, scheme) ||
        !identical(_cachedTables, tables)) {
      _cachedText = text;
      _cachedScheme = scheme;
      _cachedTables = tables;
      _cachedSpans = highlightSql(
        text,
        colors: SqlColors.of(scheme),
        tables: tables,
      );
    }
    return TextSpan(style: style, children: _cachedSpans);
  }
}

// ---------------------------------------------------------------------------
// Statements
// ---------------------------------------------------------------------------

/// Where one statement is in a script: from [start] to [end] (without the
/// `;`).
@internal
typedef StatementRange = ({int start, int end});

/// The statements of [sql], split at `;` outside strings, comments and
/// trigger bodies. Text the lexer cannot read ends the last statement.
@internal
List<StatementRange> splitStatements(String sql) {
  List<Token> tokens;
  var readable = sql.length;
  try {
    tokens = tokenize(sql);
  } on SqlException catch (e) {
    readable = (e.offset ?? 0).clamp(0, sql.length);
    try {
      tokens = tokenize(sql.substring(0, readable));
    } on SqlException {
      tokens = const [];
    }
  }
  final out = <StatementRange>[];
  int? start;
  var end = 0;
  var create = false;
  var trigger = false;
  var inBody = false;
  var caseDepth = 0;
  for (final t in tokens) {
    if (t.kind == TokenKind.eof) break;
    if (start == null) {
      if (t.isSymbol(';')) continue;
      start = t.start;
      create = t.isWord('CREATE');
      trigger = false;
      inBody = false;
      caseDepth = 0;
    }
    if (create && !trigger && t.isWord('TRIGGER')) trigger = true;
    if (trigger && !inBody && t.isWord('BEGIN')) {
      inBody = true;
    } else if (inBody) {
      if (t.isWord('CASE')) {
        caseDepth++;
      } else if (t.isWord('END')) {
        if (caseDepth > 0) {
          caseDepth--;
        } else {
          inBody = false;
        }
      }
    }
    if (t.isSymbol(';') && !inBody) {
      out.add((start: start, end: end));
      start = null;
      continue;
    }
    end = t.end;
  }
  if (readable < sql.length) {
    // An unterminated string or comment: it belongs to the last statement.
    final rest = sql.substring(readable);
    if (rest.trim().isNotEmpty) {
      start ??= readable + rest.length - rest.trimLeft().length;
      end = readable + rest.trimRight().length;
    }
  }
  if (start != null) out.add((start: start, end: end));
  return out;
}

/// The statement at [offset] in [sql]: the one containing it, else the one
/// just before it, else the first. Null when there is none.
@internal
StatementRange? statementAt(String sql, int offset) {
  final all = splitStatements(sql);
  if (all.isEmpty) return null;
  StatementRange? before;
  for (final s in all) {
    if (offset >= s.start && offset <= s.end) return s;
    if (s.end <= offset) before = s;
  }
  return before ?? all.first;
}

/// A short label for a statement: its verb and, for most, its object
/// (`SELECT`, `INSERT INTO notes`, `CREATE TABLE people`).
@internal
String statementLabel(String sql) {
  List<Token> tokens;
  try {
    tokens = tokenize(sql);
  } on SqlException {
    return sql.trim().split(RegExp(r'\s+')).first.toUpperCase();
  }
  final words = <String>[];
  for (final t in tokens) {
    if (t.kind == TokenKind.eof || words.length == 4) break;
    if (t.kind == TokenKind.word) {
      words.add(sqlKeywords.contains(t.upper) ? t.upper : t.text);
    } else if (t.kind == TokenKind.quotedIdentifier) {
      words.add(t.text);
    } else {
      break;
    }
  }
  if (words.isEmpty) return 'Statement';
  final verb = words.first;
  int take;
  switch (verb) {
    case 'INSERT' || 'DELETE' || 'REPLACE':
      take = words.length >= 3 && (words[1] == 'INTO' || words[1] == 'FROM')
          ? 3
          : 1;
    case 'UPDATE':
      take = words.length >= 2 ? 2 : 1;
    case 'CREATE' || 'DROP' || 'ALTER':
      final i = words.indexWhere(
        (w) => const {'TABLE', 'VIEW', 'INDEX', 'TRIGGER'}.contains(w),
      );
      take = i < 0 ? 2 : (i + 2).clamp(1, words.length);
      if (i >= 0 && i + 1 < words.length && words[i + 1] == 'IF') take = i + 1;
    case 'PRAGMA':
      take = words.length >= 2 ? 2 : 1;
    default:
      take = 1;
  }
  return words.take(take).join(' ');
}

/// The line and column (both from 1) of [offset] in [text].
@internal
({int line, int column}) lineAndColumn(String text, int offset) {
  var line = 1;
  var lineStart = 0;
  final end = offset.clamp(0, text.length);
  for (var i = 0; i < end; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      line++;
      lineStart = i + 1;
    }
  }
  return (line: line, column: end - lineStart + 1);
}

// ---------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------

/// The word being typed at [caret]: where it starts, what is typed so far,
/// and the name before a `.` in front of it (`t.na` → qualifier `t`).
@internal
typedef WordAtCaret = ({int start, String prefix, String? qualifier});

bool _isWordChar(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    c == 0x5F;

/// The word ending at [caret] in [text] (see [WordAtCaret]), or null when
/// the caret is not after a word or a `.`.
@internal
WordAtCaret? wordAt(String text, int caret) {
  if (caret < 0 || caret > text.length) return null;
  var start = caret;
  while (start > 0 && _isWordChar(text.codeUnitAt(start - 1))) {
    start--;
  }
  final prefix = text.substring(start, caret);
  String? qualifier;
  if (start > 0 && text.codeUnitAt(start - 1) == 0x2E) {
    var q = start - 1;
    while (q > 0 && _isWordChar(text.codeUnitAt(q - 1))) {
      q--;
    }
    if (q < start - 1) qualifier = text.substring(q, start - 1);
  }
  if (prefix.isEmpty && qualifier == null) return null;
  if (prefix.isNotEmpty && RegExp(r'^[0-9]').hasMatch(prefix)) return null;
  return (start: start, prefix: prefix, qualifier: qualifier);
}

/// The tables a statement names (after FROM, JOIN, INTO, UPDATE or TABLE)
/// and its aliases, all lower case: alias → table, and table → table.
@internal
Map<String, String> referencedTables(String statement) {
  List<Token> tokens;
  try {
    tokens = tokenize(statement);
  } on SqlException catch (e) {
    try {
      tokens = tokenize(statement.substring(0, e.offset ?? 0));
    } on SqlException {
      return const {};
    }
  }
  final out = <String, String>{};
  const introducers = {'FROM', 'JOIN', 'INTO', 'UPDATE', 'TABLE'};
  for (var i = 0; i + 1 < tokens.length; i++) {
    if (!(tokens[i].kind == TokenKind.word &&
        introducers.contains(tokens[i].upper))) {
      continue;
    }
    var j = i + 1;
    while (j < tokens.length &&
        tokens[j].kind == TokenKind.word &&
        const {
          'IF',
          'NOT',
          'EXISTS',
          'OR',
          'REPLACE',
        }.contains(tokens[j].upper)) {
      j++;
    }
    if (j >= tokens.length) break;
    final t = tokens[j];
    if (t.kind != TokenKind.word && t.kind != TokenKind.quotedIdentifier) {
      continue;
    }
    if (t.kind == TokenKind.word && sqlKeywords.contains(t.upper)) continue;
    final table = t.text.toLowerCase();
    out[table] = table;
    var k = j + 1;
    if (k < tokens.length && tokens[k].isWord('AS')) k++;
    if (k < tokens.length) {
      final a = tokens[k];
      if ((a.kind == TokenKind.word && !sqlKeywords.contains(a.upper)) ||
          a.kind == TokenKind.quotedIdentifier) {
        out[a.text.toLowerCase()] = table;
      }
    }
  }
  return out;
}

/// Completions for [word] in [statement]: columns of the tables the
/// statement names first, then table and view names, then keywords, then
/// other columns. [columns] maps each table or view (lower case) to its
/// column names; [names] are the tables and views as declared.
@internal
List<String> completionsFor({
  required WordAtCaret word,
  required String statement,
  required List<String> names,
  required Map<String, List<String>> columns,
  int max = 12,
}) {
  final prefix = word.prefix.toLowerCase();
  final referenced = referencedTables(statement);
  final out = <String>[];
  final seen = <String>{};
  void add(String candidate) {
    final lower = candidate.toLowerCase();
    if (out.length >= max || lower == prefix || !lower.startsWith(prefix)) {
      return;
    }
    if (seen.add(lower)) out.add(candidate);
  }

  final qualifier = word.qualifier?.toLowerCase();
  if (qualifier != null) {
    final table = referenced[qualifier] ?? qualifier;
    for (final c in columns[table] ?? const <String>[]) {
      add(c);
    }
    return out;
  }
  if (prefix.isEmpty) return out;
  for (final t in referenced.values.toSet()) {
    for (final c in columns[t] ?? const <String>[]) {
      add(c);
    }
  }
  for (final n in names) {
    add(n);
  }
  final upper =
      word.prefix.isNotEmpty && word.prefix[0].toUpperCase() == word.prefix[0];
  for (final k in sqlKeywords) {
    add(upper ? k : k.toLowerCase());
  }
  for (final cs in columns.values) {
    for (final c in cs) {
      add(c);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Parameter values
// ---------------------------------------------------------------------------

/// A parameter value typed as text: `NULL`, a number, `'quoted text'`,
/// `X'hex'`, `true`/`false` (1/0); anything else is the text as typed.
@internal
Object? parseParameterText(String text) {
  final t = text.trim();
  if (t.toUpperCase() == 'NULL') return null;
  if (RegExp(r'^[+-]?\d+$').hasMatch(t)) {
    return int.tryParse(t) ?? double.parse(t);
  }
  if (RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$').hasMatch(t)) {
    return double.parse(t);
  }
  if (t.length >= 2 && t.startsWith("'") && t.endsWith("'")) {
    return t.substring(1, t.length - 1).replaceAll("''", "'");
  }
  if (RegExp(r"^[xX]'[0-9A-Fa-f\s]*'$").hasMatch(t)) return parseHexBytes(t);
  if (t.toLowerCase() == 'true') return 1;
  if (t.toLowerCase() == 'false') return 0;
  return text;
}

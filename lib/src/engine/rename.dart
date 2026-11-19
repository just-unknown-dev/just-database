part of 'engine.dart';

// Stored views, triggers and CHECK constraints are kept as SQL text. When a
// table or column is renamed, their text is rewritten token by token, so
// comments and layout survive. The rules recognise where a name is used as
// a table or column; an identifier used for something else that happens to
// share the name may be renamed too, which only matters for names that
// are reused across tables in one trigger.

bool _isName(Token t, String name) =>
    (t.kind == TokenKind.word || t.kind == TokenKind.quotedIdentifier) &&
    t.text.toLowerCase() == name.toLowerCase();

String _replaceTokens(
  String sql,
  List<Token> tokens,
  Set<int> which,
  String newName,
) {
  if (which.isEmpty) return sql;
  final b = StringBuffer();
  var at = 0;
  for (var i = 0; i < tokens.length; i++) {
    if (!which.contains(i)) continue;
    final t = tokens[i];
    b
      ..write(sql.substring(at, t.start))
      ..write(quoteIdentifier(newName));
    at = t.end;
  }
  b.write(sql.substring(at));
  return b.toString();
}

/// Lower-case names of every identifier in [sql].
Set<String> _identifiersIn(String sql) {
  try {
    return {
      for (final t in tokenize(sql))
        if (t.kind == TokenKind.word || t.kind == TokenKind.quotedIdentifier)
          t.text.toLowerCase(),
    };
  } on SqlException {
    return const {};
  }
}

/// Rewrites [sql] so that table [oldName] is called [newName]: after FROM,
/// JOIN, INTO, UPDATE, TABLE, REFERENCES and a trigger's ON, in a FROM
/// list, and as a column qualifier (`old.col`).
String _renameTableInSql(String sql, String oldName, String newName) {
  final tokens = tokenize(sql);
  final which = <int>{};
  var inFrom = false;
  var depth = 0;
  final fromDepth = <int>[];
  var triggerHeader =
      tokens.isNotEmpty && tokens.length > 1 && tokens[1].isWord('TRIGGER');
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (t.isSymbol('(')) depth++;
    if (t.isSymbol(')')) {
      depth--;
      if (fromDepth.isNotEmpty && fromDepth.last > depth) {
        fromDepth.removeLast();
        inFrom = fromDepth.isNotEmpty;
      }
    }
    if (t.kind == TokenKind.word) {
      switch (t.upper) {
        case 'FROM':
          inFrom = true;
          fromDepth.add(depth);
        case 'WHERE':
        case 'GROUP':
        case 'HAVING':
        case 'ORDER':
        case 'LIMIT':
        case 'UNION':
        case 'INTERSECT':
        case 'EXCEPT':
        case 'SET':
        case 'VALUES':
          if (fromDepth.isNotEmpty && fromDepth.last == depth) {
            fromDepth.removeLast();
            inFrom = fromDepth.isNotEmpty;
          }
        case 'BEGIN':
          triggerHeader = false;
      }
    }
    if (!_isName(t, oldName)) continue;
    final prev = i > 0 ? tokens[i - 1] : null;
    final next = i + 1 < tokens.length ? tokens[i + 1] : null;
    if (next != null && next.isSymbol('.')) {
      which.add(i);
      continue;
    }
    if (prev == null) continue;
    if (prev.kind == TokenKind.word &&
        const {
          'FROM',
          'JOIN',
          'INTO',
          'UPDATE',
          'TABLE',
          'REFERENCES',
        }.contains(prev.upper)) {
      which.add(i);
      continue;
    }
    if (triggerHeader && prev.isWord('ON')) {
      which.add(i);
      continue;
    }
    if (inFrom && prev.isSymbol(',')) which.add(i);
  }
  return _replaceTokens(sql, tokens, which, newName);
}

/// Rewrites [sql] so that column [oldName] of [table] is called [newName].
///
/// Qualified uses (`table.col`, and `new.col`/`old.col` when [pseudo]) are
/// always renamed. With [unqualified] (CHECK constraints, and triggers on
/// the table itself) bare uses are renamed too, as is the column list of
/// `UPDATE OF`.
String _renameColumnInSql(
  String sql,
  String oldName,
  String newName, {
  String? table,
  bool unqualified = false,
  bool pseudo = false,
}) {
  final tokens = tokenize(sql);
  final which = <int>{};
  for (var i = 0; i < tokens.length; i++) {
    final t = tokens[i];
    if (!_isName(t, oldName)) continue;
    final prev = i > 0 ? tokens[i - 1] : null;
    final next = i + 1 < tokens.length ? tokens[i + 1] : null;
    if (prev != null && prev.isSymbol('.')) {
      final q = i > 1 ? tokens[i - 2] : null;
      if (q == null) continue;
      final qualifier = q.text.toLowerCase();
      if ((table != null && qualifier == table.toLowerCase()) ||
          (pseudo && (qualifier == 'new' || qualifier == 'old'))) {
        which.add(i);
      }
      continue;
    }
    if (next != null && (next.isSymbol('.') || next.isSymbol('('))) continue;
    if (unqualified) which.add(i);
  }
  return _replaceTokens(sql, tokens, which, newName);
}

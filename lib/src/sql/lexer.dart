import 'dart:typed_data';

import 'package:flutter/foundation.dart' show internal;

import 'sql_exception.dart';

/// The kinds of token.
@internal
enum TokenKind {
  /// A bare word: a keyword or an unquoted identifier. [Token.text] is
  /// as written; [Token.upper] is upper-cased.
  word,

  /// `"name"`, `` `name` `` or `[name]`. [Token.text] is the name.
  quotedIdentifier,

  /// `'text'`. [Token.text] is the text with `''` unescaped.
  string,

  /// `X'0A1B'`. [Token.value] is the bytes.
  blob,

  /// An integer literal. [Token.value] is its int (or a double when it does
  /// not fit 64 bits, as SQLite reads it).
  integer,

  /// A real literal. [Token.value] is its double.
  real,

  /// `?`, `?NNN`, `:name`, `@name` or `$name`. [Token.text] is as written.
  parameter,

  /// Punctuation or an operator. [Token.text] is the symbol.
  symbol,

  /// The body of a `/*+ … */` hint comment.
  hint,

  /// The end of the input.
  eof,
}

/// One token of SQL text.
@internal
final class Token {
  /// Creates a token.
  Token(this.kind, this.text, this.start, this.end, [this.value])
    : upper = kind == TokenKind.word ? text.toUpperCase() : text;

  /// The kind of token.
  final TokenKind kind;

  /// The token's text (see [TokenKind]).
  final String text;

  /// [text] upper-cased, for words.
  final String upper;

  /// The offsets of the token in the SQL text.
  final int start, end;

  /// The literal value, for blobs and numbers.
  final Object? value;

  /// Whether this is the bare word [w] (upper case).
  bool isWord(String w) => kind == TokenKind.word && upper == w;

  /// Whether this is the symbol [s].
  bool isSymbol(String s) => kind == TokenKind.symbol && text == s;

  @override
  String toString() => kind == TokenKind.eof ? 'end of input' : "'$text'";
}

const _symbols2 = ['||', '<<', '>>', '<=', '>=', '==', '!=', '<>'];
const _symbols1 = '+-*/%&|~<>=(),;.';

/// Splits SQL text into tokens.
@internal
List<Token> tokenize(String sql) {
  final tokens = <Token>[];
  final n = sql.length;
  var i = 0;

  bool isIdStart(int c) =>
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      c == 0x5F ||
      c >= 0x80;
  bool isIdPart(int c) => isIdStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x24;
  bool isDigit(int c) => c >= 0x30 && c <= 0x39;

  while (i < n) {
    final c = sql.codeUnitAt(i);
    // Whitespace.
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C) {
      i++;
      continue;
    }
    final start = i;
    // Comments.
    if (c == 0x2D && i + 1 < n && sql.codeUnitAt(i + 1) == 0x2D) {
      while (i < n && sql.codeUnitAt(i) != 0x0A) {
        i++;
      }
      continue;
    }
    if (c == 0x2F && i + 1 < n && sql.codeUnitAt(i + 1) == 0x2A) {
      final close = sql.indexOf('*/', i + 2);
      final end = close < 0 ? n : close + 2;
      if (i + 2 < n && sql.codeUnitAt(i + 2) == 0x2B) {
        if (close < 0) {
          throw SqlException.syntax('unterminated hint comment', sql, start);
        }
        tokens.add(
          Token(TokenKind.hint, sql.substring(i + 3, close).trim(), start, end),
        );
      }
      i = end;
      continue;
    }
    // Strings.
    if (c == 0x27) {
      final (text, end) = _quoted(sql, i, 0x27, 'string');
      tokens.add(Token(TokenKind.string, text, start, end));
      i = end;
      continue;
    }
    // Quoted identifiers.
    if (c == 0x22 || c == 0x60) {
      final (text, end) = _quoted(sql, i, c, 'identifier');
      tokens.add(Token(TokenKind.quotedIdentifier, text, start, end));
      i = end;
      continue;
    }
    if (c == 0x5B) {
      final close = sql.indexOf(']', i + 1);
      if (close < 0) {
        throw SqlException.syntax('unterminated [identifier]', sql, start);
      }
      tokens.add(
        Token(
          TokenKind.quotedIdentifier,
          sql.substring(i + 1, close),
          start,
          close + 1,
        ),
      );
      i = close + 1;
      continue;
    }
    // Blob literals.
    if ((c == 0x58 || c == 0x78) &&
        i + 1 < n &&
        sql.codeUnitAt(i + 1) == 0x27) {
      final (hex, end) = _quoted(sql, i + 1, 0x27, 'blob');
      if (hex.length.isOdd || !RegExp(r'^[0-9A-Fa-f]*$').hasMatch(hex)) {
        throw SqlException.syntax('malformed blob literal', sql, start);
      }
      final bytes = Uint8List(hex.length ~/ 2);
      for (var k = 0; k < bytes.length; k++) {
        bytes[k] = int.parse(hex.substring(2 * k, 2 * k + 2), radix: 16);
      }
      tokens.add(
        Token(TokenKind.blob, sql.substring(start, end), start, end, bytes),
      );
      i = end;
      continue;
    }
    // Numbers.
    if (isDigit(c) ||
        (c == 0x2E && i + 1 < n && isDigit(sql.codeUnitAt(i + 1)))) {
      if (c == 0x30 && i + 1 < n && (sql.codeUnitAt(i + 1) | 0x20) == 0x78) {
        var j = i + 2;
        while (j < n && RegExp(r'[0-9A-Fa-f]').hasMatch(sql[j])) {
          j++;
        }
        final digits = sql.substring(i + 2, j);
        if (digits.isEmpty ||
            digits.length > 16 ||
            (j < n && isIdPart(sql.codeUnitAt(j)))) {
          throw SqlException.syntax('malformed hex literal', sql, start);
        }
        // Two's complement, as SQLite: 0xFFFFFFFFFFFFFFFF is -1.
        final value = BigInt.parse(digits, radix: 16).toSigned(64).toInt();
        tokens.add(
          Token(TokenKind.integer, sql.substring(i, j), start, j, value),
        );
        i = j;
        continue;
      }
      var j = i;
      var isReal = false;
      while (j < n && isDigit(sql.codeUnitAt(j))) {
        j++;
      }
      if (j < n && sql.codeUnitAt(j) == 0x2E) {
        isReal = true;
        j++;
        while (j < n && isDigit(sql.codeUnitAt(j))) {
          j++;
        }
      }
      if (j < n && (sql.codeUnitAt(j) | 0x20) == 0x65) {
        var k = j + 1;
        if (k < n && (sql.codeUnitAt(k) == 0x2B || sql.codeUnitAt(k) == 0x2D)) {
          k++;
        }
        if (k < n && isDigit(sql.codeUnitAt(k))) {
          isReal = true;
          j = k;
          while (j < n && isDigit(sql.codeUnitAt(j))) {
            j++;
          }
        } else {
          throw SqlException.syntax('malformed number', sql, start);
        }
      }
      if (j < n && isIdStart(sql.codeUnitAt(j))) {
        throw SqlException.syntax(
          'unrecognized token "${sql.substring(start, j + 1)}"',
          sql,
          start,
        );
      }
      final text = sql.substring(i, j);
      if (isReal) {
        tokens.add(Token(TokenKind.real, text, start, j, double.parse(text)));
      } else {
        final v = int.tryParse(text);
        tokens.add(
          v != null
              ? Token(TokenKind.integer, text, start, j, v)
              : Token(TokenKind.real, text, start, j, double.parse(text)),
        );
      }
      i = j;
      continue;
    }
    // Words.
    if (isIdStart(c)) {
      var j = i + 1;
      while (j < n && isIdPart(sql.codeUnitAt(j))) {
        j++;
      }
      tokens.add(Token(TokenKind.word, sql.substring(i, j), start, j));
      i = j;
      continue;
    }
    // Parameters.
    if (c == 0x3F) {
      var j = i + 1;
      while (j < n && isDigit(sql.codeUnitAt(j))) {
        j++;
      }
      tokens.add(Token(TokenKind.parameter, sql.substring(i, j), start, j));
      i = j;
      continue;
    }
    if ((c == 0x3A || c == 0x40 || c == 0x24) &&
        i + 1 < n &&
        isIdStart(sql.codeUnitAt(i + 1))) {
      var j = i + 1;
      while (j < n && isIdPart(sql.codeUnitAt(j))) {
        j++;
      }
      tokens.add(Token(TokenKind.parameter, sql.substring(i, j), start, j));
      i = j;
      continue;
    }
    // Symbols.
    if (i + 1 < n) {
      final two = sql.substring(i, i + 2);
      if (_symbols2.contains(two)) {
        tokens.add(Token(TokenKind.symbol, two, start, i + 2));
        i += 2;
        continue;
      }
    }
    if (_symbols1.contains(sql[i])) {
      tokens.add(Token(TokenKind.symbol, sql[i], start, i + 1));
      i++;
      continue;
    }
    throw SqlException.syntax('unrecognized token "${sql[i]}"', sql, start);
  }
  tokens.add(Token(TokenKind.eof, '', n, n));
  return tokens;
}

/// Reads a quoted run starting at [i] (the opening quote [q]), where a
/// doubled quote stands for one. Returns the unescaped text and the offset
/// after the closing quote.
(String, int) _quoted(String sql, int i, int q, String what) {
  final b = StringBuffer();
  var j = i + 1;
  final n = sql.length;
  while (true) {
    if (j >= n) throw SqlException.syntax('unterminated $what', sql, i);
    final c = sql.codeUnitAt(j);
    if (c == q) {
      if (j + 1 < n && sql.codeUnitAt(j + 1) == q) {
        b.writeCharCode(q);
        j += 2;
        continue;
      }
      return (b.toString(), j + 1);
    }
    b.writeCharCode(c);
    j++;
  }
}

import 'ast.dart';

/// SQL tokenizer — converts a SQL string into a list of [Token]s.
class Lexer {
  final String source;
  int _pos = 0;
  int _line = 1;
  int _column = 1;

  /// Maps uppercase keyword strings to their [TokenType].
  static const Map<String, TokenType> _keywords = {
    'CREATE': TokenType.kwCreate,
    'TABLE': TokenType.kwTable,
    'DROP': TokenType.kwDrop,
    'ALTER': TokenType.kwAlter,
    'ADD': TokenType.kwAdd,
    'COLUMN': TokenType.kwColumn,
    'RENAME': TokenType.kwRename,
    'TO': TokenType.kwTo,
    'IF': TokenType.kwIf,
    'NOT': TokenType.kwNot,
    'EXISTS': TokenType.kwExists,
    'SELECT': TokenType.kwSelect,
    'FROM': TokenType.kwFrom,
    'WHERE': TokenType.kwWhere,
    'INSERT': TokenType.kwInsert,
    'INTO': TokenType.kwInto,
    'VALUES': TokenType.kwValues,
    'UPDATE': TokenType.kwUpdate,
    'SET': TokenType.kwSet,
    'DELETE': TokenType.kwDelete,
    'JOIN': TokenType.kwJoin,
    'INNER': TokenType.kwInner,
    'LEFT': TokenType.kwLeft,
    'RIGHT': TokenType.kwRight,
    'OUTER': TokenType.kwOuter,
    'ON': TokenType.kwOn,
    'AS': TokenType.kwAs,
    'ORDER': TokenType.kwOrder,
    'BY': TokenType.kwBy,
    'GROUP': TokenType.kwGroup,
    'HAVING': TokenType.kwHaving,
    'LIMIT': TokenType.kwLimit,
    'OFFSET': TokenType.kwOffset,
    'DISTINCT': TokenType.kwDistinct,
    'ALL': TokenType.kwAll,
    'COUNT': TokenType.kwCount,
    'SUM': TokenType.kwSum,
    'AVG': TokenType.kwAvg,
    'MIN': TokenType.kwMin,
    'MAX': TokenType.kwMax,
    'INTEGER': TokenType.kwInteger,
    'INT': TokenType.kwInt,
    'TEXT': TokenType.kwText,
    'VARCHAR': TokenType.kwVarchar,
    'REAL': TokenType.kwReal,
    'FLOAT': TokenType.kwFloat,
    'DOUBLE': TokenType.kwDouble,
    'BLOB': TokenType.kwBlob,
    'BOOLEAN': TokenType.kwBoolean,
    'BOOL': TokenType.kwBool,
    'DATETIME': TokenType.kwDatetime,
    'DATE': TokenType.kwDate,
    'NULL': TokenType.kwNull_,
    'PRIMARY': TokenType.kwPrimary,
    'KEY': TokenType.kwKey,
    'UNIQUE': TokenType.kwUnique,
    'DEFAULT': TokenType.kwDefault,
    'FOREIGN': TokenType.kwForeign,
    'REFERENCES': TokenType.kwReferences,
    'AUTOINCREMENT': TokenType.kwAutoincrement,
    'AUTO_INCREMENT': TokenType.kwAutoincrement,
    'AND': TokenType.kwAnd,
    'OR': TokenType.kwOr,
    'IN': TokenType.kwIn,
    'LIKE': TokenType.kwLike,
    'IS': TokenType.kwIs,
    'BETWEEN': TokenType.kwBetween,
    'TRUE': TokenType.kwTrue,
    'FALSE': TokenType.kwFalse,
    'CASE': TokenType.kwCase,
    'WHEN': TokenType.kwWhen,
    'THEN': TokenType.kwThen,
    'ELSE': TokenType.kwElse,
    'END': TokenType.kwEnd,
    // Transaction keywords
    'BEGIN': TokenType.kwBegin,
    'COMMIT': TokenType.kwCommit,
    'ROLLBACK': TokenType.kwRollback,
    'SAVEPOINT': TokenType.kwSavepoint,
    'RELEASE': TokenType.kwRelease,
    'TRANSACTION': TokenType.kwTransaction,
    'WORK': TokenType.kwWork,
    'DEFERRED': TokenType.kwDeferred,
    'IMMEDIATE': TokenType.kwImmediate,
    'EXCLUSIVE': TokenType.kwExclusive,
    // View keywords
    'VIEW': TokenType.kwView,
    // Trigger keywords
    'TRIGGER': TokenType.kwTrigger,
    'BEFORE': TokenType.kwBefore,
    'AFTER': TokenType.kwAfter,
    'INSTEAD': TokenType.kwInsteadOf,
    'FOR': TokenType.kwFor,
    'EACH': TokenType.kwEach,
    'ROW': TokenType.kwRow,
    // Index keywords
    'INDEX': TokenType.kwIndex,
    'SPATIAL': TokenType.kwSpatial,
    'USING': TokenType.kwUsing,
  };

  Lexer(this.source);

  /// Tokenizes the entire source string. Always ends with an [TokenType.eof] token.
  List<Token> tokenize() {
    final tokens = <Token>[];
    while (!_isAtEnd()) {
      _skipWhitespaceAndComments();
      if (_isAtEnd()) break;
      tokens.add(_nextToken());
    }
    tokens.add(
      Token(type: TokenType.eof, lexeme: '', line: _line, column: _column),
    );
    return tokens;
  }

  Token _nextToken() {
    final startLine = _line;
    final startCol = _column;
    final ch = _current();

    // String literal
    if (ch == "'") return _readString(startLine, startCol);

    // Number literal
    if (_isDigit(ch) || (ch == '.' && _isDigit(_peekChar(1)))) {
      return _readNumber(startLine, startCol);
    }

    // Identifier or keyword
    if (_isAlpha(ch) || ch == '_') {
      return _readIdentifierOrKeyword(startLine, startCol);
    }

    // Operators and punctuation
    _advance();
    switch (ch) {
      case '(':
        return Token(
          type: TokenType.lparen,
          lexeme: ch,
          line: startLine,
          column: startCol,
        );
      case ')':
        return Token(
          type: TokenType.rparen,
          lexeme: ch,
          line: startLine,
          column: startCol,
        );
      case ',':
        return Token(
          type: TokenType.comma,
          lexeme: ch,
          line: startLine,
          column: startCol,
        );
      case '.':
        return Token(
          type: TokenType.dot,
          lexeme: ch,
          line: startLine,
          column: startCol,
        );
      case ';':
        return Token(
          type: TokenType.semicolon,
          lexeme: ch,
          line: startLine,
          column: startCol,
        );
      case '+':
        return Token(
          type: TokenType.opPlus,
          lexeme: ch,
          line: startLine,
          column: startCol,
        );
      case '-':
        return Token(
          type: TokenType.opMinus,
          lexeme: ch,
          line: startLine,
          column: startCol,
        );
      case '*':
        return Token(
          type: TokenType.opStar,
          lexeme: ch,
          line: startLine,
          column: startCol,
        );
      case '/':
        // Hint comment /*+ ... */ — emit as hintComment token
        if (_current() == '*' && _peekChar(1) == '+') {
          _advance(); // skip *
          _advance(); // skip +
          final hintBuf = StringBuffer();
          while (!_isAtEnd()) {
            if (_current() == '*' && _peekChar(1) == '/') {
              _advance(); // skip *
              _advance(); // skip /
              break;
            }
            if (_current() == '\n') {
              _line++;
              _column = 0;
            }
            hintBuf.write(_current());
            _advance();
          }
          final hintBody = hintBuf.toString().trim();
          return Token(
            type: TokenType.hintComment,
            lexeme: '/*+$hintBody*/',
            value: hintBody,
            line: startLine,
            column: startCol,
          );
        }
        return Token(
          type: TokenType.opSlash,
          lexeme: ch,
          line: startLine,
          column: startCol,
        );
      case '%':
        return Token(
          type: TokenType.opPercent,
          lexeme: ch,
          line: startLine,
          column: startCol,
        );
      case '=':
        return Token(
          type: TokenType.opEq,
          lexeme: ch,
          line: startLine,
          column: startCol,
        );
      case '!':
        if (!_isAtEnd() && _current() == '=') {
          _advance();
          return Token(
            type: TokenType.opNeq,
            lexeme: '!=',
            line: startLine,
            column: startCol,
          );
        }
        throw ParseException('Unexpected character "!"', startLine, startCol);
      case '<':
        if (!_isAtEnd() && _current() == '=') {
          _advance();
          return Token(
            type: TokenType.opLte,
            lexeme: '<=',
            line: startLine,
            column: startCol,
          );
        }
        if (!_isAtEnd() && _current() == '>') {
          _advance();
          return Token(
            type: TokenType.opNeq,
            lexeme: '<>',
            line: startLine,
            column: startCol,
          );
        }
        return Token(
          type: TokenType.opLt,
          lexeme: '<',
          line: startLine,
          column: startCol,
        );
      case '>':
        if (!_isAtEnd() && _current() == '=') {
          _advance();
          return Token(
            type: TokenType.opGte,
            lexeme: '>=',
            line: startLine,
            column: startCol,
          );
        }
        return Token(
          type: TokenType.opGt,
          lexeme: '>',
          line: startLine,
          column: startCol,
        );
      default:
        throw ParseException('Unexpected character "$ch"', startLine, startCol);
    }
  }

  Token _readString(int startLine, int startCol) {
    _advance(); // consume opening '
    final buffer = StringBuffer();
    while (!_isAtEnd()) {
      final ch = _current();
      if (ch == "'") {
        _advance();
        // '' means escaped single-quote
        if (!_isAtEnd() && _current() == "'") {
          buffer.write("'");
          _advance();
        } else {
          break; // end of string
        }
      } else {
        buffer.write(ch);
        if (ch == '\n') {
          _line++;
          _column = 0;
        }
        _advance();
      }
    }
    final str = buffer.toString();
    return Token(
      type: TokenType.litString,
      lexeme: "'$str'",
      value: str,
      line: startLine,
      column: startCol,
    );
  }

  Token _readNumber(int startLine, int startCol) {
    final start = _pos;
    bool isFloat = false;
    while (!_isAtEnd() && _isDigit(_current())) {
      _advance();
    }
    if (!_isAtEnd() && _current() == '.') {
      isFloat = true;
      _advance();
      while (!_isAtEnd() && _isDigit(_current())) {
        _advance();
      }
    }
    // Optional exponent
    if (!_isAtEnd() && (_current() == 'e' || _current() == 'E')) {
      isFloat = true;
      _advance();
      if (!_isAtEnd() && (_current() == '+' || _current() == '-')) _advance();
      while (!_isAtEnd() && _isDigit(_current())) {
        _advance();
      }
    }
    final lexeme = source.substring(start, _pos);
    if (isFloat) {
      return Token(
        type: TokenType.litFloat,
        lexeme: lexeme,
        value: double.parse(lexeme),
        line: startLine,
        column: startCol,
      );
    } else {
      return Token(
        type: TokenType.litInteger,
        lexeme: lexeme,
        value: int.parse(lexeme),
        line: startLine,
        column: startCol,
      );
    }
  }

  Token _readIdentifierOrKeyword(int startLine, int startCol) {
    final start = _pos;
    while (!_isAtEnd() && (_isAlphaNumeric(_current()) || _current() == '_')) {
      _advance();
    }
    final lexeme = source.substring(start, _pos);
    final upper = lexeme.toUpperCase();
    final kwType = _keywords[upper];

    if (kwType != null) {
      dynamic value;
      if (kwType == TokenType.kwTrue) value = true;
      if (kwType == TokenType.kwFalse) value = false;
      return Token(
        type: kwType,
        lexeme: lexeme,
        value: value,
        line: startLine,
        column: startCol,
      );
    }

    // Backtick-quoted identifiers like `name` are handled below
    return Token(
      type: TokenType.identifier,
      lexeme: lexeme,
      value: lexeme,
      line: startLine,
      column: startCol,
    );
  }

  void _skipWhitespaceAndComments() {
    while (!_isAtEnd()) {
      final ch = _current();
      if (ch == ' ' || ch == '\t' || ch == '\r') {
        _advance();
      } else if (ch == '\n') {
        _line++;
        _column = 0;
        _advance();
      } else if (ch == '-' && _peekChar(1) == '-') {
        // Line comment
        while (!_isAtEnd() && _current() != '\n') {
          _advance();
        }
      } else if (ch == '/' && _peekChar(1) == '*') {
        // Hint comments /*+ ... */ must reach _nextToken — don't skip them
        if (_peekChar(2) == '+') break;
        // Block comment
        _advance();
        _advance();
        while (!_isAtEnd()) {
          if (_current() == '*' && _peekChar(1) == '/') {
            _advance();
            _advance();
            break;
          }
          if (_current() == '\n') {
            _line++;
            _column = 0;
          }
          _advance();
        }
      } else {
        break;
      }
    }
  }

  bool _isAtEnd() => _pos >= source.length;

  String _current() => _isAtEnd() ? '' : source[_pos];

  String _peekChar(int offset) {
    final idx = _pos + offset;
    return idx >= source.length ? '' : source[idx];
  }

  void _advance() {
    if (!_isAtEnd()) {
      _pos++;
      _column++;
    }
  }

  bool _isDigit(String ch) =>
      ch.isNotEmpty && ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57;

  bool _isAlpha(String ch) {
    if (ch.isEmpty) return false;
    final code = ch.codeUnitAt(0);
    return (code >= 65 && code <= 90) || (code >= 97 && code <= 122);
  }

  bool _isAlphaNumeric(String ch) => _isAlpha(ch) || _isDigit(ch);
}

import 'package:flutter/foundation.dart' show internal;

import '../storage/schema.dart';
import '../storage/values.dart' show minInt64;
import 'ast.dart';
import 'lexer.dart';
import 'sql_exception.dart';

/// A parsed statement with its parameters.
@internal
final class ParsedStatement {
  ParsedStatement(this.statement, this.source, this.parameterCount, this.names);

  /// The statement.
  final Statement statement;

  /// The whole SQL text the statement was parsed from; the offsets in the
  /// syntax tree point into it.
  final String source;

  /// The statement's own SQL text.
  String get sql => source.substring(statement.start, statement.end);

  /// How many parameters it takes (the largest parameter index).
  final int parameterCount;

  /// The index of each named parameter, by its name without the prefix
  /// (`:id`, `@id` and `$id` are all `id`).
  final Map<String, int> names;
}

/// Words that cannot be used as identifiers without quoting (SQLite's
/// keywords that have no fallback to an identifier), plus the join words.
const _reserved = {
  'ADD', 'ALL', 'ALTER', 'AND', 'AS', 'AUTOINCREMENT', 'BETWEEN', 'CASE', //
  'CHECK', 'COLLATE', 'COMMIT', 'CONSTRAINT', 'CREATE', 'CROSS', //
  'CURRENT_DATE', 'CURRENT_TIME', 'CURRENT_TIMESTAMP', 'DEFAULT', //
  'DEFERRABLE', 'DELETE', 'DISTINCT', 'DROP', 'ELSE', 'ESCAPE', 'EXCEPT', //
  'EXISTS', 'FOREIGN', 'FROM', 'FULL', 'GLOB', 'GROUP', 'HAVING', 'IN', //
  'INDEX', 'INNER', 'INSERT', 'INTERSECT', 'INTO', 'IS', 'ISNULL', 'JOIN', //
  'LEFT', 'LIKE', 'LIMIT', 'NATURAL', 'NOT', 'NOTNULL', 'NULL', 'ON', 'OR', //
  'ORDER', 'OUTER', 'PRIMARY', 'REFERENCES', 'REGEXP', 'RETURNING', 'RIGHT', //
  'ROLLBACK', 'SELECT', 'SET', 'TABLE', 'THEN', 'TO', 'TRANSACTION', //
  'UNION', 'UNIQUE', 'UPDATE', 'USING', 'VALUES', 'WHEN', 'WHERE', //
};

/// Words that may name a column but never follow a table or expression as
/// an alias without `AS`, because a clause starts with them.
const _noImplicitAlias = {'OFFSET', 'WINDOW', 'INDEXED', 'MATCH'};

/// Parses SQL text.
@internal
final class Parser {
  Parser._(this._sql) : _tokens = _withHints(tokenize(_sql));

  final String _sql;
  final List<Token> _tokens;
  int _p = 0;

  // Parameters of the statement being parsed.
  int _paramMax = 0;
  Map<String, int> _named = {};
  bool _paramsAllowed = true;

  /// Parses [sql], which must hold exactly one statement (a trailing `;` is
  /// allowed). Throws [SqlException] on a syntax error, on trailing text,
  /// and when [sql] holds more than one statement.
  static ParsedStatement parseOne(String sql) {
    final p = Parser._(sql);
    p._skipSemicolons();
    if (p._peek.kind == TokenKind.eof) {
      throw SqlException.syntax('empty statement', sql, 0);
    }
    final s = p._statementWithParams();
    p._skipSemicolons();
    if (p._peek.kind != TokenKind.eof) {
      final t = p._peek;
      if (s.statement.end <= t.start && _startsStatement(t)) {
        throw SqlException(
          'more than one statement; use executeScript() to run several',
          kind: SqlErrorKind.misuse,
          sql: sql,
          offset: t.start,
        );
      }
      throw SqlException.syntax('near $t: syntax error', sql, t.start);
    }
    return s;
  }

  /// Parses every statement of [sql], separated by `;`.
  static List<ParsedStatement> parseScript(String sql) {
    final p = Parser._(sql);
    final out = <ParsedStatement>[];
    p._skipSemicolons();
    while (p._peek.kind != TokenKind.eof) {
      out.add(p._statementWithParams());
      if (p._peek.kind != TokenKind.eof && !p._peek.isSymbol(';')) {
        throw SqlException.syntax(
          'near ${p._peek}: syntax error',
          sql,
          p._peek.start,
        );
      }
      p._skipSemicolons();
    }
    return out;
  }

  /// Parses a single expression (used for stored DEFAULT and CHECK text).
  static Expr parseExpression(String sql) {
    final p = Parser._(sql).._paramsAllowed = false;
    final e = p._expr();
    if (p._peek.kind != TokenKind.eof) {
      throw SqlException.syntax(
        'near ${p._peek}: syntax error',
        sql,
        p._peek.start,
      );
    }
    return e;
  }

  static bool _startsStatement(Token t) =>
      t.kind == TokenKind.word &&
      const {
        'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'CREATE', 'DROP', 'ALTER', //
        'BEGIN', 'COMMIT', 'END', 'ROLLBACK', 'SAVEPOINT', 'RELEASE', //
        'PRAGMA', 'REPLACE', 'VALUES', 'WITH', //
      }.contains(t.upper);

  /// Keeps hint comments only where hints may stand: at the start of a
  /// statement and right after SELECT. Elsewhere they are plain comments.
  static List<Token> _withHints(List<Token> tokens) {
    final out = <Token>[];
    for (final t in tokens) {
      if (t.kind == TokenKind.hint) {
        final prev = out.lastWhere(
          (x) => x.kind != TokenKind.hint,
          orElse: () => Token(TokenKind.eof, '', 0, 0),
        );
        if (prev.kind == TokenKind.eof ||
            prev.isSymbol(';') ||
            prev.isWord('SELECT')) {
          out.add(t);
        }
        continue;
      }
      out.add(t);
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Token helpers
  // ---------------------------------------------------------------------------

  Token get _peek => _tokens[_p];
  Token _peekAt(int k) => _tokens[(_p + k).clamp(0, _tokens.length - 1)];
  Token _advance() => _tokens[_p < _tokens.length - 1 ? _p++ : _p];
  int get _lastEnd => _p == 0 ? 0 : _tokens[_p - 1].end;

  bool _isWord(String w) => _peek.isWord(w);
  bool _isSymbol(String s) => _peek.isSymbol(s);

  bool _acceptWord(String w) {
    if (_isWord(w)) {
      _p++;
      return true;
    }
    return false;
  }

  bool _acceptSymbol(String s) {
    if (_isSymbol(s)) {
      _p++;
      return true;
    }
    return false;
  }

  Never _error([String? what]) {
    final t = _peek;
    throw SqlException.syntax(
      what ??
          (t.kind == TokenKind.eof
              ? 'incomplete input'
              : 'near $t: syntax error'),
      _sql,
      t.start,
    );
  }

  void _expectWord(String w) {
    if (!_acceptWord(w)) _error('expected $w but found $_peek');
  }

  void _expectSymbol(String s) {
    if (!_acceptSymbol(s)) _error("expected '$s' but found $_peek");
  }

  void _skipSemicolons() {
    while (_acceptSymbol(';')) {}
  }

  /// An identifier: a quoted identifier, or a bare word that is not
  /// reserved. Strings are accepted too, as SQLite does for names.
  String _name([String what = 'a name']) {
    final t = _peek;
    if (t.kind == TokenKind.quotedIdentifier || t.kind == TokenKind.string) {
      _p++;
      return t.text;
    }
    if (t.kind == TokenKind.word && !_reserved.contains(t.upper)) {
      _p++;
      return t.text;
    }
    _error('expected $what but found $t');
  }

  bool get _atName {
    final t = _peek;
    return t.kind == TokenKind.quotedIdentifier ||
        (t.kind == TokenKind.word && !_reserved.contains(t.upper));
  }

  /// An optional alias: `AS name`, or a bare name that cannot start a
  /// clause.
  String? _alias() {
    if (_acceptWord('AS')) return _name('an alias');
    final t = _peek;
    if (t.kind == TokenKind.quotedIdentifier || t.kind == TokenKind.string) {
      _p++;
      return t.text;
    }
    if (t.kind == TokenKind.word &&
        !_reserved.contains(t.upper) &&
        !_noImplicitAlias.contains(t.upper)) {
      _p++;
      return t.text;
    }
    return null;
  }

  List<String> _nameList() {
    _expectSymbol('(');
    final names = [_name('a column name')];
    while (_acceptSymbol(',')) {
      names.add(_name('a column name'));
    }
    _expectSymbol(')');
    return names;
  }

  // ---------------------------------------------------------------------------
  // Statements
  // ---------------------------------------------------------------------------

  ParsedStatement _statementWithParams() {
    _paramMax = 0;
    _named = {};
    final s = _statement();
    return ParsedStatement(s, _sql, _paramMax, Map.unmodifiable(_named));
  }

  Statement _statement() {
    final hints = _hints();
    final t = _peek;
    if (t.kind != TokenKind.word) _error();
    switch (t.upper) {
      case 'SELECT':
      case 'VALUES':
        return _select(hints: hints);
      case 'WITH':
        _error('WITH (common table expressions) is not supported');
      case 'INSERT':
      case 'REPLACE':
        return _insert();
      case 'UPDATE':
        return _update();
      case 'DELETE':
        return _delete();
      case 'CREATE':
        return _create();
      case 'DROP':
        return _drop();
      case 'ALTER':
        return _alter();
      case 'BEGIN':
        _p++;
        if (!_acceptWord('DEFERRED') && !_acceptWord('IMMEDIATE')) {
          _acceptWord('EXCLUSIVE');
        }
        if (_acceptWord('TRANSACTION') && _atName) _name();
        return BeginStatement(t.start, _lastEnd);
      case 'COMMIT':
      case 'END':
        _p++;
        if (_acceptWord('TRANSACTION') && _atName) _name();
        return CommitStatement(t.start, _lastEnd);
      case 'ROLLBACK':
        _p++;
        if (_acceptWord('TRANSACTION') && _atName && !_isWord('TO')) _name();
        String? sp;
        if (_acceptWord('TO')) {
          _acceptWord('SAVEPOINT');
          sp = _name('a savepoint name');
        }
        return RollbackStatement(sp, t.start, _lastEnd);
      case 'SAVEPOINT':
        _p++;
        return SavepointStatement(_name('a savepoint name'), t.start, _lastEnd);
      case 'RELEASE':
        _p++;
        _acceptWord('SAVEPOINT');
        return ReleaseStatement(_name('a savepoint name'), t.start, _lastEnd);
      case 'PRAGMA':
        _p++;
        final name = _name('a pragma name').toLowerCase();
        String? value;
        if (_acceptSymbol('=')) {
          value = _pragmaValue();
        } else if (_acceptSymbol('(')) {
          value = _pragmaValue();
          _expectSymbol(')');
        }
        return PragmaStatement(name, value, t.start, _lastEnd);
      case 'EXPLAIN':
        _error('EXPLAIN is not supported');
      default:
        _error();
    }
  }

  String _pragmaValue() {
    final t = _advance();
    switch (t.kind) {
      case TokenKind.word:
      case TokenKind.quotedIdentifier:
      case TokenKind.string:
      case TokenKind.integer:
      case TokenKind.real:
        return t.text;
      case TokenKind.symbol when t.text == '-' || t.text == '+':
        final n = _advance();
        if (n.kind != TokenKind.integer && n.kind != TokenKind.real) _error();
        return '${t.text}${n.text}';
      default:
        _p--;
        _error('expected a pragma value');
    }
  }

  List<QueryHint> _hints() {
    final hints = <QueryHint>[];
    while (_peek.kind == TokenKind.hint) {
      hints.addAll(_parseHints(_advance().text));
    }
    return hints;
  }

  static final _hintPattern = RegExp(r'([A-Za-z_]+)\s*(?:\(([^)]*)\))?');

  static List<QueryHint> _parseHints(String body) {
    final hints = <QueryHint>[];
    for (final m in _hintPattern.allMatches(body)) {
      final args = (m.group(2) ?? '')
          .split(RegExp(r'[\s,]+'))
          .where((s) => s.isNotEmpty)
          .toList();
      switch (m.group(1)!.toUpperCase()) {
        case 'INDEX':
        case 'FORCE_INDEX':
          if (args.length >= 2) {
            hints.add(
              QueryHint(HintKind.forceIndex, table: args[0], index: args[1]),
            );
          } else if (args.length == 1) {
            hints.add(QueryHint(HintKind.forceIndex, index: args[0]));
          }
        case 'NO_INDEX':
          hints.add(
            QueryHint(HintKind.noIndex, table: args.isEmpty ? null : args[0]),
          );
        case 'FULL_SCAN':
          hints.add(
            QueryHint(HintKind.fullScan, table: args.isEmpty ? null : args[0]),
          );
        case 'JOIN_ORDER':
          hints.add(QueryHint(HintKind.joinOrder, order: args));
      }
    }
    return hints;
  }

  // ---------------------------------------------------------------------------
  // SELECT
  // ---------------------------------------------------------------------------

  SelectStatement _select({List<QueryHint> hints = const []}) {
    final start = _peek.start;
    final allHints = [...hints];
    final cores = [_selectCore(allHints)];
    final ops = <CompoundOp>[];
    while (true) {
      CompoundOp? op;
      if (_acceptWord('UNION')) {
        op = _acceptWord('ALL') ? CompoundOp.unionAll : CompoundOp.union;
      } else if (_acceptWord('INTERSECT')) {
        op = CompoundOp.intersect;
      } else if (_acceptWord('EXCEPT')) {
        op = CompoundOp.except;
      }
      if (op == null) break;
      ops.add(op);
      cores.add(_selectCore(allHints));
    }
    var orderBy = const <OrderingTerm>[];
    if (_acceptWord('ORDER')) {
      _expectWord('BY');
      orderBy = _orderingTerms();
    }
    Expr? limit, offset;
    if (_acceptWord('LIMIT')) {
      limit = _expr();
      if (_acceptWord('OFFSET')) {
        offset = _expr();
      } else if (_acceptSymbol(',')) {
        // LIMIT offset, count
        offset = limit;
        limit = _expr();
      }
    }
    return SelectStatement(
      cores: cores,
      ops: ops,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      hints: allHints,
      start: start,
      end: _lastEnd,
    );
  }

  List<OrderingTerm> _orderingTerms() {
    final terms = <OrderingTerm>[];
    do {
      final e = _expr();
      var desc = false;
      if (_acceptWord('DESC')) {
        desc = true;
      } else {
        _acceptWord('ASC');
      }
      bool? nullsFirst;
      if (_acceptWord('NULLS')) {
        if (_acceptWord('FIRST')) {
          nullsFirst = true;
        } else {
          _expectWord('LAST');
          nullsFirst = false;
        }
      }
      terms.add(OrderingTerm(e, desc, nullsFirst));
    } while (_acceptSymbol(','));
    return terms;
  }

  SelectCore _selectCore(List<QueryHint> hints) {
    if (_acceptWord('VALUES')) {
      final rows = <List<Expr>>[];
      do {
        rows.add(_valueRow());
      } while (_acceptSymbol(','));
      final width = rows.first.length;
      for (final r in rows) {
        if (r.length != width) {
          _error('all VALUES must have the same number of terms');
        }
      }
      return SelectCore(values: rows);
    }
    _expectWord('SELECT');
    hints.addAll(_hints());
    var distinct = false;
    if (_acceptWord('DISTINCT')) {
      distinct = true;
    } else {
      _acceptWord('ALL');
    }
    final columns = <ResultColumn>[];
    do {
      columns.add(_resultColumn());
    } while (_acceptSymbol(','));
    FromItem? from;
    if (_acceptWord('FROM')) from = _joinChain();
    final where = _acceptWord('WHERE') ? _expr() : null;
    var groupBy = const <Expr>[];
    Expr? having;
    if (_acceptWord('GROUP')) {
      _expectWord('BY');
      groupBy = [_expr()];
      while (_acceptSymbol(',')) {
        groupBy.add(_expr());
      }
    }
    if (_acceptWord('HAVING')) having = _expr();
    if (_isWord('WINDOW')) _error('window functions are not supported');
    return SelectCore(
      distinct: distinct,
      columns: columns,
      from: from,
      where: where,
      groupBy: groupBy,
      having: having,
    );
  }

  List<Expr> _valueRow() {
    _expectSymbol('(');
    final items = [_expr()];
    while (_acceptSymbol(',')) {
      items.add(_expr());
    }
    _expectSymbol(')');
    return items;
  }

  ResultColumn _resultColumn() {
    if (_acceptSymbol('*')) return StarColumn(null);
    // table.*
    if ((_peek.kind == TokenKind.word ||
            _peek.kind == TokenKind.quotedIdentifier) &&
        _peekAt(1).isSymbol('.') &&
        _peekAt(2).isSymbol('*')) {
      final table = _advance().text;
      _p += 2;
      return StarColumn(table);
    }
    final e = _expr();
    return ExprColumn(e, _alias());
  }

  FromItem _joinChain() {
    var left = _tableOrSubquery();
    while (true) {
      if (_acceptSymbol(',')) {
        left = JoinSource(
          left,
          _tableOrSubquery(),
          JoinKind.cross,
          false,
          null,
          null,
        );
        continue;
      }
      final save = _p;
      final natural = _acceptWord('NATURAL');
      JoinKind? kind;
      if (_acceptWord('LEFT')) {
        _acceptWord('OUTER');
        kind = JoinKind.left;
      } else if (_acceptWord('RIGHT')) {
        _acceptWord('OUTER');
        kind = JoinKind.right;
      } else if (_acceptWord('FULL')) {
        _acceptWord('OUTER');
        kind = JoinKind.full;
      } else if (_acceptWord('INNER')) {
        kind = JoinKind.inner;
      } else if (_acceptWord('CROSS')) {
        kind = JoinKind.cross;
      }
      if (!_acceptWord('JOIN')) {
        if (natural || kind != null) _error('expected JOIN');
        _p = save;
        return left;
      }
      kind ??= JoinKind.inner;
      final right = _tableOrSubquery();
      Expr? on;
      List<String>? using;
      if (!natural) {
        if (_acceptWord('ON')) {
          on = _expr();
        } else if (_acceptWord('USING')) {
          using = _nameList();
        }
      }
      if (kind == JoinKind.cross && (on != null || using != null)) {
        // SQLite treats CROSS JOIN … ON like an inner join.
        kind = JoinKind.inner;
      }
      left = JoinSource(left, right, kind, natural, on, using);
    }
  }

  FromItem _tableOrSubquery() {
    if (_acceptSymbol('(')) {
      if (_isWord('SELECT') || _isWord('VALUES')) {
        final q = _select();
        _expectSymbol(')');
        return SubquerySource(q, _alias());
      }
      final inner = _joinChain();
      _expectSymbol(')');
      return inner;
    }
    final start = _peek.start;
    final name = _name('a table name');
    if (_acceptSymbol('.')) {
      // schema.table: only "main" is known.
      if (name.toLowerCase() != 'main') {
        _error('unknown database $name');
      }
      final real = _name('a table name');
      final alias = _alias();
      _indexedBy();
      return TableSource(real, alias, start, _lastEnd);
    }
    final alias = _alias();
    _indexedBy();
    return TableSource(name, alias, start, _lastEnd);
  }

  void _indexedBy() {
    if (_acceptWord('INDEXED')) {
      _expectWord('BY');
      _name('an index name');
    } else if (_isWord('NOT') && _peekAt(1).isWord('INDEXED')) {
      _p += 2;
    }
  }

  // ---------------------------------------------------------------------------
  // INSERT, UPDATE, DELETE
  // ---------------------------------------------------------------------------

  ConflictAction? _orAction() {
    if (!_acceptWord('OR')) return null;
    final t = _advance();
    return switch (t.upper) {
      'ABORT' => ConflictAction.abort,
      'FAIL' => ConflictAction.fail,
      'IGNORE' => ConflictAction.ignore,
      'REPLACE' => ConflictAction.replace,
      'ROLLBACK' => ConflictAction.rollback,
      _ => (() {
        _p--;
        _error('expected ABORT, FAIL, IGNORE, REPLACE or ROLLBACK');
      })(),
    };
  }

  InsertStatement _insert() {
    final start = _peek.start;
    ConflictAction conflict;
    if (_acceptWord('REPLACE')) {
      conflict = ConflictAction.replace;
    } else {
      _expectWord('INSERT');
      conflict = _orAction() ?? ConflictAction.abort;
    }
    _expectWord('INTO');
    var table = _name('a table name');
    if (_acceptSymbol('.')) {
      if (table.toLowerCase() != 'main') _error('unknown database $table');
      table = _name('a table name');
    }
    if (_acceptWord('AS')) _name('an alias');
    List<String>? columns;
    if (_isSymbol('(')) columns = _nameList();
    List<List<Expr>>? values;
    SelectStatement? select;
    if (_acceptWord('DEFAULT')) {
      _expectWord('VALUES');
    } else if (_isWord('VALUES')) {
      _p++;
      values = [];
      do {
        values.add(_valueRow());
      } while (_acceptSymbol(','));
    } else if (_isWord('SELECT') || _peek.kind == TokenKind.hint) {
      select = _select(hints: _hints());
    } else {
      _error('expected VALUES, SELECT or DEFAULT VALUES');
    }
    Upsert? upsert;
    if (_isWord('ON') && _peekAt(1).isWord('CONFLICT')) {
      _p += 2;
      List<String>? target;
      if (_isSymbol('(')) target = _nameList();
      _expectWord('DO');
      if (_acceptWord('NOTHING')) {
        upsert = Upsert(target, true, const [], null);
      } else {
        _expectWord('UPDATE');
        _expectWord('SET');
        final sets = _assignments();
        final where = _acceptWord('WHERE') ? _expr() : null;
        if (target == null) {
          _error('ON CONFLICT DO UPDATE needs a conflict target');
        }
        upsert = Upsert(target, false, sets, where);
      }
    }
    if (_isWord('RETURNING')) _error('RETURNING is not supported');
    return InsertStatement(
      conflict: conflict,
      table: table,
      columns: columns,
      values: values,
      select: select,
      upsert: upsert,
      start: start,
      end: _lastEnd,
    );
  }

  List<Assignment> _assignments() {
    final sets = <Assignment>[];
    do {
      if (_isSymbol('(')) _error('row-value assignments are not supported');
      final col = _name('a column name');
      if (_acceptSymbol('.')) {
        _error('qualified column names are not allowed in SET');
      }
      _expectSymbol('=');
      sets.add(Assignment(col, _expr()));
    } while (_acceptSymbol(','));
    return sets;
  }

  UpdateStatement _update() {
    final start = _peek.start;
    _expectWord('UPDATE');
    final conflict = _orAction() ?? ConflictAction.abort;
    var table = _name('a table name');
    if (_acceptSymbol('.')) {
      if (table.toLowerCase() != 'main') _error('unknown database $table');
      table = _name('a table name');
    }
    final alias = _isWord('SET') ? null : _alias();
    _indexedBy();
    _expectWord('SET');
    final sets = _assignments();
    if (_isWord('FROM')) _error('UPDATE … FROM is not supported');
    final where = _acceptWord('WHERE') ? _expr() : null;
    if (_isWord('RETURNING')) _error('RETURNING is not supported');
    if (_isWord('ORDER') || _isWord('LIMIT')) {
      _error('ORDER BY and LIMIT on UPDATE are not supported');
    }
    return UpdateStatement(
      conflict: conflict,
      table: table,
      alias: alias,
      sets: sets,
      where: where,
      start: start,
      end: _lastEnd,
    );
  }

  DeleteStatement _delete() {
    final start = _peek.start;
    _expectWord('DELETE');
    _expectWord('FROM');
    var table = _name('a table name');
    if (_acceptSymbol('.')) {
      if (table.toLowerCase() != 'main') _error('unknown database $table');
      table = _name('a table name');
    }
    final alias = _isWord('WHERE') ? null : _alias();
    _indexedBy();
    final where = _acceptWord('WHERE') ? _expr() : null;
    if (_isWord('RETURNING')) _error('RETURNING is not supported');
    if (_isWord('ORDER') || _isWord('LIMIT')) {
      _error('ORDER BY and LIMIT on DELETE are not supported');
    }
    return DeleteStatement(
      table: table,
      alias: alias,
      where: where,
      start: start,
      end: _lastEnd,
    );
  }

  // ---------------------------------------------------------------------------
  // CREATE, DROP, ALTER
  // ---------------------------------------------------------------------------

  bool _ifNotExists() {
    if (_isWord('IF')) {
      _p++;
      _expectWord('NOT');
      _expectWord('EXISTS');
      return true;
    }
    return false;
  }

  bool _ifExists() {
    if (_isWord('IF')) {
      _p++;
      _expectWord('EXISTS');
      return true;
    }
    return false;
  }

  String _qualifiedName(String what) {
    final n = _name(what);
    if (_acceptSymbol('.')) {
      if (n.toLowerCase() != 'main') _error('unknown database $n');
      return _name(what);
    }
    return n;
  }

  Statement _create() {
    final start = _peek.start;
    _expectWord('CREATE');
    if (_isWord('TEMP') || _isWord('TEMPORARY')) {
      _error('temporary tables, views and triggers are not supported');
    }
    if (_isWord('VIRTUAL')) _error('virtual tables are not supported');
    if (_acceptWord('TABLE')) return _createTable(start);
    if (_acceptWord('VIEW')) return _createView(start);
    if (_acceptWord('TRIGGER')) return _createTrigger(start);
    var unique = false, spatial = false;
    if (_acceptWord('UNIQUE')) {
      unique = true;
    } else if (_acceptWord('SPATIAL')) {
      spatial = true;
    }
    if (_acceptWord('INDEX')) return _createIndex(start, unique, spatial);
    _error('expected TABLE, VIEW, INDEX or TRIGGER after CREATE');
  }

  CreateTableStatement _createTable(int start) {
    final ifNotExists = _ifNotExists();
    final name = _qualifiedName('a table name');
    if (_acceptWord('AS')) {
      final q = _select(hints: _hints());
      return CreateTableStatement(
        ifNotExists: ifNotExists,
        name: name,
        asSelect: q,
        start: start,
        end: _lastEnd,
      );
    }
    _expectSymbol('(');
    final columns = <ColumnSpec>[];
    final constraints = <ConstraintSpec>[];
    var inConstraints = false;
    do {
      if (_isWord('CONSTRAINT') ||
          _isWord('PRIMARY') ||
          _isWord('UNIQUE') ||
          _isWord('CHECK') ||
          _isWord('FOREIGN')) {
        inConstraints = true;
        constraints.add(_tableConstraint());
      } else {
        if (inConstraints) {
          _error('column definitions must come before constraints');
        }
        columns.add(_columnSpec());
      }
    } while (_acceptSymbol(','));
    _expectSymbol(')');
    if (_isWord('WITHOUT')) _error('WITHOUT ROWID tables are not supported');
    if (_isWord('STRICT')) _error('STRICT tables are not supported');
    if (columns.isEmpty) _error('a table needs at least one column');
    return CreateTableStatement(
      ifNotExists: ifNotExists,
      name: name,
      columns: columns,
      constraints: constraints,
      start: start,
      end: _lastEnd,
    );
  }

  /// A declared type: words, then an optional `(n)` or `(n, m)`.
  String _typeName() {
    final words = <String>[];
    while (_peek.kind == TokenKind.word &&
        !_reserved.contains(_peek.upper) &&
        !const {'GENERATED', 'AS'}.contains(_peek.upper)) {
      words.add(_advance().text);
    }
    if (words.isEmpty) return '';
    var type = words.join(' ');
    if (_isSymbol('(')) {
      final from = _peek.start;
      _p++;
      _signedNumber();
      if (_acceptSymbol(',')) _signedNumber();
      _expectSymbol(')');
      type = '$type${_sql.substring(from, _lastEnd)}';
    }
    return type;
  }

  void _signedNumber() {
    if (!_acceptSymbol('-')) _acceptSymbol('+');
    final t = _advance();
    if (t.kind != TokenKind.integer && t.kind != TokenKind.real) {
      _p--;
      _error('expected a number');
    }
  }

  void _conflictClause() {
    if (_isWord('ON') && _peekAt(1).isWord('CONFLICT')) {
      _p += 2;
      final t = _advance();
      if (!const {
        'ROLLBACK',
        'ABORT',
        'FAIL',
        'IGNORE',
        'REPLACE',
      }.contains(t.upper)) {
        _p--;
        _error('expected a conflict resolution');
      }
    }
  }

  ColumnSpec _columnSpec() {
    final name = _name('a column name');
    final type = _typeName();
    var notNull = false, primaryKey = false, descending = false;
    var autoIncrement = false, unique = false;
    Expr? defaultExpr;
    String? defaultSql, collation;
    final checks = <(Expr, String)>[];
    ForeignKeyDefinition? references;
    while (true) {
      if (_acceptWord('CONSTRAINT')) _name('a constraint name');
      if (_acceptWord('PRIMARY')) {
        _expectWord('KEY');
        if (_acceptWord('DESC')) {
          descending = true;
        } else {
          _acceptWord('ASC');
        }
        _conflictClause();
        primaryKey = true;
        if (_acceptWord('AUTOINCREMENT')) autoIncrement = true;
      } else if (_isWord('NOT') && _peekAt(1).isWord('NULL')) {
        _p += 2;
        _conflictClause();
        notNull = true;
      } else if (_acceptWord('NULL')) {
        _conflictClause();
      } else if (_acceptWord('UNIQUE')) {
        _conflictClause();
        unique = true;
      } else if (_acceptWord('CHECK')) {
        _expectSymbol('(');
        final from = _peek.start;
        final e = _expr();
        final text = _sql.substring(from, _lastEnd);
        _expectSymbol(')');
        checks.add((e, text));
      } else if (_acceptWord('DEFAULT')) {
        final from = _peek.start;
        defaultExpr = _defaultValue();
        defaultSql = _sql.substring(from, _lastEnd);
      } else if (_acceptWord('COLLATE')) {
        collation = _name('a collation name').toUpperCase();
      } else if (_acceptWord('REFERENCES')) {
        references = _foreignKeyClause([name]);
      } else if (_isWord('GENERATED') || _isWord('AS')) {
        _error('generated columns are not supported');
      } else {
        break;
      }
    }
    if (autoIncrement && type.toUpperCase() != 'INTEGER') {
      _error('AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY');
    }
    return ColumnSpec(
      name: name,
      type: type,
      notNull: notNull,
      primaryKey: primaryKey,
      descending: descending,
      autoIncrement: autoIncrement,
      unique: unique,
      defaultExpr: defaultExpr,
      defaultSql: defaultSql,
      collation: collation,
      checks: checks,
      references: references,
    );
  }

  /// `DEFAULT` value: a signed number, a literal, CURRENT_*, or `(expr)`.
  Expr _defaultValue() {
    final t = _peek;
    if (t.isSymbol('(')) {
      _p++;
      final e = _expr();
      _expectSymbol(')');
      return e;
    }
    if (t.isSymbol('-') || t.isSymbol('+')) {
      _p++;
      final n = _peek;
      if (n.kind != TokenKind.integer && n.kind != TokenKind.real) {
        _error('expected a number after ${t.text}');
      }
      _p++;
      final lit = Literal(n.value, n.start, n.end);
      return t.text == '-' ? Unary('-', lit, t.start, n.end) : lit;
    }
    switch (t.kind) {
      case TokenKind.integer:
      case TokenKind.real:
      case TokenKind.string:
      case TokenKind.blob:
        return _primary();
      case TokenKind.word:
        if (const {
          'NULL',
          'TRUE',
          'FALSE',
          'CURRENT_TIME',
          'CURRENT_DATE',
          'CURRENT_TIMESTAMP',
        }.contains(t.upper)) {
          return _primary();
        }
        // SQLite reads a bare word here as text.
        _p++;
        return Literal(t.text, t.start, t.end);
      default:
        _error('expected a DEFAULT value');
    }
  }

  ForeignKeyDefinition _foreignKeyClause(List<String> columns) {
    final parent = _qualifiedName('a table name');
    final parentColumns = _isSymbol('(') ? _nameList() : const <String>[];
    var onDelete = ForeignKeyAction.noAction;
    var onUpdate = ForeignKeyAction.noAction;
    while (true) {
      if (_isWord('ON') &&
          (_peekAt(1).isWord('DELETE') || _peekAt(1).isWord('UPDATE'))) {
        _p++;
        final isDelete = _advance().upper == 'DELETE';
        final action = _fkAction();
        if (isDelete) {
          onDelete = action;
        } else {
          onUpdate = action;
        }
      } else if (_acceptWord('MATCH')) {
        _name('a match type');
      } else {
        break;
      }
    }
    // [NOT] DEFERRABLE [INITIALLY DEFERRED | IMMEDIATE]: parsed, enforced
    // immediately.
    if (_isWord('NOT') && _peekAt(1).isWord('DEFERRABLE')) _p++;
    if (_acceptWord('DEFERRABLE')) {
      if (_acceptWord('INITIALLY')) {
        if (!_acceptWord('DEFERRED')) _expectWord('IMMEDIATE');
      }
    }
    if (parentColumns.isNotEmpty && parentColumns.length != columns.length) {
      _error(
        'foreign key has ${columns.length} columns but references ${parentColumns.length}',
      );
    }
    return ForeignKeyDefinition(
      columns: columns,
      parentTable: parent,
      parentColumns: parentColumns,
      onDelete: onDelete,
      onUpdate: onUpdate,
    );
  }

  ForeignKeyAction _fkAction() {
    if (_acceptWord('CASCADE')) return ForeignKeyAction.cascade;
    if (_acceptWord('RESTRICT')) return ForeignKeyAction.restrict;
    if (_acceptWord('SET')) {
      if (_acceptWord('NULL')) return ForeignKeyAction.setNull;
      _expectWord('DEFAULT');
      return ForeignKeyAction.setDefault;
    }
    if (_acceptWord('NO')) {
      _expectWord('ACTION');
      return ForeignKeyAction.noAction;
    }
    _error('expected CASCADE, RESTRICT, SET NULL, SET DEFAULT or NO ACTION');
  }

  ConstraintSpec _tableConstraint() {
    String? name;
    if (_acceptWord('CONSTRAINT')) name = _name('a constraint name');
    if (_acceptWord('PRIMARY')) {
      _expectWord('KEY');
      final cols = _indexedColumnNames();
      _conflictClause();
      return ConstraintSpec(
        kind: TableConstraintKind.primaryKey,
        name: name,
        columns: cols,
      );
    }
    if (_acceptWord('UNIQUE')) {
      final cols = _indexedColumnNames();
      _conflictClause();
      return ConstraintSpec(
        kind: TableConstraintKind.unique,
        name: name,
        columns: cols,
      );
    }
    if (_acceptWord('CHECK')) {
      _expectSymbol('(');
      final from = _peek.start;
      final e = _expr();
      final text = _sql.substring(from, _lastEnd);
      _expectSymbol(')');
      return ConstraintSpec(
        kind: TableConstraintKind.check,
        name: name,
        check: e,
        checkSql: text,
      );
    }
    if (_acceptWord('FOREIGN')) {
      _expectWord('KEY');
      final cols = _nameList();
      _expectWord('REFERENCES');
      final fk = _foreignKeyClause(cols);
      return ConstraintSpec(
        kind: TableConstraintKind.foreignKey,
        name: name,
        columns: cols,
        foreignKey: fk,
      );
    }
    _error('expected PRIMARY KEY, UNIQUE, CHECK or FOREIGN KEY');
  }

  /// `(col [COLLATE c] [ASC|DESC], …)` in key constraints; only the names
  /// are kept.
  List<String> _indexedColumnNames() => [
    for (final c in _indexedColumns()) c.name,
  ];

  List<IndexedColumn> _indexedColumns() {
    _expectSymbol('(');
    final cols = <IndexedColumn>[];
    do {
      if (!_atName) _error('only column names can be indexed');
      final name = _name('a column name');
      String? collation;
      if (_acceptWord('COLLATE')) {
        collation = _name('a collation name').toUpperCase();
      }
      var desc = false;
      if (_acceptWord('DESC')) {
        desc = true;
      } else {
        _acceptWord('ASC');
      }
      cols.add(IndexedColumn(name, collation, desc));
    } while (_acceptSymbol(','));
    _expectSymbol(')');
    return cols;
  }

  CreateIndexStatement _createIndex(int start, bool unique, bool spatial) {
    final ifNotExists = _ifNotExists();
    // A spatial index may leave out its name (as 1.x documented).
    final name = spatial && _isWord('ON')
        ? null
        : _qualifiedName('an index name');
    _expectWord('ON');
    final table = _name('a table name');
    final columns = _indexedColumns();
    if (_isWord('WHERE')) _error('partial indexes are not supported');
    return CreateIndexStatement(
      unique: unique,
      spatial: spatial,
      ifNotExists: ifNotExists,
      name: name ?? 'spatial_${table}_${columns.map((c) => c.name).join('_')}',
      table: table,
      columns: columns,
      start: start,
      end: _lastEnd,
    );
  }

  CreateViewStatement _createView(int start) {
    final ifNotExists = _ifNotExists();
    final name = _qualifiedName('a view name');
    final columns = _isSymbol('(') ? _nameList() : null;
    _expectWord('AS');
    final saved = _paramsAllowed;
    _paramsAllowed = false;
    final q = _select(hints: _hints());
    _paramsAllowed = saved;
    return CreateViewStatement(
      ifNotExists: ifNotExists,
      name: name,
      columns: columns,
      query: q,
      start: start,
      end: _lastEnd,
    );
  }

  CreateTriggerStatement _createTrigger(int start) {
    final ifNotExists = _ifNotExists();
    final name = _qualifiedName('a trigger name');
    var timing = TriggerTiming.before;
    if (_acceptWord('BEFORE')) {
      timing = TriggerTiming.before;
    } else if (_acceptWord('AFTER')) {
      timing = TriggerTiming.after;
    } else if (_acceptWord('INSTEAD')) {
      _expectWord('OF');
      timing = TriggerTiming.insteadOf;
    }
    TriggerEvent event;
    List<String>? updateOf;
    if (_acceptWord('INSERT')) {
      event = TriggerEvent.insert;
    } else if (_acceptWord('DELETE')) {
      event = TriggerEvent.delete;
    } else if (_acceptWord('UPDATE')) {
      event = TriggerEvent.update;
      if (_acceptWord('OF')) {
        updateOf = [_name('a column name')];
        while (_acceptSymbol(',')) {
          updateOf.add(_name('a column name'));
        }
      }
    } else {
      _error('expected INSERT, UPDATE or DELETE');
    }
    _expectWord('ON');
    final table = _qualifiedName('a table name');
    if (_acceptWord('FOR')) {
      _expectWord('EACH');
      _expectWord('ROW');
    }
    final saved = _paramsAllowed;
    _paramsAllowed = false;
    final when = _acceptWord('WHEN') ? _expr() : null;
    _expectWord('BEGIN');
    final body = <Statement>[];
    while (!_isWord('END')) {
      if (_peek.kind == TokenKind.eof) _error('expected END');
      final t = _peek;
      Statement s;
      if (t.isWord('INSERT') || t.isWord('REPLACE')) {
        s = _insert();
      } else if (t.isWord('UPDATE')) {
        s = _update();
      } else if (t.isWord('DELETE')) {
        s = _delete();
      } else if (t.isWord('SELECT') ||
          t.isWord('VALUES') ||
          t.kind == TokenKind.hint) {
        s = _select(hints: _hints());
      } else {
        _error(
          'only INSERT, UPDATE, DELETE and SELECT are allowed in a trigger',
        );
      }
      body.add(s);
      _expectSymbol(';');
    }
    _p++; // END
    _paramsAllowed = saved;
    if (body.isEmpty) _error('a trigger needs at least one statement');
    return CreateTriggerStatement(
      ifNotExists: ifNotExists,
      name: name,
      timing: timing,
      event: event,
      updateOf: updateOf,
      table: table,
      when: when,
      body: body,
      start: start,
      end: _lastEnd,
    );
  }

  Statement _drop() {
    final start = _peek.start;
    _expectWord('DROP');
    if (_acceptWord('TABLE')) {
      final ifExists = _ifExists();
      return DropTableStatement(
        ifExists,
        _qualifiedName('a table name'),
        start,
        _lastEnd,
      );
    }
    if (_acceptWord('VIEW')) {
      final ifExists = _ifExists();
      return DropViewStatement(
        ifExists,
        _qualifiedName('a view name'),
        start,
        _lastEnd,
      );
    }
    if (_acceptWord('INDEX')) {
      final ifExists = _ifExists();
      final name = _qualifiedName('an index name');
      return DropIndexStatement(ifExists, name, start, _lastEnd);
    }
    if (_acceptWord('TRIGGER')) {
      final ifExists = _ifExists();
      return DropTriggerStatement(
        ifExists,
        _qualifiedName('a trigger name'),
        start,
        _lastEnd,
      );
    }
    _error('expected TABLE, VIEW, INDEX or TRIGGER after DROP');
  }

  Statement _alter() {
    final start = _peek.start;
    _expectWord('ALTER');
    _expectWord('TABLE');
    final table = _qualifiedName('a table name');
    if (_acceptWord('RENAME')) {
      if (_acceptWord('TO')) {
        return RenameTableStatement(
          table,
          _name('a table name'),
          start,
          _lastEnd,
        );
      }
      _acceptWord('COLUMN');
      final col = _name('a column name');
      _expectWord('TO');
      return RenameColumnStatement(
        table,
        col,
        _name('a column name'),
        start,
        _lastEnd,
      );
    }
    if (_acceptWord('ADD')) {
      _acceptWord('COLUMN');
      return AddColumnStatement(table, _columnSpec(), start, _lastEnd);
    }
    if (_acceptWord('DROP')) {
      _acceptWord('COLUMN');
      return DropColumnStatement(
        table,
        _name('a column name'),
        start,
        _lastEnd,
      );
    }
    _error('expected RENAME, ADD or DROP');
  }

  // ---------------------------------------------------------------------------
  // Expressions (SQLite precedence, lowest first)
  // ---------------------------------------------------------------------------

  Expr _expr() => _or();

  Expr _or() {
    var left = _and();
    while (_acceptWord('OR')) {
      final right = _and();
      left = Binary('OR', left, right, left.start, right.end);
    }
    return left;
  }

  Expr _and() {
    var left = _not();
    while (_acceptWord('AND')) {
      final right = _not();
      left = Binary('AND', left, right, left.start, right.end);
    }
    return left;
  }

  Expr _not() {
    if (_isWord('NOT')) {
      final t = _advance();
      final operand = _not();
      return Unary('NOT', operand, t.start, operand.end);
    }
    return _equality();
  }

  Expr _equality() {
    var left = _comparison();
    while (true) {
      final t = _peek;
      if (t.isSymbol('=') || t.isSymbol('==')) {
        _p++;
        final r = _comparison();
        left = Binary('=', left, r, left.start, r.end);
      } else if (t.isSymbol('!=') || t.isSymbol('<>')) {
        _p++;
        final r = _comparison();
        left = Binary('!=', left, r, left.start, r.end);
      } else if (t.isWord('IS')) {
        _p++;
        var not = _acceptWord('NOT');
        if (_acceptWord('DISTINCT')) {
          _expectWord('FROM');
          not = !not;
        }
        final r = _comparison();
        left = Binary(not ? 'IS NOT' : 'IS', left, r, left.start, r.end);
      } else if (t.isWord('ISNULL')) {
        _p++;
        left = Binary(
          'IS',
          left,
          Literal(null, t.start, t.end),
          left.start,
          t.end,
        );
      } else if (t.isWord('NOTNULL')) {
        _p++;
        left = Binary(
          'IS NOT',
          left,
          Literal(null, t.start, t.end),
          left.start,
          t.end,
        );
      } else if (t.isWord('NOT') && _peekAt(1).isWord('NULL')) {
        _p += 2;
        left = Binary(
          'IS NOT',
          left,
          Literal(null, t.start, t.end),
          left.start,
          _lastEnd,
        );
      } else {
        final save = _p;
        final not = _acceptWord('NOT');
        if (_acceptWord('BETWEEN')) {
          final low = _comparison();
          _expectWord('AND');
          final high = _comparison();
          left = Between(left, low, high, not, left.start, high.end);
        } else if (_acceptWord('IN')) {
          left = _inTail(left, not);
        } else if (_isWord('LIKE') || _isWord('GLOB')) {
          final op = _advance().upper;
          final pattern = _comparison();
          Expr? escape;
          if (_acceptWord('ESCAPE')) escape = _comparison();
          left = Like(op, left, pattern, escape, not, left.start, _lastEnd);
        } else if (_isWord('REGEXP') || _isWord('MATCH')) {
          _error('${_peek.upper} is not supported');
        } else {
          _p = save;
          return left;
        }
      }
    }
  }

  Expr _inTail(Expr left, bool not) {
    _expectSymbol('(');
    if (_isWord('SELECT') || _isWord('VALUES')) {
      final q = _select();
      _expectSymbol(')');
      return InSelect(left, q, not, left.start, _lastEnd);
    }
    final items = <Expr>[];
    if (!_isSymbol(')')) {
      items.add(_expr());
      while (_acceptSymbol(',')) {
        items.add(_expr());
      }
    }
    _expectSymbol(')');
    return InList(left, items, not, left.start, _lastEnd);
  }

  Expr _comparison() {
    var left = _bitwise();
    while (true) {
      final t = _peek;
      if (t.kind == TokenKind.symbol &&
          (t.text == '<' ||
              t.text == '<=' ||
              t.text == '>' ||
              t.text == '>=')) {
        _p++;
        final r = _bitwise();
        left = Binary(t.text, left, r, left.start, r.end);
      } else {
        return left;
      }
    }
  }

  Expr _bitwise() {
    var left = _additive();
    while (true) {
      final t = _peek;
      if (t.kind == TokenKind.symbol &&
          (t.text == '&' ||
              t.text == '|' ||
              t.text == '<<' ||
              t.text == '>>')) {
        _p++;
        final r = _additive();
        left = Binary(t.text, left, r, left.start, r.end);
      } else {
        return left;
      }
    }
  }

  Expr _additive() {
    var left = _multiplicative();
    while (true) {
      final t = _peek;
      if (t.isSymbol('+') || t.isSymbol('-')) {
        _p++;
        final r = _multiplicative();
        left = Binary(t.text, left, r, left.start, r.end);
      } else {
        return left;
      }
    }
  }

  Expr _multiplicative() {
    var left = _concat();
    while (true) {
      final t = _peek;
      if (t.isSymbol('*') || t.isSymbol('/') || t.isSymbol('%')) {
        _p++;
        final r = _concat();
        left = Binary(t.text, left, r, left.start, r.end);
      } else {
        return left;
      }
    }
  }

  Expr _concat() {
    var left = _unary();
    while (_isSymbol('||')) {
      _p++;
      final r = _unary();
      left = Binary('||', left, r, left.start, r.end);
    }
    return left;
  }

  Expr _unary() {
    final t = _peek;
    if (t.isSymbol('-') || t.isSymbol('+') || t.isSymbol('~')) {
      _p++;
      final operand = _unary();
      // Fold a negative number literal, so -9223372036854775808 is the
      // smallest integer rather than a real.
      if (t.text == '-' && operand is Literal && operand.value is num) {
        final text = _sql.substring(operand.start, operand.end);
        if (text == '9223372036854775808') {
          return Literal(minInt64, t.start, operand.end);
        }
        return Literal(-(operand.value as num), t.start, operand.end);
      }
      return Unary(t.text, operand, t.start, operand.end);
    }
    var e = _primary();
    while (_isWord('COLLATE')) {
      _p++;
      final name = _name('a collation name');
      e = Collate(e, name.toUpperCase(), e.start, _lastEnd);
    }
    return e;
  }

  Expr _primary() {
    final t = _peek;
    switch (t.kind) {
      case TokenKind.integer:
      case TokenKind.real:
      case TokenKind.blob:
        _p++;
        return Literal(t.value, t.start, t.end);
      case TokenKind.string:
        _p++;
        return Literal(t.text, t.start, t.end);
      case TokenKind.parameter:
        _p++;
        return _param(t);
      case TokenKind.symbol:
        if (t.text == '(') {
          _p++;
          if (_isWord('SELECT') || _isWord('VALUES')) {
            final q = _select();
            _expectSymbol(')');
            return ScalarSubquery(q, t.start, _lastEnd);
          }
          final first = _expr();
          if (_acceptSymbol(',')) {
            final items = [first, _expr()];
            while (_acceptSymbol(',')) {
              items.add(_expr());
            }
            _expectSymbol(')');
            return RowValue(items, t.start, _lastEnd);
          }
          _expectSymbol(')');
          // Keep the parentheses in the span, as SQLite names the column.
          return _reSpan(first, t.start, _lastEnd);
        }
        _error();
      case TokenKind.quotedIdentifier:
        return _columnOrFunction();
      case TokenKind.word:
        switch (t.upper) {
          case 'NULL':
            _p++;
            return Literal(null, t.start, t.end);
          case 'TRUE':
            _p++;
            return Literal(1, t.start, t.end);
          case 'FALSE':
            _p++;
            return Literal(0, t.start, t.end);
          case 'CURRENT_TIME':
          case 'CURRENT_DATE':
          case 'CURRENT_TIMESTAMP':
            _p++;
            return CurrentTime(t.upper, t.start, t.end);
          case 'CAST':
            if (_peekAt(1).isSymbol('(')) {
              _p += 2;
              final e = _expr();
              _expectWord('AS');
              final type = _typeName();
              _expectSymbol(')');
              return Cast(e, type, t.start, _lastEnd);
            }
          case 'CASE':
            return _case();
          case 'EXISTS':
            _p++;
            _expectSymbol('(');
            final q = _select();
            _expectSymbol(')');
            return Exists(q, false, t.start, _lastEnd);
          case 'RAISE':
            if (_peekAt(1).isSymbol('(')) return _raise();
          case 'NOT':
            if (_peekAt(1).isWord('EXISTS')) {
              _p += 2;
              _expectSymbol('(');
              final q = _select();
              _expectSymbol(')');
              return Exists(q, true, t.start, _lastEnd);
            }
        }
        if (_reserved.contains(t.upper)) _error();
        return _columnOrFunction();
      default:
        _error();
    }
  }

  /// [e] with its span widened to [start]..[end] (for parentheses).
  Expr _reSpan(Expr e, int start, int end) {
    // The engine names columns from spans; parentheses around an
    // expression become part of the name, as in SQLite.
    return switch (e) {
      Literal() => Literal(e.value, start, end),
      ColumnRef() => ColumnRef(e.table, e.column, start, end),
      Binary() => Binary(e.op, e.left, e.right, start, end),
      Unary() => Unary(e.op, e.operand, start, end),
      _ => e,
    };
  }

  Expr _param(Token t) {
    if (!_paramsAllowed) {
      throw SqlException.syntax(
        'parameters are not allowed in views, triggers and stored defaults',
        _sql,
        t.start,
      );
    }
    final text = t.text;
    if (text == '?') {
      final i = ++_paramMax;
      return Param(i, null, t.start, t.end);
    }
    if (text.startsWith('?')) {
      final i = int.parse(text.substring(1));
      if (i < 1 || i > 32766) {
        throw SqlException.syntax(
          'parameter index out of range',
          _sql,
          t.start,
        );
      }
      if (i > _paramMax) _paramMax = i;
      return Param(i, null, t.start, t.end);
    }
    final name = text.substring(1);
    final i = _named[name] ??= ++_paramMax;
    return Param(i, name, t.start, t.end);
  }

  Expr _columnOrFunction() {
    final t = _advance();
    final name = t.text;
    if (_isSymbol('(') && t.kind == TokenKind.word) {
      _p++;
      final upper = t.upper;
      var distinct = false, star = false;
      final args = <Expr>[];
      if (_acceptSymbol('*')) {
        star = true;
      } else if (!_isSymbol(')')) {
        distinct = _acceptWord('DISTINCT');
        if (!distinct) _acceptWord('ALL');
        args.add(_expr());
        while (_acceptSymbol(',')) {
          args.add(_expr());
        }
      }
      _expectSymbol(')');
      if (_isWord('FILTER') || _isWord('OVER')) {
        _error('${_peek.upper} clauses are not supported');
      }
      return FunctionCall(upper, args, distinct, star, t.start, _lastEnd);
    }
    if (_isSymbol('.')) {
      _p++;
      final col = _peek;
      if (col.kind == TokenKind.quotedIdentifier ||
          (col.kind == TokenKind.word)) {
        _p++;
        if (_isSymbol('.')) {
          // schema.table.column
          if (name.toLowerCase() != 'main') _error('unknown database $name');
          _p++;
          final c2 = _advance();
          return ColumnRef(col.text, c2.text, t.start, c2.end);
        }
        return ColumnRef(name, col.text, t.start, col.end);
      }
      _error('expected a column name');
    }
    return ColumnRef(null, name, t.start, t.end);
  }

  Expr _case() {
    final t = _advance();
    Expr? base;
    if (!_isWord('WHEN')) base = _expr();
    final whens = <(Expr, Expr)>[];
    while (_acceptWord('WHEN')) {
      final w = _expr();
      _expectWord('THEN');
      whens.add((w, _expr()));
    }
    if (whens.isEmpty) _error('CASE needs at least one WHEN');
    final otherwise = _acceptWord('ELSE') ? _expr() : null;
    _expectWord('END');
    return Case(base, whens, otherwise, t.start, _lastEnd);
  }

  Expr _raise() {
    final t = _advance();
    _expectSymbol('(');
    final k = _advance();
    RaiseKind kind;
    switch (k.upper) {
      case 'IGNORE':
        _expectSymbol(')');
        return Raise(RaiseKind.ignore, null, t.start, _lastEnd);
      case 'ROLLBACK':
        kind = RaiseKind.rollback;
      case 'ABORT':
        kind = RaiseKind.abort;
      case 'FAIL':
        kind = RaiseKind.fail;
      default:
        _p--;
        _error('expected IGNORE, ROLLBACK, ABORT or FAIL');
    }
    _expectSymbol(',');
    final m = _advance();
    if (m.kind != TokenKind.string) {
      _p--;
      _error('expected an error message');
    }
    _expectSymbol(')');
    return Raise(kind, m.text, t.start, _lastEnd);
  }
}

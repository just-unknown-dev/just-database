import 'ast.dart';
import 'lexer.dart';

/// Recursive-descent SQL parser.
/// Converts a token list into an [Statement] AST.
class Parser {
  final List<Token> _tokens;
  int _pos = 0;
  final List<QueryHint> _pendingHints = [];

  Parser(this._tokens);

  /// Convenience factory: tokenize + parse in one call.
  static Statement parseSQL(String sql) {
    final tokens = Lexer(sql).tokenize();
    return Parser(tokens).parse();
  }

  /// Parse a SQL script containing multiple semicolon-separated statements.
  static List<Statement> parseSQLStatements(String sql) {
    final tokens = Lexer(sql).tokenize();
    final parser = Parser(tokens);
    final stmts = <Statement>[];
    while (!parser._isAtEnd()) {
      while (parser._check(TokenType.semicolon)) {
        parser._advance();
      }
      if (parser._isAtEnd()) break;
      stmts.add(parser._parseStatement());
      parser._match(TokenType.semicolon);
    }
    return stmts;
  }

  Statement parse() {
    // Skip leading semicolons
    while (_check(TokenType.semicolon)) {
      _advance();
    }
    final stmt = _parseStatement();
    // Allow trailing semicolon
    _match(TokenType.semicolon);
    return stmt;
  }

  Statement _parseStatement() {
    // Collect any leading query hints (/*+ ... */ before SELECT etc.)
    while (_check(TokenType.hintComment)) {
      _pendingHints.addAll(_parseHintBody(_advance().value as String? ?? ''));
    }
    final t = _peek();
    switch (t.type) {
      case TokenType.kwSelect:
        return _parseSelect();
      case TokenType.kwInsert:
        return _parseInsert();
      case TokenType.kwUpdate:
        return _parseUpdate();
      case TokenType.kwDelete:
        return _parseDelete();
      case TokenType.kwCreate:
        return _parseCreate();
      case TokenType.kwDrop:
        return _parseDrop();
      case TokenType.kwAlter:
        return _parseAlter();
      case TokenType.kwBegin:
        return _parseBegin();
      case TokenType.kwCommit:
        return _parseCommit();
      case TokenType.kwRollback:
        return _parseRollback();
      case TokenType.kwSavepoint:
        return _parseSavepoint();
      case TokenType.kwRelease:
        return _parseRelease();
      default:
        throw _error(
          'Expected SQL statement (SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, ALTER, BEGIN, COMMIT, ROLLBACK, SAVEPOINT, RELEASE)',
        );
    }
  }

  // ===========================================================================
  // SELECT
  // ===========================================================================

  SelectStatement _parseSelect() {
    _consume(TokenType.kwSelect);
    // Collect inline query hints: SELECT /*+ INDEX(tbl idx) */ ...
    while (_check(TokenType.hintComment)) {
      _pendingHints.addAll(_parseHintBody(_advance().value as String? ?? ''));
    }
    final distinct = _match(TokenType.kwDistinct) != null;

    final columns = _parseSelectList();
    // Allow SELECT without FROM (e.g. SELECT 1+1, scalar functions).
    // In that case, use a virtual "_dual_" table (one row, no columns).
    final String tableName;
    final String? tableAlias;
    if (_check(TokenType.kwFrom)) {
      _advance(); // consume FROM
      final ref = _parseTableRef();
      tableName = ref.$1;
      tableAlias = ref.$2;
    } else {
      tableName = '_dual_';
      tableAlias = null;
    }
    final joins = _parseJoins();
    Expression? where;
    if (_match(TokenType.kwWhere) != null) {
      where = _parseExpression();
    }
    final groupBy = <String>[];
    if (_checkSequence([TokenType.kwGroup, TokenType.kwBy])) {
      _advance();
      _advance();
      groupBy.add(_parseColumnName());
      while (_match(TokenType.comma) != null) {
        groupBy.add(_parseColumnName());
      }
    }
    Expression? having;
    if (_match(TokenType.kwHaving) != null) {
      having = _parseExpression();
    }
    final orderBy = <OrderByClause>[];
    if (_checkSequence([TokenType.kwOrder, TokenType.kwBy])) {
      _advance();
      _advance();
      orderBy.addAll(_parseOrderByList());
    }
    int? limit;
    if (_match(TokenType.kwLimit) != null) {
      limit = _consumeInt('Expected integer after LIMIT');
    }
    int? offset;
    if (_match(TokenType.kwOffset) != null) {
      offset = _consumeInt('Expected integer after OFFSET');
    }

    final hints = List<QueryHint>.of(_pendingHints);
    _pendingHints.clear();
    return SelectStatement(
      columns: columns,
      tableName: tableName,
      tableAlias: tableAlias,
      joins: joins,
      whereClause: where,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      distinct: distinct,
      hints: hints,
    );
  }

  List<SelectColumn> _parseSelectList() {
    final cols = <SelectColumn>[];
    cols.add(_parseSelectColumn());
    while (_match(TokenType.comma) != null) {
      cols.add(_parseSelectColumn());
    }
    return cols;
  }

  SelectColumn _parseSelectColumn() {
    // SELECT *
    if (_check(TokenType.opStar)) {
      _advance();
      return const SelectColumn(isStar: true);
    }
    // SELECT t.*
    if (_check(TokenType.identifier) &&
        _peekAt(1).type == TokenType.dot &&
        _peekAt(2).type == TokenType.opStar) {
      final prefix = _advance().value as String;
      _advance(); // dot
      _advance(); // *
      return SelectColumn(isStar: true, starTablePrefix: prefix);
    }

    final expr = _parseExpression();
    String? alias;
    if (_match(TokenType.kwAs) != null) {
      alias = _parseColumnName();
    } else if (_check(TokenType.identifier)) {
      // Implicit alias
      alias = _advance().value as String;
    }
    return SelectColumn(expression: expr, alias: alias);
  }

  /// Parses "tableName [alias]" or "tableName AS alias".
  (String, String?) _parseTableRef() {
    final name = _parseTableName();
    String? alias;
    if (_match(TokenType.kwAs) != null) {
      alias = _parseColumnName();
    } else if (_check(TokenType.identifier)) {
      alias = _advance().value as String;
    }
    return (name, alias);
  }

  List<JoinClause> _parseJoins() {
    final joins = <JoinClause>[];
    while (_isJoinStart()) {
      joins.add(_parseJoin());
    }
    return joins;
  }

  bool _isJoinStart() {
    final t = _peek().type;
    return t == TokenType.kwJoin ||
        t == TokenType.kwInner ||
        t == TokenType.kwLeft ||
        t == TokenType.kwRight;
  }

  JoinClause _parseJoin() {
    JoinType type;
    final t = _peek().type;
    if (t == TokenType.kwInner) {
      _advance();
      _consume(TokenType.kwJoin);
      type = JoinType.inner;
    } else if (t == TokenType.kwLeft) {
      _advance();
      _match(TokenType.kwOuter);
      _consume(TokenType.kwJoin);
      type = JoinType.left;
    } else if (t == TokenType.kwRight) {
      _advance();
      _match(TokenType.kwOuter);
      _consume(TokenType.kwJoin);
      type = JoinType.right;
    } else {
      _consume(TokenType.kwJoin);
      type = JoinType.inner;
    }
    final (tableName, alias) = _parseTableRef();
    _consume(TokenType.kwOn, errorMessage: 'Expected ON after JOIN table name');
    final condition = _parseExpression();
    return JoinClause(
      type: type,
      tableName: tableName,
      alias: alias,
      condition: condition,
    );
  }

  List<OrderByClause> _parseOrderByList() {
    final clauses = <OrderByClause>[];
    clauses.add(_parseOrderByClause());
    while (_match(TokenType.comma) != null) {
      clauses.add(_parseOrderByClause());
    }
    return clauses;
  }

  OrderByClause _parseOrderByClause() {
    final expr = _parseExpression();
    bool desc = false;
    if (_check(TokenType.identifier)) {
      final lexeme = _peek().lexeme.toUpperCase();
      if (lexeme == 'DESC') {
        _advance();
        desc = true;
      } else if (lexeme == 'ASC') {
        _advance();
      }
    }
    return OrderByClause(expression: expr, descending: desc);
  }

  // ===========================================================================
  // INSERT
  // ===========================================================================

  InsertStatement _parseInsert() {
    _consume(TokenType.kwInsert);
    _consume(TokenType.kwInto, errorMessage: 'Expected INTO after INSERT');
    final tableName = _parseTableName();

    List<String>? columns;
    if (_check(TokenType.lparen)) {
      // Peek: if next after '(' is an identifier followed by ')' or ',' it's column list
      // (Not a VALUES subquery)
      _advance(); // consume '('
      columns = [];
      columns.add(_parseColumnName());
      while (_match(TokenType.comma) != null) {
        columns.add(_parseColumnName());
      }
      _consume(TokenType.rparen);
    }

    _consume(TokenType.kwValues, errorMessage: 'Expected VALUES');
    final valueRows = <List<Expression>>[];
    valueRows.add(_parseValueRow());
    while (_match(TokenType.comma) != null) {
      valueRows.add(_parseValueRow());
    }

    return InsertStatement(
      tableName: tableName,
      columns: columns,
      valueRows: valueRows,
    );
  }

  List<Expression> _parseValueRow() {
    _consume(TokenType.lparen);
    final values = <Expression>[];
    values.add(_parseExpression());
    while (_match(TokenType.comma) != null) {
      values.add(_parseExpression());
    }
    _consume(TokenType.rparen);
    return values;
  }

  // ===========================================================================
  // UPDATE
  // ===========================================================================

  UpdateStatement _parseUpdate() {
    _consume(TokenType.kwUpdate);
    final tableName = _parseTableName();
    _consume(TokenType.kwSet, errorMessage: 'Expected SET after table name');
    final assignments = <AssignmentClause>[];
    assignments.add(_parseAssignment());
    while (_match(TokenType.comma) != null) {
      assignments.add(_parseAssignment());
    }
    Expression? where;
    if (_match(TokenType.kwWhere) != null) {
      where = _parseExpression();
    }
    return UpdateStatement(
      tableName: tableName,
      assignments: assignments,
      whereClause: where,
    );
  }

  AssignmentClause _parseAssignment() {
    final col = _parseColumnName();
    _consume(TokenType.opEq, errorMessage: 'Expected = in assignment');
    final value = _parseExpression();
    return AssignmentClause(columnName: col, value: value);
  }

  // ===========================================================================
  // DELETE
  // ===========================================================================

  DeleteStatement _parseDelete() {
    _consume(TokenType.kwDelete);
    _consume(TokenType.kwFrom, errorMessage: 'Expected FROM after DELETE');
    final tableName = _parseTableName();
    Expression? where;
    if (_match(TokenType.kwWhere) != null) {
      where = _parseExpression();
    }
    return DeleteStatement(tableName: tableName, whereClause: where);
  }

  // ===========================================================================
  // CREATE
  // ===========================================================================

  Statement _parseCreate() {
    _consume(TokenType.kwCreate);

    // CREATE [OR REPLACE] VIEW
    bool orReplace = false;
    if (_check(TokenType.kwOr)) {
      _advance(); // OR
      // Next token should be REPLACE (an identifier-like keyword)
      if (_peek().lexeme.toUpperCase() == 'REPLACE') {
        _advance();
        orReplace = true;
      }
    }
    if (_check(TokenType.kwView)) {
      return _parseCreateView(orReplace: orReplace);
    }

    // CREATE TRIGGER
    if (_check(TokenType.kwTrigger)) {
      return _parseCreateTrigger();
    }

    // CREATE [UNIQUE|SPATIAL] INDEX
    bool isUnique = false;
    bool isSpatial = false;
    if (_match(TokenType.kwUnique) != null) {
      isUnique = true;
    } else if (_match(TokenType.kwSpatial) != null) {
      isSpatial = true;
    }
    if (_check(TokenType.kwIndex)) {
      return _parseCreateIndex(isUnique: isUnique, isSpatial: isSpatial);
    }
    if (isUnique || isSpatial) {
      throw _error('Expected INDEX after UNIQUE or SPATIAL');
    }

    _consume(
      TokenType.kwTable,
      errorMessage: 'Expected TABLE, VIEW, TRIGGER, or INDEX after CREATE',
    );
    bool ifNotExists = false;
    if (_checkSequence([TokenType.kwIf, TokenType.kwNot, TokenType.kwExists])) {
      _advance();
      _advance();
      _advance();
      ifNotExists = true;
    }
    final tableName = _parseTableName();
    _consume(TokenType.lparen);
    final columns = <ColumnDefinitionNode>[];
    final foreignKeys = <ForeignKeyConstraintNode>[];
    final tableConstraints = <TableLevelConstraintNode>[];
    _parseColumnOrConstraint(columns, foreignKeys, tableConstraints);
    while (_match(TokenType.comma) != null) {
      if (_isAtEnd() || _check(TokenType.rparen)) break;
      _parseColumnOrConstraint(columns, foreignKeys, tableConstraints);
    }
    _consume(TokenType.rparen);
    return CreateTableStatement(
      tableName: tableName,
      ifNotExists: ifNotExists,
      columns: columns,
      foreignKeys: foreignKeys,
      tableConstraints: tableConstraints,
    );
  }

  /// CREATE [OR REPLACE] VIEW [IF NOT EXISTS] name AS select
  CreateViewStatement _parseCreateView({bool orReplace = false}) {
    _consume(TokenType.kwView);
    bool ifNotExists = false;
    if (_checkSequence([TokenType.kwIf, TokenType.kwNot, TokenType.kwExists])) {
      _advance();
      _advance();
      _advance();
      ifNotExists = true;
    }
    final viewName = _parseTableName();
    // Expect AS
    if (_peek().lexeme.toUpperCase() != 'AS' && !_check(TokenType.kwAs)) {
      throw _error('Expected AS after view name');
    }
    _advance(); // AS
    final select = _parseSelect();
    return CreateViewStatement(
      viewName: viewName,
      orReplace: orReplace,
      ifNotExists: ifNotExists,
      selectStatement: select,
    );
  }

  void _parseColumnOrConstraint(
    List<ColumnDefinitionNode> columns,
    List<ForeignKeyConstraintNode> foreignKeys,
    List<TableLevelConstraintNode> tableConstraints,
  ) {
    if (_check(TokenType.kwForeign)) {
      foreignKeys.add(_parseForeignKeyConstraint());
    } else if (_check(TokenType.kwPrimary)) {
      // Table-level PRIMARY KEY (col1, col2)
      _advance(); // PRIMARY
      _consume(TokenType.kwKey);
      _consume(TokenType.lparen);
      final cols = <String>[];
      cols.add(_parseColumnName());
      while (_match(TokenType.comma) != null) {
        cols.add(_parseColumnName());
      }
      _consume(TokenType.rparen);
      tableConstraints.add(
        TableLevelConstraintNode(type: 'PRIMARY KEY', columns: cols),
      );
    } else if (_check(TokenType.kwUnique)) {
      // Table-level UNIQUE (col1, col2)
      _advance();
      _consume(TokenType.lparen);
      final cols = <String>[];
      cols.add(_parseColumnName());
      while (_match(TokenType.comma) != null) {
        if (_check(TokenType.rparen)) break;
        cols.add(_parseColumnName());
      }
      _consume(TokenType.rparen);
      tableConstraints.add(
        TableLevelConstraintNode(type: 'UNIQUE', columns: cols),
      );
    } else {
      columns.add(_parseColumnDefinition());
    }
  }

  ColumnDefinitionNode _parseColumnDefinition() {
    final name = _parseColumnName();
    final dataType = _parseDataTypeName();
    bool notNull = false;
    bool primaryKey = false;
    bool unique = false;
    bool autoIncrement = false;
    Expression? defaultValue;
    String? fkTable;
    String? fkColumn;

    bool loop = true;
    while (loop) {
      if (_match(TokenType.kwNot) != null) {
        _consume(TokenType.kwNull_, errorMessage: 'Expected NULL after NOT');
        notNull = true;
      } else if (_check(TokenType.kwPrimary)) {
        _advance();
        _consume(TokenType.kwKey);
        primaryKey = true;
        notNull = true;
      } else if (_check(TokenType.kwAutoincrement)) {
        _advance();
        autoIncrement = true;
      } else if (_match(TokenType.kwUnique) != null) {
        unique = true;
      } else if (_match(TokenType.kwDefault) != null) {
        defaultValue = _parsePrimary();
      } else if (_check(TokenType.kwReferences)) {
        _advance();
        fkTable = _parseTableName();
        if (_check(TokenType.lparen)) {
          _advance();
          fkColumn = _parseColumnName();
          _consume(TokenType.rparen);
        }
      } else {
        loop = false;
      }
    }

    return ColumnDefinitionNode(
      name: name,
      dataType: dataType,
      notNull: notNull,
      primaryKey: primaryKey,
      unique: unique,
      autoIncrement: autoIncrement,
      defaultValue: defaultValue,
      foreignKeyTable: fkTable,
      foreignKeyColumn: fkColumn,
    );
  }

  ForeignKeyConstraintNode _parseForeignKeyConstraint() {
    _consume(TokenType.kwForeign);
    _consume(TokenType.kwKey);
    _consume(TokenType.lparen);
    final cols = <String>[];
    cols.add(_parseColumnName());
    while (_match(TokenType.comma) != null) {
      cols.add(_parseColumnName());
    }
    _consume(TokenType.rparen);
    _consume(
      TokenType.kwReferences,
      errorMessage: 'Expected REFERENCES in FOREIGN KEY',
    );
    final refTable = _parseTableName();
    _consume(TokenType.lparen);
    final refCols = <String>[];
    refCols.add(_parseColumnName());
    while (_match(TokenType.comma) != null) {
      refCols.add(_parseColumnName());
    }
    _consume(TokenType.rparen);
    return ForeignKeyConstraintNode(
      columns: cols,
      referencedTable: refTable,
      referencedColumns: refCols,
    );
  }

  String _parseDataTypeName() {
    final t = _peek();
    if (_isDataTypeToken(t.type)) {
      _advance();
      // Handle VARCHAR(n), CHAR(n) etc.
      if (_check(TokenType.lparen)) {
        _advance();
        while (!_check(TokenType.rparen) && !_isAtEnd()) {
          _advance();
        }
        _consume(TokenType.rparen);
      }
      return t.lexeme.toUpperCase();
    }
    // Allow identifiers as type names too
    if (t.type == TokenType.identifier) {
      _advance();
      if (_check(TokenType.lparen)) {
        _advance();
        while (!_check(TokenType.rparen) && !_isAtEnd()) {
          _advance();
        }
        _consume(TokenType.rparen);
      }
      return t.lexeme.toUpperCase();
    }
    throw _error('Expected data type name');
  }

  bool _isDataTypeToken(TokenType t) {
    return t == TokenType.kwInteger ||
        t == TokenType.kwInt ||
        t == TokenType.kwText ||
        t == TokenType.kwVarchar ||
        t == TokenType.kwReal ||
        t == TokenType.kwFloat ||
        t == TokenType.kwDouble ||
        t == TokenType.kwBlob ||
        t == TokenType.kwBoolean ||
        t == TokenType.kwBool ||
        t == TokenType.kwDatetime ||
        t == TokenType.kwDate;
  }

  // ===========================================================================
  // DROP
  // ===========================================================================

  Statement _parseDrop() {
    _consume(TokenType.kwDrop);
    // DROP VIEW
    if (_check(TokenType.kwView)) {
      _advance(); // VIEW
      bool ifExists = false;
      if (_checkSequence([TokenType.kwIf, TokenType.kwExists])) {
        _advance();
        _advance();
        ifExists = true;
      }
      final viewName = _parseTableName();
      return DropViewStatement(viewName: viewName, ifExists: ifExists);
    }
    // DROP TRIGGER
    if (_check(TokenType.kwTrigger)) {
      _advance(); // TRIGGER
      bool ifExists = false;
      if (_checkSequence([TokenType.kwIf, TokenType.kwExists])) {
        _advance();
        _advance();
        ifExists = true;
      }
      final name = _parseIdentifierOrKeyword();
      return DropTriggerStatement(name: name, ifExists: ifExists);
    }
    // DROP INDEX
    if (_check(TokenType.kwIndex)) {
      _advance(); // INDEX
      bool ifExists = false;
      if (_checkSequence([TokenType.kwIf, TokenType.kwExists])) {
        _advance();
        _advance();
        ifExists = true;
      }
      final indexName = _parseIdentifierOrKeyword();
      String? tableName;
      if (_check(TokenType.kwOn) ||
          (_peek().type == TokenType.identifier &&
              _peek().lexeme.toUpperCase() == 'ON')) {
        _advance(); // ON
        tableName = _parseTableName();
      }
      return DropIndexStatement(
        indexName: indexName,
        tableName: tableName,
        ifExists: ifExists,
      );
    }
    _consume(
      TokenType.kwTable,
      errorMessage: 'Expected TABLE, VIEW, TRIGGER, or INDEX after DROP',
    );
    bool ifExists = false;
    if (_checkSequence([TokenType.kwIf, TokenType.kwExists])) {
      _advance();
      _advance();
      ifExists = true;
    }
    final tableName = _parseTableName();
    return DropTableStatement(tableName: tableName, ifExists: ifExists);
  }

  // ===========================================================================
  // ALTER
  // ===========================================================================

  AlterTableStatement _parseAlter() {
    _consume(TokenType.kwAlter);
    _consume(TokenType.kwTable, errorMessage: 'Expected TABLE after ALTER');
    final tableName = _parseTableName();

    if (_check(TokenType.kwAdd)) {
      _advance();
      _match(TokenType.kwColumn);
      final col = _parseColumnDefinition();
      return AlterTableStatement(
        tableName: tableName,
        action: AlterActionType.addColumn,
        newColumn: col,
      );
    }

    if (_check(TokenType.kwDrop)) {
      _advance();
      _match(TokenType.kwColumn);
      final colName = _parseColumnName();
      return AlterTableStatement(
        tableName: tableName,
        action: AlterActionType.dropColumn,
        targetName: colName,
      );
    }

    if (_check(TokenType.kwRename)) {
      _advance();
      _match(TokenType.kwColumn);
      final oldName = _parseColumnName();
      _consume(TokenType.kwTo, errorMessage: 'Expected TO in RENAME COLUMN');
      final newName = _parseColumnName();
      return AlterTableStatement(
        tableName: tableName,
        action: AlterActionType.renameColumn,
        targetName: oldName,
        newName: newName,
      );
    }

    throw _error('Expected ADD, DROP, or RENAME after ALTER TABLE');
  }

  // ===========================================================================
  // TRANSACTION STATEMENTS
  // ===========================================================================

  /// BEGIN [DEFERRED|IMMEDIATE|EXCLUSIVE] [TRANSACTION|WORK]
  BeginStatement _parseBegin() {
    _consume(TokenType.kwBegin);
    String? mode;
    if (_match(TokenType.kwDeferred) != null) {
      mode = 'DEFERRED';
    } else if (_match(TokenType.kwImmediate) != null) {
      mode = 'IMMEDIATE';
    } else if (_match(TokenType.kwExclusive) != null) {
      mode = 'EXCLUSIVE';
    }
    // Optional TRANSACTION or WORK keyword
    _match(TokenType.kwTransaction);
    _match(TokenType.kwWork);
    return BeginStatement(mode: mode);
  }

  /// COMMIT [TRANSACTION|WORK]
  CommitStatement _parseCommit() {
    _consume(TokenType.kwCommit);
    _match(TokenType.kwTransaction);
    _match(TokenType.kwWork);
    return const CommitStatement();
  }

  /// ROLLBACK [TRANSACTION|WORK] [TO [SAVEPOINT] name]
  RollbackStatement _parseRollback() {
    _consume(TokenType.kwRollback);
    _match(TokenType.kwTransaction);
    _match(TokenType.kwWork);
    String? savepointName;
    if (_match(TokenType.kwTo) != null) {
      _match(TokenType.kwSavepoint); // Optional SAVEPOINT keyword
      savepointName = _parseIdentifierOrKeyword();
    }
    return RollbackStatement(savepointName: savepointName);
  }

  /// SAVEPOINT name
  SavepointStatement _parseSavepoint() {
    _consume(TokenType.kwSavepoint);
    final name = _parseIdentifierOrKeyword();
    return SavepointStatement(name: name);
  }

  /// RELEASE [SAVEPOINT] name
  ReleaseStatement _parseRelease() {
    _consume(TokenType.kwRelease);
    _match(TokenType.kwSavepoint); // Optional SAVEPOINT keyword
    final name = _parseIdentifierOrKeyword();
    return ReleaseStatement(name: name);
  }

  /// Parses the next token as an identifier even if it is a keyword.
  /// Used for savepoint names which can shadow keywords.
  String _parseIdentifierOrKeyword() {
    final t = _advance();
    return t.lexeme;
  }

  // ===========================================================================
  // EXPRESSION PARSING (precedence climbing)
  // ===========================================================================

  Expression _parseExpression() => _parseOr();

  Expression _parseOr() {
    var left = _parseAnd();
    while (_match(TokenType.kwOr) != null) {
      final right = _parseAnd();
      left = BinaryExpression(left: left, operator_: 'OR', right: right);
    }
    return left;
  }

  Expression _parseAnd() {
    var left = _parseNot();
    while (_match(TokenType.kwAnd) != null) {
      final right = _parseNot();
      left = BinaryExpression(left: left, operator_: 'AND', right: right);
    }
    return left;
  }

  Expression _parseNot() {
    if (_match(TokenType.kwNot) != null) {
      final operand = _parseNot();
      return UnaryExpression(operator_: 'NOT', operand: operand);
    }
    return _parseComparison();
  }

  Expression _parseComparison() {
    var left = _parseAdditive();

    // IS [NOT] NULL
    if (_match(TokenType.kwIs) != null) {
      final isNot = _match(TokenType.kwNot) != null;
      _consume(TokenType.kwNull_, errorMessage: 'Expected NULL after IS [NOT]');
      return IsNullExpression(operand: left, isNotNull: isNot);
    }

    // [NOT] BETWEEN
    final notBetween =
        _check(TokenType.kwNot) && _peekAt(1).type == TokenType.kwBetween;
    if (notBetween) {
      _advance(); // NOT
      _advance(); // BETWEEN
      final lower = _parseAdditive();
      _consume(TokenType.kwAnd, errorMessage: 'Expected AND in BETWEEN');
      final upper = _parseAdditive();
      return BetweenExpression(
        operand: left,
        lower: lower,
        upper: upper,
        notBetween: true,
      );
    }
    if (_match(TokenType.kwBetween) != null) {
      final lower = _parseAdditive();
      _consume(TokenType.kwAnd, errorMessage: 'Expected AND in BETWEEN');
      final upper = _parseAdditive();
      return BetweenExpression(operand: left, lower: lower, upper: upper);
    }

    // [NOT] IN (...)
    final notIn = _check(TokenType.kwNot) && _peekAt(1).type == TokenType.kwIn;
    if (notIn) {
      _advance(); // NOT
      _advance(); // IN
      final values = _parseInList();
      return InListExpression(operand: left, values: values, notIn: true);
    }
    if (_match(TokenType.kwIn) != null) {
      final values = _parseInList();
      return InListExpression(operand: left, values: values);
    }

    // LIKE
    if (_match(TokenType.kwLike) != null) {
      final pattern = _parseAdditive();
      return BinaryExpression(left: left, operator_: 'LIKE', right: pattern);
    }
    if (_check(TokenType.kwNot) && _peekAt(1).type == TokenType.kwLike) {
      _advance(); // NOT
      _advance(); // LIKE
      final pattern = _parseAdditive();
      return UnaryExpression(
        operator_: 'NOT',
        operand: BinaryExpression(
          left: left,
          operator_: 'LIKE',
          right: pattern,
        ),
      );
    }

    // Comparison operators
    final ops = {
      TokenType.opEq: '=',
      TokenType.opNeq: '!=',
      TokenType.opLt: '<',
      TokenType.opLte: '<=',
      TokenType.opGt: '>',
      TokenType.opGte: '>=',
    };
    for (final entry in ops.entries) {
      if (_match(entry.key) != null) {
        final right = _parseAdditive();
        return BinaryExpression(
          left: left,
          operator_: entry.value,
          right: right,
        );
      }
    }

    return left;
  }

  List<Expression> _parseInList() {
    _consume(TokenType.lparen);
    final values = <Expression>[];
    values.add(_parseExpression());
    while (_match(TokenType.comma) != null) {
      values.add(_parseExpression());
    }
    _consume(TokenType.rparen);
    return values;
  }

  Expression _parseAdditive() {
    var left = _parseMultiplicative();
    while (true) {
      if (_match(TokenType.opPlus) != null) {
        left = BinaryExpression(
          left: left,
          operator_: '+',
          right: _parseMultiplicative(),
        );
      } else if (_match(TokenType.opMinus) != null) {
        left = BinaryExpression(
          left: left,
          operator_: '-',
          right: _parseMultiplicative(),
        );
      } else {
        break;
      }
    }
    return left;
  }

  Expression _parseMultiplicative() {
    var left = _parseUnary();
    while (true) {
      if (_match(TokenType.opStar) != null) {
        left = BinaryExpression(
          left: left,
          operator_: '*',
          right: _parseUnary(),
        );
      } else if (_match(TokenType.opSlash) != null) {
        left = BinaryExpression(
          left: left,
          operator_: '/',
          right: _parseUnary(),
        );
      } else if (_match(TokenType.opPercent) != null) {
        left = BinaryExpression(
          left: left,
          operator_: '%',
          right: _parseUnary(),
        );
      } else {
        break;
      }
    }
    return left;
  }

  Expression _parseUnary() {
    if (_match(TokenType.opMinus) != null) {
      return UnaryExpression(operator_: '-', operand: _parseUnary());
    }
    if (_match(TokenType.opPlus) != null) {
      return _parseUnary(); // unary + is a no-op
    }
    return _parsePrimary();
  }

  Expression _parsePrimary() {
    final t = _peek();

    // NULL literal
    if (_match(TokenType.kwNull_) != null) {
      return const LiteralExpression(null);
    }
    // TRUE / FALSE
    if (_match(TokenType.kwTrue) != null) {
      return const LiteralExpression(true);
    }
    if (_match(TokenType.kwFalse) != null) {
      return const LiteralExpression(false);
    }
    // Integer literal
    if (t.type == TokenType.litInteger) {
      _advance();
      return LiteralExpression(t.value as int);
    }
    // Float literal
    if (t.type == TokenType.litFloat) {
      _advance();
      return LiteralExpression(t.value as double);
    }
    // String literal
    if (t.type == TokenType.litString) {
      _advance();
      return LiteralExpression(t.value as String);
    }

    // Aggregate functions
    if (_isAggregateFunction(t.type)) {
      return _parseFunctionCall();
    }

    // Subquery in parens: (SELECT ...)
    if (t.type == TokenType.lparen && _peekAt(1).type == TokenType.kwSelect) {
      _advance(); // consume (
      final sub = _parseSelect();
      _consume(TokenType.rparen);
      return SubqueryExpression(sub);
    }

    // Parenthesized expression
    if (_match(TokenType.lparen) != null) {
      final inner = _parseExpression();
      _consume(TokenType.rparen);
      return ParenthesizedExpression(inner);
    }

    // Column reference: [table.]column  OR  generic function call: name(...)
    if (t.type == TokenType.identifier) {
      final name = t.value as String;
      _advance();
      // Generic function call (including ST_* spatial functions)
      if (_check(TokenType.lparen)) {
        return _parseGenericFunctionCall(name.toUpperCase());
      }
      if (_match(TokenType.dot) != null) {
        // Could be table.column or table.function(...)
        final next = _peek();
        if (next.type == TokenType.identifier) {
          final col = next.value as String;
          _advance();
          if (_check(TokenType.lparen)) {
            return _parseGenericFunctionCall(col.toUpperCase());
          }
          return ColumnReferenceExpression(tableAlias: name, columnName: col);
        }
        final colName = _parseColumnName();
        return ColumnReferenceExpression(tableAlias: name, columnName: colName);
      }
      return ColumnReferenceExpression(columnName: name);
    }

    // Keyword used as identifier (e.g. column named "status")
    if (_isKeywordUsableAsIdentifier(t.type)) {
      _advance();
      return ColumnReferenceExpression(columnName: t.lexeme);
    }

    throw _error('Unexpected token "${t.lexeme}" (${t.type}) in expression');
  }

  bool _isKeywordUsableAsIdentifier(TokenType type) {
    // Some keywords are commonly used as column names
    return type == TokenType.kwKey ||
        type == TokenType.kwDate ||
        type == TokenType.kwTo ||
        type == TokenType.kwEnd ||
        type == TokenType.kwAll;
  }

  bool _isAggregateFunction(TokenType type) {
    return type == TokenType.kwCount ||
        type == TokenType.kwSum ||
        type == TokenType.kwAvg ||
        type == TokenType.kwMin ||
        type == TokenType.kwMax;
  }

  Expression _parseFunctionCall() {
    final funcToken = _advance();
    final name = funcToken.lexeme.toUpperCase();
    _consume(
      TokenType.lparen,
      errorMessage: 'Expected ( after function name $name',
    );

    bool distinct = false;
    bool isStar = false;
    Expression? argument;

    if (_check(TokenType.opStar)) {
      _advance();
      isStar = true;
    } else {
      if (_match(TokenType.kwDistinct) != null) distinct = true;
      argument = _parseExpression();
    }

    _consume(
      TokenType.rparen,
      errorMessage: 'Expected ) after function arguments',
    );
    return FunctionCallExpression(
      functionName: name,
      distinct: distinct,
      isStar: isStar,
      argument: argument,
    );
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  String _parseColumnName() {
    final t = _peek();
    if (t.type == TokenType.identifier) {
      _advance();
      return t.value as String;
    }
    // Allow keywords as column names
    if (_isKeywordToken(t.type)) {
      _advance();
      return t.lexeme;
    }
    throw _error('Expected column name, got "${t.lexeme}"');
  }

  String _parseTableName() {
    final t = _peek();
    if (t.type == TokenType.identifier) {
      _advance();
      return t.value as String;
    }
    throw _error('Expected table name, got "${t.lexeme}"');
  }

  bool _isKeywordToken(TokenType type) {
    // Keywords that are commonly used as identifiers
    return type == TokenType.kwKey ||
        type == TokenType.kwDate ||
        type == TokenType.kwAll ||
        type == TokenType.kwEnd ||
        type == TokenType.kwTo ||
        type == TokenType.kwSet ||
        type == TokenType.kwBy;
  }

  int _consumeInt(String errorMessage) {
    final t = _peek();
    if (t.type == TokenType.litInteger) {
      _advance();
      return t.value as int;
    }
    throw _error(errorMessage);
  }

  Token _consume(TokenType expected, {String? errorMessage}) {
    if (_check(expected)) return _advance();
    throw _error(
      errorMessage ??
          'Expected ${expected.name} but got "${_peek().lexeme}" (${_peek().type})',
    );
  }

  Token? _match(TokenType type) {
    if (_check(type)) return _advance();
    return null;
  }

  bool _check(TokenType type) => !_isAtEnd() && _peek().type == type;

  bool _checkSequence(List<TokenType> types) {
    for (int i = 0; i < types.length; i++) {
      if (_peekAt(i).type != types[i]) return false;
    }
    return true;
  }

  Token _peek() => _peekAt(0);

  Token _peekAt(int offset) {
    final idx = _pos + offset;
    if (idx >= _tokens.length) return _tokens.last; // EOF
    return _tokens[idx];
  }

  Token _advance() {
    final t = _tokens[_pos];
    if (_pos < _tokens.length - 1) _pos++;
    return t;
  }

  bool _isAtEnd() => _peek().type == TokenType.eof;

  ParseException _error(String message) {
    final t = _peek();
    return ParseException(message, t.line, t.column);
  }

  // ===========================================================================
  // TRIGGER PARSING
  // ===========================================================================

  CreateTriggerStatement _parseCreateTrigger() {
    _consume(TokenType.kwTrigger);
    bool ifNotExists = false;
    if (_checkSequence([TokenType.kwIf, TokenType.kwNot, TokenType.kwExists])) {
      _advance();
      _advance();
      _advance();
      ifNotExists = true;
    }
    final name = _parseIdentifierOrKeyword();

    // Timing: BEFORE | AFTER | INSTEAD OF
    TriggerTiming timing;
    if (_match(TokenType.kwBefore) != null) {
      timing = TriggerTiming.before;
    } else if (_match(TokenType.kwAfter) != null) {
      timing = TriggerTiming.after;
    } else if (_match(TokenType.kwInsteadOf) != null) {
      // Consume optional 'OF' (tokenized as identifier)
      if (_peek().type == TokenType.identifier &&
          _peek().lexeme.toUpperCase() == 'OF') {
        _advance();
      }
      timing = TriggerTiming.insteadOf;
    } else {
      throw _error('Expected BEFORE, AFTER, or INSTEAD OF in trigger');
    }

    // Event: INSERT | UPDATE [OF col,...] | DELETE
    TriggerEvent event;
    final List<String> updateColumns = [];
    if (_match(TokenType.kwInsert) != null) {
      event = TriggerEvent.insert_;
    } else if (_match(TokenType.kwUpdate) != null) {
      event = TriggerEvent.update_;
      // Optional: OF col1, col2, ...
      if (_peek().type == TokenType.identifier &&
          _peek().lexeme.toUpperCase() == 'OF') {
        _advance(); // OF
        updateColumns.add(_parseColumnName());
        while (_match(TokenType.comma) != null) {
          updateColumns.add(_parseColumnName());
        }
      }
    } else if (_match(TokenType.kwDelete) != null) {
      event = TriggerEvent.delete_;
    } else {
      throw _error('Expected INSERT, UPDATE, or DELETE in trigger');
    }

    // ON tableName
    _consume(TokenType.kwOn, errorMessage: 'Expected ON in trigger');
    final tableName = _parseTableName();

    // FOR EACH ROW  (optional)
    if (_match(TokenType.kwFor) != null) {
      // optional EACH
      if (_check(TokenType.kwEach) ||
          (_peek().type == TokenType.identifier &&
              _peek().lexeme.toUpperCase() == 'EACH')) {
        _advance();
      }
      // optional ROW
      if (_check(TokenType.kwRow) ||
          (_peek().type == TokenType.identifier &&
              _peek().lexeme.toUpperCase() == 'ROW')) {
        _advance();
      }
    }

    // WHEN (expr)  (optional)
    Expression? whenExpr;
    if (_match(TokenType.kwWhen) != null) {
      _consume(TokenType.lparen);
      whenExpr = _parseExpression();
      _consume(TokenType.rparen);
    }

    // BEGIN stmt; ... END
    _consume(TokenType.kwBegin, errorMessage: 'Expected BEGIN in trigger body');
    final body = <Statement>[];
    while (!_isAtEnd() && !_check(TokenType.kwEnd)) {
      while (_match(TokenType.semicolon) != null) {}
      if (_check(TokenType.kwEnd)) break;
      body.add(_parseStatement());
      _match(TokenType.semicolon);
    }
    _consume(
      TokenType.kwEnd,
      errorMessage: 'Expected END to close trigger body',
    );

    return CreateTriggerStatement(
      name: name,
      ifNotExists: ifNotExists,
      timing: timing,
      event: event,
      updateColumns: updateColumns,
      tableName: tableName,
      whenExpr: whenExpr,
      body: body,
    );
  }

  // ===========================================================================
  // INDEX PARSING
  // ===========================================================================

  CreateIndexStatement _parseCreateIndex({
    bool isUnique = false,
    bool isSpatial = false,
  }) {
    _consume(TokenType.kwIndex);
    bool ifNotExists = false;
    if (_checkSequence([TokenType.kwIf, TokenType.kwNot, TokenType.kwExists])) {
      _advance();
      _advance();
      _advance();
      ifNotExists = true;
    }
    final indexName = _parseIdentifierOrKeyword();
    _consume(TokenType.kwOn, errorMessage: 'Expected ON in CREATE INDEX');
    final tableName = _parseTableName();
    _consume(TokenType.lparen);
    final columns = <String>[_parseColumnName()];
    while (_match(TokenType.comma) != null) {
      columns.add(_parseColumnName());
    }
    _consume(TokenType.rparen);
    return CreateIndexStatement(
      indexName: indexName,
      tableName: tableName,
      columns: columns,
      isUnique: isUnique,
      isSpatial: isSpatial,
      ifNotExists: ifNotExists,
    );
  }

  // ===========================================================================
  // QUERY HINT PARSING
  // ===========================================================================

  /// Parses the body text of a /*+ ... */ hint comment into [QueryHint]s.
  List<QueryHint> _parseHintBody(String body) {
    final hints = <QueryHint>[];
    final pattern = RegExp(r'(\w+)\s*(?:\(([^)]*)\))?');
    for (final m in pattern.allMatches(body)) {
      final hintName = m.group(1)!.toUpperCase();
      final argStr = m.group(2) ?? '';
      final args = argStr
          .split(RegExp(r'[\s,]+'))
          .where((s) => s.isNotEmpty)
          .toList();
      switch (hintName) {
        case 'INDEX':
        case 'FORCE_INDEX':
          hints.add(
            QueryHint(
              type: HintType.forceIndex,
              tableName: args.isNotEmpty ? args[0] : null,
              indexName: args.length > 1 ? args[1] : null,
            ),
          );
        case 'NO_INDEX':
          hints.add(
            QueryHint(
              type: HintType.noIndex,
              tableName: args.isNotEmpty ? args[0] : null,
              indexName: args.length > 1 ? args[1] : null,
            ),
          );
        case 'FULL_SCAN':
          hints.add(
            QueryHint(
              type: HintType.fullScan,
              tableName: args.isNotEmpty ? args[0] : null,
            ),
          );
        case 'JOIN_ORDER':
          hints.add(QueryHint(type: HintType.joinOrder, joinOrder: args));
      }
    }
    return hints;
  }

  // ===========================================================================
  // GENERIC FUNCTION CALL
  // ===========================================================================

  /// Parses a generic function call: name(arg1, arg2, ...)
  Expression _parseGenericFunctionCall(String name) {
    _consume(TokenType.lparen);
    if (_match(TokenType.rparen) != null) {
      return FunctionCallExpression(functionName: name, arguments: const []);
    }
    if (_check(TokenType.opStar)) {
      _advance();
      _consume(TokenType.rparen);
      return FunctionCallExpression(functionName: name, isStar: true);
    }
    final bool distinct = _match(TokenType.kwDistinct) != null;
    final args = <Expression>[_parseExpression()];
    while (_match(TokenType.comma) != null) {
      if (_check(TokenType.rparen)) break;
      args.add(_parseExpression());
    }
    _consume(TokenType.rparen);
    if (args.length == 1 && !distinct) {
      return FunctionCallExpression(
        functionName: name,
        distinct: distinct,
        argument: args[0],
      );
    }
    return FunctionCallExpression(
      functionName: name,
      distinct: distinct,
      arguments: args,
    );
  }
}

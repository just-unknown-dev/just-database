// SQL Lexer token types
enum TokenType {
  // --- DDL Keywords ---
  kwCreate,
  kwTable,
  kwDrop,
  kwAlter,
  kwAdd,
  kwColumn,
  kwRename,
  kwTo,
  kwIf,
  kwNot,
  kwExists,

  // --- DML Keywords ---
  kwSelect,
  kwFrom,
  kwWhere,
  kwInsert,
  kwInto,
  kwValues,
  kwUpdate,
  kwSet,
  kwDelete,

  // --- Query clause keywords ---
  kwJoin,
  kwInner,
  kwLeft,
  kwRight,
  kwOuter,
  kwOn,
  kwAs,
  kwOrder,
  kwBy,
  kwGroup,
  kwHaving,
  kwLimit,
  kwOffset,
  kwDistinct,
  kwAll,

  // --- Aggregate function keywords ---
  kwCount,
  kwSum,
  kwAvg,
  kwMin,
  kwMax,

  // --- Data type keywords ---
  kwInteger,
  kwInt,
  kwText,
  kwVarchar,
  kwReal,
  kwFloat,
  kwDouble,
  kwBlob,
  kwBoolean,
  kwBool,
  kwDatetime,
  kwDate,

  // --- Constraint keywords ---
  kwNull_,
  kwPrimary,
  kwKey,
  kwUnique,
  kwDefault,
  kwForeign,
  kwReferences,
  kwAutoincrement,

  // --- View keywords ---
  kwView,

  // --- Trigger keywords ---
  kwTrigger,
  kwBefore,
  kwAfter,
  kwInsteadOf,
  kwFor,
  kwEach,
  kwRow,

  // --- Index keywords ---
  kwIndex,
  kwSpatial,
  kwUsing,

  // --- Hint token ---
  hintComment,

  // --- Transaction keywords ---
  kwBegin,
  kwCommit,
  kwRollback,
  kwSavepoint,
  kwRelease,
  kwTransaction,
  kwWork,
  kwDeferred,
  kwImmediate,
  kwExclusive,

  // --- Logic / comparison keywords ---
  kwAnd,
  kwOr,
  kwIn,
  kwLike,
  kwIs,
  kwBetween,
  kwTrue,
  kwFalse,
  kwCase,
  kwWhen,
  kwThen,
  kwElse,
  kwEnd,

  // --- Literals ---
  litInteger,
  litFloat,
  litString,

  // --- Operators ---
  opEq, // =
  opNeq, // != or <>
  opLt, // <
  opLte, // <=
  opGt, // >
  opGte, // >=
  opPlus, // +
  opMinus, // -
  opStar, // *
  opSlash, // /
  opPercent, // %
  // --- Punctuation ---
  lparen, // (
  rparen, // )
  comma, // ,
  dot, // .
  semicolon, // ;
  // --- Identifier ---
  identifier,

  // --- End of input ---
  eof,
}

/// A single lexical token.
class Token {
  final TokenType type;
  final String lexeme;
  final dynamic value; // parsed: int, double, String, bool, or null
  final int line;
  final int column;

  const Token({
    required this.type,
    required this.lexeme,
    this.value,
    required this.line,
    required this.column,
  });

  @override
  String toString() =>
      'Token($type, "$lexeme"${value != null ? ", value=$value" : ""})';
}

// =============================================================================
// BASE AST NODES
// =============================================================================

abstract class AstNode {
  const AstNode();
}

abstract class Statement extends AstNode {
  const Statement();
}

abstract class Expression extends AstNode {
  const Expression();
}

// =============================================================================
// SUPPORTING VALUE OBJECTS
// =============================================================================

/// A column reference in a SELECT list (e.g. "u.name AS username").
class SelectColumn {
  final Expression? expression; // null only when isStar = true
  final String? alias;
  final bool isStar; // SELECT *
  final String? starTablePrefix; // SELECT t.*

  const SelectColumn({
    this.expression,
    this.alias,
    this.isStar = false,
    this.starTablePrefix,
  });
}

enum JoinType { inner, left, right }

class JoinClause {
  final JoinType type;
  final String tableName;
  final String? alias;
  final Expression condition; // ON expression

  const JoinClause({
    required this.type,
    required this.tableName,
    this.alias,
    required this.condition,
  });
}

class OrderByClause {
  final Expression expression;
  final bool descending;

  const OrderByClause({required this.expression, this.descending = false});
}

class AssignmentClause {
  final String columnName;
  final Expression value;

  const AssignmentClause({required this.columnName, required this.value});
}

/// Column definition inside CREATE TABLE or ALTER TABLE ADD COLUMN.
class ColumnDefinitionNode extends AstNode {
  final String name;
  final String dataType;
  final bool notNull;
  final bool primaryKey;
  final bool unique;
  final bool autoIncrement;
  final Expression? defaultValue;
  final String? foreignKeyTable;
  final String? foreignKeyColumn;

  const ColumnDefinitionNode({
    required this.name,
    required this.dataType,
    this.notNull = false,
    this.primaryKey = false,
    this.unique = false,
    this.autoIncrement = false,
    this.defaultValue,
    this.foreignKeyTable,
    this.foreignKeyColumn,
  });
}

class ForeignKeyConstraintNode extends AstNode {
  final List<String> columns;
  final String referencedTable;
  final List<String> referencedColumns;

  const ForeignKeyConstraintNode({
    required this.columns,
    required this.referencedTable,
    required this.referencedColumns,
  });
}

// =============================================================================
// STATEMENTS
// =============================================================================

class SelectStatement extends Statement {
  final List<SelectColumn> columns;
  final String tableName;
  final String? tableAlias;
  final List<JoinClause> joins;
  final Expression? whereClause;
  final List<String> groupBy;
  final Expression? having;
  final List<OrderByClause> orderBy;
  final int? limit;
  final int? offset;
  final bool distinct;
  final List<QueryHint> hints; // /*+ ... */ optimization hints

  const SelectStatement({
    required this.columns,
    required this.tableName,
    this.tableAlias,
    this.joins = const [],
    this.whereClause,
    this.groupBy = const [],
    this.having,
    this.orderBy = const [],
    this.limit,
    this.offset,
    this.distinct = false,
    this.hints = const [],
  });
}

class InsertStatement extends Statement {
  final String tableName;
  final List<String>? columns; // null → use all schema columns in order
  final List<List<Expression>> valueRows; // supports multi-row insert

  const InsertStatement({
    required this.tableName,
    this.columns,
    required this.valueRows,
  });
}

class UpdateStatement extends Statement {
  final String tableName;
  final List<AssignmentClause> assignments;
  final Expression? whereClause;

  const UpdateStatement({
    required this.tableName,
    required this.assignments,
    this.whereClause,
  });
}

class DeleteStatement extends Statement {
  final String tableName;
  final Expression? whereClause;

  const DeleteStatement({required this.tableName, this.whereClause});
}

class CreateTableStatement extends Statement {
  final String tableName;
  final bool ifNotExists;
  final List<ColumnDefinitionNode> columns;
  final List<ForeignKeyConstraintNode> foreignKeys;
  final List<TableLevelConstraintNode> tableConstraints;

  const CreateTableStatement({
    required this.tableName,
    this.ifNotExists = false,
    required this.columns,
    this.foreignKeys = const [],
    this.tableConstraints = const [],
  });
}

/// Represents a table-level constraint (PRIMARY KEY or UNIQUE).
class TableLevelConstraintNode extends AstNode {
  final String type; // 'PRIMARY KEY' or 'UNIQUE'
  final List<String> columns;

  const TableLevelConstraintNode({required this.type, required this.columns});
}

class DropTableStatement extends Statement {
  final String tableName;
  final bool ifExists;

  const DropTableStatement({required this.tableName, this.ifExists = false});
}

enum AlterActionType { addColumn, dropColumn, renameColumn }

class AlterTableStatement extends Statement {
  final String tableName;
  final AlterActionType action;
  final ColumnDefinitionNode? newColumn;
  final String? targetName; // column to drop or rename (old name)
  final String? newName; // for renameColumn (new name)

  const AlterTableStatement({
    required this.tableName,
    required this.action,
    this.newColumn,
    this.targetName,
    this.newName,
  });
}

/// BEGIN [DEFERRED|IMMEDIATE|EXCLUSIVE] [TRANSACTION|WORK]
class BeginStatement extends Statement {
  /// Optional isolation modifier: 'DEFERRED', 'IMMEDIATE', or 'EXCLUSIVE'.
  final String? mode;

  const BeginStatement({this.mode});
}

/// COMMIT [TRANSACTION|WORK]
class CommitStatement extends Statement {
  const CommitStatement();
}

/// ROLLBACK [TRANSACTION|WORK] [TO [SAVEPOINT] name]
class RollbackStatement extends Statement {
  /// Non-null when rolling back to a savepoint.
  final String? savepointName;

  const RollbackStatement({this.savepointName});
}

/// SAVEPOINT name
class SavepointStatement extends Statement {
  final String name;

  const SavepointStatement({required this.name});
}

/// RELEASE [SAVEPOINT] name
class ReleaseStatement extends Statement {
  final String name;

  const ReleaseStatement({required this.name});
}

/// CREATE [OR REPLACE] VIEW name AS select_stmt
class CreateViewStatement extends Statement {
  final String viewName;
  final bool orReplace;
  final bool ifNotExists;
  final SelectStatement selectStatement;

  const CreateViewStatement({
    required this.viewName,
    this.orReplace = false,
    this.ifNotExists = false,
    required this.selectStatement,
  });
}

/// DROP VIEW [IF EXISTS] name
class DropViewStatement extends Statement {
  final String viewName;
  final bool ifExists;

  const DropViewStatement({required this.viewName, this.ifExists = false});
}

// Trigger timing
enum TriggerTiming { before, after, insteadOf }

// Trigger event
enum TriggerEvent { insert_, update_, delete_ }

/// CREATE TRIGGER name {BEFORE|AFTER|INSTEAD OF} {INSERT|UPDATE [OF col,...]|DELETE}
/// ON table FOR EACH ROW [WHEN (expr)] BEGIN stmts END
class CreateTriggerStatement extends Statement {
  final String name;
  final bool ifNotExists;
  final TriggerTiming timing;
  final TriggerEvent event;
  final List<String> updateColumns; // columns for UPDATE OF, empty = all
  final String tableName;
  final Expression? whenExpr;
  final List<Statement> body;

  const CreateTriggerStatement({
    required this.name,
    this.ifNotExists = false,
    required this.timing,
    required this.event,
    this.updateColumns = const [],
    required this.tableName,
    this.whenExpr,
    required this.body,
  });
}

/// DROP TRIGGER [IF EXISTS] name
class DropTriggerStatement extends Statement {
  final String name;
  final bool ifExists;

  const DropTriggerStatement({required this.name, this.ifExists = false});
}

/// CREATE [UNIQUE|SPATIAL] INDEX [IF NOT EXISTS] name ON table (col,...)
class CreateIndexStatement extends Statement {
  final String indexName;
  final String tableName;
  final List<String> columns;
  final bool isUnique;
  final bool isSpatial;
  final bool ifNotExists;

  const CreateIndexStatement({
    required this.indexName,
    required this.tableName,
    required this.columns,
    this.isUnique = false,
    this.isSpatial = false,
    this.ifNotExists = false,
  });
}

/// DROP INDEX [IF EXISTS] name [ON table]
class DropIndexStatement extends Statement {
  final String indexName;
  final String? tableName;
  final bool ifExists;

  const DropIndexStatement({
    required this.indexName,
    this.tableName,
    this.ifExists = false,
  });
}

// Query hint types
enum HintType { forceIndex, noIndex, fullScan, joinOrder }

class QueryHint {
  final HintType type;
  final String? tableName;
  final String? indexName;
  final List<String>? joinOrder;

  const QueryHint({
    required this.type,
    this.tableName,
    this.indexName,
    this.joinOrder,
  });
}

// =============================================================================
// EXPRESSIONS
// =============================================================================

class LiteralExpression extends Expression {
  final dynamic value; // int, double, String, bool, or null

  const LiteralExpression(this.value);
}

class ColumnReferenceExpression extends Expression {
  final String? tableAlias; // e.g. 'u' in u.name
  final String columnName;

  const ColumnReferenceExpression({this.tableAlias, required this.columnName});
}

class BinaryExpression extends Expression {
  final Expression left;
  final String operator_;
  final Expression right;

  const BinaryExpression({
    required this.left,
    required this.operator_,
    required this.right,
  });
}

class UnaryExpression extends Expression {
  final String operator_; // '-', '+', 'NOT'
  final Expression operand;

  const UnaryExpression({required this.operator_, required this.operand});
}

class IsNullExpression extends Expression {
  final Expression operand;
  final bool isNotNull;

  const IsNullExpression({required this.operand, required this.isNotNull});
}

class BetweenExpression extends Expression {
  final Expression operand;
  final Expression lower;
  final Expression upper;
  final bool notBetween;

  const BetweenExpression({
    required this.operand,
    required this.lower,
    required this.upper,
    this.notBetween = false,
  });
}

class InListExpression extends Expression {
  final Expression operand;
  final List<Expression> values;
  final bool notIn;

  const InListExpression({
    required this.operand,
    required this.values,
    this.notIn = false,
  });
}

class FunctionCallExpression extends Expression {
  final String functionName; // 'COUNT', 'SUM', 'AVG', 'MIN', 'MAX', 'ST_*'
  final bool distinct;
  final bool isStar; // COUNT(*) only
  final Expression? argument; // null when isStar = true
  final List<Expression>? arguments; // multi-arg spatial functions

  const FunctionCallExpression({
    required this.functionName,
    this.distinct = false,
    this.isStar = false,
    this.argument,
    this.arguments,
  });

  /// All arguments as a list. Returns [argument] in a list if arguments is null.
  List<Expression> get allArguments {
    if (arguments != null) return arguments!;
    if (argument != null) return [argument!];
    return [];
  }
}

class SubqueryExpression extends Expression {
  final SelectStatement subquery;

  const SubqueryExpression(this.subquery);
}

class ParenthesizedExpression extends Expression {
  final Expression inner;

  const ParenthesizedExpression(this.inner);
}

// =============================================================================
// EXCEPTIONS
// =============================================================================

class ParseException implements Exception {
  final String message;
  final int line;
  final int column;

  ParseException(this.message, this.line, this.column);

  @override
  String toString() => 'ParseException at $line:$column: $message';
}

class ExecutorException implements Exception {
  final String message;

  ExecutorException(this.message);

  @override
  String toString() => 'ExecutorException: $message';
}

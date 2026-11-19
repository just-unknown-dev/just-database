/// The syntax tree the parser builds and the engine compiles.
@internal
library;

import 'package:flutter/foundation.dart' show internal;

import '../storage/schema.dart';

// =============================================================================
// Expressions
// =============================================================================

/// An expression. [start] and [end] are its offsets in the SQL text, which
/// names result columns the way SQLite does.
sealed class Expr {
  Expr(this.start, this.end);

  /// Offsets of the expression in the SQL text.
  final int start, end;
}

/// A literal: NULL, an integer, a real, text or a blob.
final class Literal extends Expr {
  Literal(this.value, super.start, super.end);
  final Object? value;
}

/// `CURRENT_TIME`, `CURRENT_DATE` or `CURRENT_TIMESTAMP`.
final class CurrentTime extends Expr {
  CurrentTime(this.keyword, super.start, super.end);

  /// The keyword, upper case.
  final String keyword;
}

/// A bound parameter. [index] is its 1-based position among the
/// statement's parameters (`?NNN` gives it directly); [name] is set for
/// `:name`, `@name` and `$name`.
final class Param extends Expr {
  Param(this.index, this.name, super.start, super.end);
  final int index;
  final String? name;
}

/// A column reference, `column` or `table.column`.
final class ColumnRef extends Expr {
  ColumnRef(this.table, this.column, super.start, super.end);
  final String? table;
  final String column;
}

/// A prefix operator: `-`, `+`, `~` or `NOT`.
final class Unary extends Expr {
  Unary(this.op, this.operand, super.start, super.end);
  final String op;
  final Expr operand;
}

/// A binary operator: `||`, `*`, `/`, `%`, `+`, `-`, `<<`, `>>`, `&`, `|`,
/// `<`, `<=`, `>`, `>=`, `=`, `!=`, `IS`, `IS NOT`, `AND` or `OR`.
final class Binary extends Expr {
  Binary(this.op, this.left, this.right, super.start, super.end);
  final String op;
  final Expr left, right;
}

/// `expr COLLATE name`.
final class Collate extends Expr {
  Collate(this.expr, this.collation, super.start, super.end);
  final Expr expr;

  /// The collation name, upper case.
  final String collation;
}

/// `x [NOT] LIKE|GLOB pattern [ESCAPE e]`.
final class Like extends Expr {
  Like(
    this.op,
    this.left,
    this.pattern,
    this.escape,
    this.not,
    super.start,
    super.end,
  );

  /// `LIKE` or `GLOB`.
  final String op;
  final Expr left, pattern;
  final Expr? escape;
  final bool not;
}

/// `x [NOT] BETWEEN low AND high`.
final class Between extends Expr {
  Between(this.expr, this.low, this.high, this.not, super.start, super.end);
  final Expr expr, low, high;
  final bool not;
}

/// `x [NOT] IN (a, b, …)`.
final class InList extends Expr {
  InList(this.expr, this.items, this.not, super.start, super.end);
  final Expr expr;
  final List<Expr> items;
  final bool not;
}

/// `x [NOT] IN (SELECT …)`.
final class InSelect extends Expr {
  InSelect(this.expr, this.query, this.not, super.start, super.end);
  final Expr expr;
  final SelectStatement query;
  final bool not;
}

/// `[NOT] EXISTS (SELECT …)`.
final class Exists extends Expr {
  Exists(this.query, this.not, super.start, super.end);
  final SelectStatement query;
  final bool not;
}

/// `(SELECT …)` used as a value.
final class ScalarSubquery extends Expr {
  ScalarSubquery(this.query, super.start, super.end);
  final SelectStatement query;
}

/// `CASE [base] WHEN … THEN … [ELSE …] END`.
final class Case extends Expr {
  Case(this.base, this.whens, this.otherwise, super.start, super.end);
  final Expr? base;
  final List<(Expr, Expr)> whens;
  final Expr? otherwise;
}

/// `CAST(expr AS type)`.
final class Cast extends Expr {
  Cast(this.expr, this.type, super.start, super.end);
  final Expr expr;
  final String type;
}

/// A function call. [name] is upper case. [star] is set for `COUNT(*)`.
final class FunctionCall extends Expr {
  FunctionCall(
    this.name,
    this.args,
    this.distinct,
    this.star,
    super.start,
    super.end,
  );
  final String name;
  final List<Expr> args;
  final bool distinct;
  final bool star;
}

/// How a `RAISE()` in a trigger ends the statement.
enum RaiseKind { ignore, rollback, abort, fail }

/// `RAISE(IGNORE)` or `RAISE(ROLLBACK|ABORT|FAIL, message)`.
final class Raise extends Expr {
  Raise(this.kind, this.message, super.start, super.end);
  final RaiseKind kind;
  final String? message;
}

/// A parenthesised list of values, `(a, b)`, only valid where a row value
/// is (`VALUES`, and `IN` against a two-column subquery is not supported).
final class RowValue extends Expr {
  RowValue(this.items, super.start, super.end);
  final List<Expr> items;
}

// =============================================================================
// SELECT
// =============================================================================

/// A query hint from a `/*+ … */` comment.
enum HintKind { forceIndex, noIndex, fullScan, joinOrder }

/// One query hint: `INDEX(table index)`, `NO_INDEX[(table)]`, `FULL_SCAN`
/// or `JOIN_ORDER(t1, t2, …)`.
final class QueryHint {
  const QueryHint(this.kind, {this.table, this.index, this.order = const []});
  final HintKind kind;
  final String? table;
  final String? index;
  final List<String> order;
}

/// A result column: `*`, `table.*`, or an expression with an optional
/// alias.
sealed class ResultColumn {}

/// `*` or `table.*`.
final class StarColumn extends ResultColumn {
  StarColumn(this.table);
  final String? table;
}

/// `expr [AS alias]`.
final class ExprColumn extends ResultColumn {
  ExprColumn(this.expr, this.alias);
  final Expr expr;
  final String? alias;
}

/// The kinds of join.
enum JoinKind { inner, left, right, full, cross }

/// An item of a FROM clause.
sealed class FromItem {}

/// A table or view by name.
final class TableSource extends FromItem {
  TableSource(this.name, this.alias, this.start, this.end);
  final String name;
  final String? alias;
  final int start, end;
}

/// `(SELECT …) [AS] alias`.
final class SubquerySource extends FromItem {
  SubquerySource(this.query, this.alias);
  final SelectStatement query;
  final String? alias;
}

/// `left [NATURAL] [kind] JOIN right [ON expr | USING (cols)]`. A comma
/// is a cross join.
final class JoinSource extends FromItem {
  JoinSource(
    this.left,
    this.right,
    this.kind,
    this.natural,
    this.on,
    this.using,
  );
  final FromItem left, right;
  final JoinKind kind;
  final bool natural;
  final Expr? on;
  final List<String>? using;
}

/// One SELECT (or VALUES) inside a compound select.
final class SelectCore {
  SelectCore({
    this.distinct = false,
    this.columns = const [],
    this.from,
    this.where,
    this.groupBy = const [],
    this.having,
    this.values,
  });
  final bool distinct;
  final List<ResultColumn> columns;
  final FromItem? from;
  final Expr? where;
  final List<Expr> groupBy;
  final Expr? having;

  /// For `VALUES (…), (…)`: the rows. [columns] is then empty.
  final List<List<Expr>>? values;
}

/// How two selects combine.
enum CompoundOp { union, unionAll, intersect, except }

/// `ORDER BY expr [ASC|DESC] [NULLS FIRST|LAST]`.
final class OrderingTerm {
  OrderingTerm(this.expr, this.descending, this.nullsFirst);
  final Expr expr;
  final bool descending;

  /// Null when not given: NULLs sort first ascending, last descending.
  final bool? nullsFirst;
}

/// A statement. [start] and [end] are its offsets in the SQL text.
sealed class Statement {
  Statement(this.start, this.end);
  final int start, end;
}

/// A SELECT, possibly compound.
final class SelectStatement extends Statement {
  SelectStatement({
    required this.cores,
    required this.ops,
    this.orderBy = const [],
    this.limit,
    this.offset,
    this.hints = const [],
    required int start,
    required int end,
  }) : super(start, end);

  /// The selects; [ops] holds one operator between each pair.
  final List<SelectCore> cores;
  final List<CompoundOp> ops;
  final List<OrderingTerm> orderBy;
  final Expr? limit, offset;
  final List<QueryHint> hints;
}

// =============================================================================
// INSERT, UPDATE, DELETE
// =============================================================================

/// The conflict resolution of `INSERT OR …` / `UPDATE OR …`.
enum ConflictAction { abort, fail, ignore, replace, rollback }

/// `column = expr` in UPDATE and upsert.
final class Assignment {
  Assignment(this.column, this.value);
  final String column;
  final Expr value;
}

/// `ON CONFLICT [(cols)] DO NOTHING | DO UPDATE SET … [WHERE …]`.
final class Upsert {
  Upsert(this.target, this.doNothing, this.sets, this.where);
  final List<String>? target;
  final bool doNothing;
  final List<Assignment> sets;
  final Expr? where;
}

/// `INSERT [OR action] INTO table [(cols)] VALUES … | SELECT … |
/// DEFAULT VALUES [upsert]`.
final class InsertStatement extends Statement {
  InsertStatement({
    required this.conflict,
    required this.table,
    required this.columns,
    this.values,
    this.select,
    this.upsert,
    required int start,
    required int end,
  }) : super(start, end);
  final ConflictAction conflict;
  final String table;
  final List<String>? columns;

  /// Rows of `VALUES`; null for `SELECT` and `DEFAULT VALUES`.
  final List<List<Expr>>? values;

  /// The `SELECT`; null for `VALUES` and `DEFAULT VALUES`.
  final SelectStatement? select;
  final Upsert? upsert;
}

/// `UPDATE [OR action] table SET … [WHERE …]`.
final class UpdateStatement extends Statement {
  UpdateStatement({
    required this.conflict,
    required this.table,
    required this.alias,
    required this.sets,
    required this.where,
    required int start,
    required int end,
  }) : super(start, end);
  final ConflictAction conflict;
  final String table;
  final String? alias;
  final List<Assignment> sets;
  final Expr? where;
}

/// `DELETE FROM table [WHERE …]`.
final class DeleteStatement extends Statement {
  DeleteStatement({
    required this.table,
    required this.alias,
    required this.where,
    required int start,
    required int end,
  }) : super(start, end);
  final String table;
  final String? alias;
  final Expr? where;
}

// =============================================================================
// Schema statements
// =============================================================================

/// A column in CREATE TABLE or ALTER TABLE ADD COLUMN.
final class ColumnSpec {
  ColumnSpec({
    required this.name,
    required this.type,
    this.notNull = false,
    this.primaryKey = false,
    this.descending = false,
    this.autoIncrement = false,
    this.unique = false,
    this.defaultExpr,
    this.defaultSql,
    this.collation,
    this.checks = const [],
    this.references,
  });
  final String name;
  final String type;
  final bool notNull, primaryKey, descending, autoIncrement, unique;
  final Expr? defaultExpr;
  final String? defaultSql;
  final String? collation;

  /// CHECK expressions with their SQL text.
  final List<(Expr, String)> checks;
  final ForeignKeyDefinition? references;
}

/// A table constraint in CREATE TABLE.
final class ConstraintSpec {
  ConstraintSpec({
    required this.kind,
    this.name,
    this.columns = const [],
    this.check,
    this.checkSql,
    this.foreignKey,
  });
  final TableConstraintKind kind;
  final String? name;
  final List<String> columns;
  final Expr? check;
  final String? checkSql;
  final ForeignKeyDefinition? foreignKey;
}

/// `CREATE TABLE [IF NOT EXISTS] name (…)` or `… AS SELECT …`.
final class CreateTableStatement extends Statement {
  CreateTableStatement({
    required this.ifNotExists,
    required this.name,
    this.columns = const [],
    this.constraints = const [],
    this.asSelect,
    required int start,
    required int end,
  }) : super(start, end);
  final bool ifNotExists;
  final String name;
  final List<ColumnSpec> columns;
  final List<ConstraintSpec> constraints;
  final SelectStatement? asSelect;
}

/// `DROP TABLE [IF EXISTS] name`.
final class DropTableStatement extends Statement {
  DropTableStatement(this.ifExists, this.name, super.start, super.end);
  final bool ifExists;
  final String name;
}

/// `ALTER TABLE name RENAME TO new`.
final class RenameTableStatement extends Statement {
  RenameTableStatement(this.table, this.newName, super.start, super.end);
  final String table, newName;
}

/// `ALTER TABLE name RENAME [COLUMN] old TO new`.
final class RenameColumnStatement extends Statement {
  RenameColumnStatement(
    this.table,
    this.column,
    this.newName,
    super.start,
    super.end,
  );
  final String table, column, newName;
}

/// `ALTER TABLE name ADD [COLUMN] spec`.
final class AddColumnStatement extends Statement {
  AddColumnStatement(this.table, this.column, super.start, super.end);
  final String table;
  final ColumnSpec column;
}

/// `ALTER TABLE name DROP [COLUMN] column`.
final class DropColumnStatement extends Statement {
  DropColumnStatement(this.table, this.column, super.start, super.end);
  final String table, column;
}

/// A column of CREATE INDEX.
final class IndexedColumn {
  IndexedColumn(this.name, this.collation, this.descending);
  final String name;
  final String? collation;
  final bool descending;
}

/// `CREATE [UNIQUE | SPATIAL] INDEX [IF NOT EXISTS] name ON table (cols)`.
final class CreateIndexStatement extends Statement {
  CreateIndexStatement({
    required this.unique,
    required this.spatial,
    required this.ifNotExists,
    required this.name,
    required this.table,
    required this.columns,
    required int start,
    required int end,
  }) : super(start, end);
  final bool unique, spatial, ifNotExists;
  final String name, table;
  final List<IndexedColumn> columns;
}

/// `DROP INDEX [IF EXISTS] name`.
final class DropIndexStatement extends Statement {
  DropIndexStatement(this.ifExists, this.name, super.start, super.end);
  final bool ifExists;
  final String name;
}

/// `CREATE VIEW [IF NOT EXISTS] name [(cols)] AS SELECT …`.
final class CreateViewStatement extends Statement {
  CreateViewStatement({
    required this.ifNotExists,
    required this.name,
    required this.columns,
    required this.query,
    required int start,
    required int end,
  }) : super(start, end);
  final bool ifNotExists;
  final String name;
  final List<String>? columns;
  final SelectStatement query;
}

/// `DROP VIEW [IF EXISTS] name`.
final class DropViewStatement extends Statement {
  DropViewStatement(this.ifExists, this.name, super.start, super.end);
  final bool ifExists;
  final String name;
}

/// When a trigger fires.
enum TriggerTiming { before, after, insteadOf }

/// What fires a trigger.
enum TriggerEvent { insert, update, delete }

/// `CREATE TRIGGER [IF NOT EXISTS] name [BEFORE|AFTER|INSTEAD OF]
/// INSERT|UPDATE [OF cols]|DELETE ON table [FOR EACH ROW] [WHEN expr]
/// BEGIN …; END`.
final class CreateTriggerStatement extends Statement {
  CreateTriggerStatement({
    required this.ifNotExists,
    required this.name,
    required this.timing,
    required this.event,
    required this.updateOf,
    required this.table,
    required this.when,
    required this.body,
    required int start,
    required int end,
  }) : super(start, end);
  final bool ifNotExists;
  final String name;
  final TriggerTiming timing;
  final TriggerEvent event;
  final List<String>? updateOf;
  final String table;
  final Expr? when;
  final List<Statement> body;
}

/// `DROP TRIGGER [IF EXISTS] name`.
final class DropTriggerStatement extends Statement {
  DropTriggerStatement(this.ifExists, this.name, super.start, super.end);
  final bool ifExists;
  final String name;
}

// =============================================================================
// Transactions and pragmas
// =============================================================================

/// `BEGIN [DEFERRED | IMMEDIATE | EXCLUSIVE] [TRANSACTION]`.
final class BeginStatement extends Statement {
  BeginStatement(super.start, super.end);
}

/// `COMMIT` / `END [TRANSACTION]`.
final class CommitStatement extends Statement {
  CommitStatement(super.start, super.end);
}

/// `ROLLBACK [TRANSACTION] [TO [SAVEPOINT] name]`.
final class RollbackStatement extends Statement {
  RollbackStatement(this.savepoint, super.start, super.end);
  final String? savepoint;
}

/// `SAVEPOINT name`.
final class SavepointStatement extends Statement {
  SavepointStatement(this.name, super.start, super.end);
  final String name;
}

/// `RELEASE [SAVEPOINT] name`.
final class ReleaseStatement extends Statement {
  ReleaseStatement(this.name, super.start, super.end);
  final String name;
}

/// `PRAGMA name [= value | (value)]`.
final class PragmaStatement extends Statement {
  PragmaStatement(this.name, this.value, super.start, super.end);

  /// The pragma's name, lower case.
  final String name;

  /// The value as written, or null when only reading.
  final String? value;
}

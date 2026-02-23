import 'dart:math' as math;
import '../storage/table.dart';
import '../storage/schema.dart';
import '../storage/database_row.dart';
import '../storage/query_tracker.dart';
import '../storage/index.dart';
import 'ast.dart';
import 'parser.dart';

/// Result of a SQL query or statement execution.
class QueryResult {
  final List<String> columns;
  final List<Map<String, dynamic>> rows;
  final int affectedRows;
  final String? errorMessage;
  final bool success;

  const QueryResult._({
    required this.columns,
    required this.rows,
    required this.affectedRows,
    required this.success,
    this.errorMessage,
  });

  factory QueryResult.success({
    List<String> columns = const [],
    List<Map<String, dynamic>> rows = const [],
    int affectedRows = 0,
  }) => QueryResult._(
    columns: columns,
    rows: rows,
    affectedRows: affectedRows,
    success: true,
  );

  factory QueryResult.error(String message) => QueryResult._(
    columns: const [],
    rows: const [],
    affectedRows: 0,
    success: false,
    errorMessage: message,
  );

  bool get isEmpty => rows.isEmpty;
  int get rowCount => rows.length;

  @override
  String toString() => success
      ? 'QueryResult(rows=${rows.length}, affected=$affectedRows)'
      : 'QueryResult(error=$errorMessage)';
}

/// Executes parsed SQL AST nodes against the in-memory table store.
class Executor {
  /// Reference to the database's table map (shared, mutable).
  final Map<String, Table> _tables;

  /// Query tracker for automatic index creation.
  final QueryTracker queryTracker;

  // ---------------------------------------------------------------------------
  // Transaction (WAL) state
  // ---------------------------------------------------------------------------

  /// Whether a transaction is currently active.
  bool get inTransaction => _txSnapshot != null;

  /// Snapshot of all tables at BEGIN time (used for ROLLBACK).
  Map<String, Table>? _txSnapshot;

  /// Named savepoints created during a transaction.
  /// Maps savepoint name → snapshot of table states at that moment.
  final Map<String, Map<String, Table>> _savepoints = {};

  // ---------------------------------------------------------------------------
  // View store
  // ---------------------------------------------------------------------------

  /// Views keyed by lower-case view name → their SELECT statement.
  final Map<String, SelectStatement> _views = {};

  // ---------------------------------------------------------------------------
  // Trigger store
  // ---------------------------------------------------------------------------

  /// Triggers keyed by lower-case table name → list of trigger definitions.
  final Map<String, List<CreateTriggerStatement>> _triggers = {};

  /// NEW row context active while a trigger body statement is executing.
  Map<String, dynamic>? _triggerNew;

  /// OLD row context active while a trigger body statement is executing.
  Map<String, dynamic>? _triggerOld;

  Executor(this._tables, {QueryTracker? queryTracker})
    : queryTracker = queryTracker ?? QueryTracker();

  /// Parses and executes a SQL string directly.
  Future<QueryResult> executeSQL(String sql) async {
    try {
      final stmt = Parser.parseSQL(sql);
      return await execute(stmt);
    } on ParseException catch (e) {
      return QueryResult.error('Parse error: $e');
    } on ExecutorException catch (e) {
      return QueryResult.error(e.message);
    } catch (e) {
      return QueryResult.error('Error: $e');
    }
  }

  Future<QueryResult> execute(Statement statement) async {
    try {
      if (statement is SelectStatement) return await _executeSelect(statement);
      if (statement is InsertStatement) return await _executeInsert(statement);
      if (statement is UpdateStatement) return await _executeUpdate(statement);
      if (statement is DeleteStatement) return await _executeDelete(statement);
      if (statement is CreateTableStatement) {
        return await _executeCreateTable(statement);
      }
      if (statement is DropTableStatement) {
        return await _executeDropTable(statement);
      }
      if (statement is AlterTableStatement) {
        return await _executeAlterTable(statement);
      }
      if (statement is BeginStatement) return _executeBegin(statement);
      if (statement is CommitStatement) return _executeCommit();
      if (statement is RollbackStatement) return _executeRollback(statement);
      if (statement is SavepointStatement) return _executeSavepoint(statement);
      if (statement is ReleaseStatement) return _executeRelease(statement);
      if (statement is CreateViewStatement) {
        return _executeCreateView(statement);
      }
      if (statement is DropViewStatement) return _executeDropView(statement);
      if (statement is CreateTriggerStatement) {
        return _executeCreateTrigger(statement);
      }
      if (statement is DropTriggerStatement) {
        return _executeDropTrigger(statement);
      }
      if (statement is CreateIndexStatement) {
        return await _executeCreateIndex(statement);
      }
      if (statement is DropIndexStatement) return _executeDropIndex(statement);
      return QueryResult.error(
        'Unknown statement type: ${statement.runtimeType}',
      );
    } on ExecutorException catch (e) {
      return QueryResult.error(e.message);
    } catch (e) {
      return QueryResult.error('Execution error: $e');
    }
  }

  // ===========================================================================
  // SELECT
  // ===========================================================================

  Future<QueryResult> _executeSelect(SelectStatement stmt) async {
    // Handle virtual dual table for scalar SELECT (no real FROM clause).
    // e.g.  SELECT 1+1, UPPER('hello'), ST_MAKEPOINT(1,2)
    if (stmt.tableName == '_dual_') {
      final row = <String, dynamic>{};
      List<Map<String, dynamic>> rows = await _projectColumns(
        [row],
        stmt.columns,
        '_dual_',
      );
      if (stmt.limit != null && stmt.limit == 0) rows = [];
      final colNames = rows.isNotEmpty ? rows.first.keys.toList() : <String>[];
      return QueryResult.success(columns: colNames, rows: rows);
    }

    // Check if this is a view reference; if so, execute the view's query
    // with any additional clauses layered on top.
    final viewKey = stmt.tableName.toLowerCase();
    if (_views.containsKey(viewKey)) {
      return _executeSelectOnView(stmt, _views[viewKey]!);
    }

    final tableKey = _findTableKey(stmt.tableName);
    if (tableKey == null) {
      return QueryResult.error('Table "${stmt.tableName}" does not exist');
    }
    final baseTable = _tables[tableKey]!;
    final baseAlias = stmt.tableAlias ?? tableKey;

    // 1. Scan base table as row contexts
    List<Map<String, dynamic>> rows = _tableToContextRows(baseTable, baseAlias);

    // 2. Apply JOINs
    for (final join in stmt.joins) {
      rows = await _applyJoin(rows, join);
    }

    // 3. Validate referenced columns exist (when rows are present or we can infer schema)
    if (rows.isEmpty) {
      // Build a schema-only context to validate column references
      final schemaCtx = _schemaContext(baseTable);
      final colError = _validateSelectColumns(stmt.columns, schemaCtx);
      if (colError != null) return QueryResult.error(colError);
    } else {
      final colError = _validateSelectColumns(stmt.columns, rows.first);
      if (colError != null) return QueryResult.error(colError);
    }

    // 4. WHERE
    if (stmt.whereClause != null) {
      // Track column usage for automatic indexing
      _trackWhereClauseUsage(stmt.tableName, stmt.whereClause!);

      final filtered = <Map<String, dynamic>>[];
      for (final row in rows) {
        if (await _evaluateAsBool(stmt.whereClause!, row)) {
          filtered.add(row);
        }
      }
      rows = filtered;

      // Check if auto-indexing is needed
      _checkAndCreateAutoIndices(tableKey);
    }

    // 4. GROUP BY + aggregates
    final hasAggregates = stmt.columns.any(
      (c) => c.expression != null && _hasAggregate(c.expression!),
    );
    if (stmt.groupBy.isNotEmpty || hasAggregates) {
      rows = await _applyGroupBy(rows, stmt.groupBy, stmt.having, stmt.columns);
    } else {
      // 5. Project columns (non-aggregate path)
      rows = await _projectColumns(rows, stmt.columns, baseAlias);
    }

    // 6. DISTINCT
    if (stmt.distinct) rows = _applyDistinct(rows);

    // 7. ORDER BY
    if (stmt.orderBy.isNotEmpty) rows = await _applyOrderBy(rows, stmt.orderBy);

    // 8. LIMIT / OFFSET
    rows = _applyLimitOffset(rows, stmt.limit, stmt.offset);

    final colNames = rows.isNotEmpty ? rows.first.keys.toList() : [];
    return QueryResult.success(columns: colNames.cast<String>(), rows: rows);
  }

  /// Converts a [Table]'s rows into row-context maps with both plain and
  /// prefixed keys: "col" and "alias.col".
  List<Map<String, dynamic>> _tableToContextRows(Table table, String alias) {
    return table.scan().map((row) {
      final ctx = <String, dynamic>{};
      for (final entry in row.values.entries) {
        ctx[entry.key] = entry.value;
        ctx['$alias.${entry.key}'] = entry.value;
      }
      return ctx;
    }).toList();
  }

  /// Builds a context map from schema only (for empty tables).
  Map<String, dynamic> _schemaContext(Table table) {
    final ctx = <String, dynamic>{};
    for (final col in table.schema.columns) {
      ctx[col.name] = null;
    }
    return ctx;
  }

  /// Validates that all explicitly referenced columns in SELECT exist in ctx.
  /// Returns an error message string, or null if valid.
  String? _validateSelectColumns(
    List<SelectColumn> columns,
    Map<String, dynamic> ctx,
  ) {
    for (final col in columns) {
      if (col.isStar) continue;
      if (col.expression == null) continue;
      final error = _validateColumnExpr(col.expression!, ctx);
      if (error != null) return error;
    }
    return null;
  }

  /// Recursively validates column references in an expression.
  String? _validateColumnExpr(Expression expr, Map<String, dynamic> ctx) {
    if (expr is ColumnReferenceExpression) {
      // Aggregates/functions skip column validation
      final qualified = expr.tableAlias != null
          ? '${expr.tableAlias}.${expr.columnName}'
          : null;
      if (qualified != null && ctx.containsKey(qualified)) return null;
      if (ctx.containsKey(expr.columnName)) return null;
      // Case-insensitive check
      final lc = expr.columnName.toLowerCase();
      for (final key in ctx.keys) {
        final plainKey = key.contains('.')
            ? key.split('.').last.toLowerCase()
            : key.toLowerCase();
        if (plainKey == lc) return null;
      }
      return 'Column "${expr.columnName}" does not exist';
    }
    if (expr is BinaryExpression) {
      return _validateColumnExpr(expr.left, ctx) ??
          _validateColumnExpr(expr.right, ctx);
    }
    if (expr is UnaryExpression) return _validateColumnExpr(expr.operand, ctx);
    if (expr is ParenthesizedExpression) {
      return _validateColumnExpr(expr.inner, ctx);
    }
    if (expr is FunctionCallExpression) {
      if (expr.argument != null) {
        return _validateColumnExpr(expr.argument!, ctx);
      }
      return null;
    }
    // Literals, SubqueryExpression, etc. are always valid
    return null;
  }

  Future<List<Map<String, dynamic>>> _applyJoin(
    List<Map<String, dynamic>> leftRows,
    JoinClause join,
  ) async {
    final tableKey = _findTableKey(join.tableName);
    if (tableKey == null) {
      throw ExecutorException('Table "${join.tableName}" does not exist');
    }
    final rightTable = _tables[tableKey]!;
    final rightAlias = join.alias ?? tableKey;
    final rightRows = _tableToContextRows(rightTable, rightAlias);

    switch (join.type) {
      case JoinType.inner:
        return await _innerJoin(leftRows, rightRows, join.condition);
      case JoinType.left:
        return await _leftJoin(
          leftRows,
          rightRows,
          join.condition,
          rightTable.schema,
          rightAlias,
        );
      case JoinType.right:
        return await _rightJoin(
          leftRows,
          rightRows,
          join.condition,
          rightTable.schema,
          rightAlias,
        );
    }
  }

  Future<List<Map<String, dynamic>>> _innerJoin(
    List<Map<String, dynamic>> left,
    List<Map<String, dynamic>> right,
    Expression condition,
  ) async {
    final result = <Map<String, dynamic>>[];
    for (final l in left) {
      for (final r in right) {
        final merged = {...l, ...r};
        if (await _evaluateAsBool(condition, merged)) result.add(merged);
      }
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> _leftJoin(
    List<Map<String, dynamic>> left,
    List<Map<String, dynamic>> right,
    Expression condition,
    TableSchema rightSchema,
    String rightAlias,
  ) async {
    final result = <Map<String, dynamic>>[];
    final nullRight = _nullContext(rightSchema, rightAlias);
    for (final l in left) {
      bool matched = false;
      for (final r in right) {
        final merged = {...l, ...r};
        if (await _evaluateAsBool(condition, merged)) {
          result.add(merged);
          matched = true;
        }
      }
      if (!matched) result.add({...l, ...nullRight});
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> _rightJoin(
    List<Map<String, dynamic>> left,
    List<Map<String, dynamic>> right,
    Expression condition,
    TableSchema rightSchema,
    String rightAlias,
  ) async {
    // Right join = flipped left join
    final result = <Map<String, dynamic>>[];
    for (final r in right) {
      bool matched = false;
      for (final l in left) {
        final merged = {...l, ...r};
        if (await _evaluateAsBool(condition, merged)) {
          result.add(merged);
          matched = true;
        }
      }
      if (!matched) {
        // Add null-filled left side - we only have right keys here
        result.add({...r});
      }
    }
    return result;
  }

  Map<String, dynamic> _nullContext(TableSchema schema, String alias) {
    final ctx = <String, dynamic>{};
    for (final col in schema.columns) {
      ctx[col.name] = null;
      ctx['$alias.${col.name}'] = null;
    }
    return ctx;
  }

  Future<List<Map<String, dynamic>>> _applyGroupBy(
    List<Map<String, dynamic>> rows,
    List<String> groupBy,
    Expression? having,
    List<SelectColumn> selectColumns,
  ) async {
    // Group rows by the groupBy keys
    Map<String, List<Map<String, dynamic>>> groups;
    if (groupBy.isEmpty) {
      // No GROUP BY but aggregates exist: treat everything as one group
      groups = {'': rows};
    } else {
      groups = {};
      for (final row in rows) {
        final key = _groupKey(row, groupBy);
        groups.putIfAbsent(key, () => []).add(row);
      }
    }

    final result = <Map<String, dynamic>>[];
    for (final groupRows in groups.values) {
      // Build a representative row with aggregate results
      final outRow = <String, dynamic>{};
      // For empty groups (e.g., aggregate on empty result), we have no representative
      final representative = groupRows.isNotEmpty ? groupRows.first : null;

      for (final selectCol in selectColumns) {
        if (selectCol.isStar) {
          // star in aggregate context: expand
          if (representative != null) {
            outRow.addAll(representative);
          }
          continue;
        }
        final expr = selectCol.expression!;
        final colName =
            selectCol.alias ??
            (representative != null
                ? _inferColumnName(expr, representative)
                : 'expr');

        if (_hasAggregate(expr)) {
          outRow[colName] = await _evaluateAggregate(expr, groupRows);
        } else {
          if (representative != null) {
            outRow[colName] = await _evaluate(expr, representative);
          } else {
            outRow[colName] = null;
          }
        }
      }

      // HAVING filter
      if (having != null) {
        final havingPassed = await _evaluateHaving(having, groupRows, outRow);
        if (!havingPassed) continue;
      }
      result.add(outRow);
    }
    return result;
  }

  /// Evaluates HAVING clause with support for aggregate functions
  Future<bool> _evaluateHaving(
    Expression expr,
    List<Map<String, dynamic>> groupRows,
    Map<String, dynamic> outRow,
  ) async {
    return _toBool(await _evaluateHavingExpr(expr, groupRows, outRow));
  }

  /// Evaluates expressions in HAVING context, supporting aggregates
  Future<dynamic> _evaluateHavingExpr(
    Expression expr,
    List<Map<String, dynamic>> groupRows,
    Map<String, dynamic> outRow,
  ) async {
    // Handle aggregate functions by evaluating on groupRows
    if (expr is FunctionCallExpression) {
      return await _evaluateAggregate(expr, groupRows);
    }

    // Handle binary expressions (AND, OR, comparisons, arithmetic)
    if (expr is BinaryExpression) {
      if (expr.operator_ == 'AND') {
        final l = await _evaluateHavingExpr(expr.left, groupRows, outRow);
        final r = await _evaluateHavingExpr(expr.right, groupRows, outRow);
        return _toBool(l) && _toBool(r);
      }
      if (expr.operator_ == 'OR') {
        final l = await _evaluateHavingExpr(expr.left, groupRows, outRow);
        final r = await _evaluateHavingExpr(expr.right, groupRows, outRow);
        return _toBool(l) || _toBool(r);
      }

      // For all other operators, evaluate both sides
      final l = await _evaluateHavingExpr(expr.left, groupRows, outRow);
      final r = await _evaluateHavingExpr(expr.right, groupRows, outRow);

      switch (expr.operator_) {
        case '=':
          return _eq(l, r);
        case '!=':
          return !_eq(l, r);
        case '<':
          return _compareValues(l, r) < 0;
        case '<=':
          return _compareValues(l, r) <= 0;
        case '>':
          return _compareValues(l, r) > 0;
        case '>=':
          return _compareValues(l, r) >= 0;
        case '+':
          if (l is String || r is String) return '${l ?? ''}${r ?? ''}';
          if (l is int && r is int) return l + r;
          return _toNum(l) + _toNum(r);
        case '-':
          if (l is int && r is int) return l - r;
          return _toNum(l) - _toNum(r);
        case '*':
          if (l is int && r is int) return l * r;
          return _toNum(l) * _toNum(r);
        case '/':
          if (r == 0 || r == 0.0) return null;
          if (l is int && r is int) return l ~/ r;
          return _toNum(l) / _toNum(r);
        case '%':
          if (r == 0 || r == 0.0) return null;
          if (l is int && r is int) return l % r;
          return _toNum(l) % _toNum(r);
        default:
          return null;
      }
    }

    // Handle parenthesized expressions
    if (expr is ParenthesizedExpression) {
      return await _evaluateHavingExpr(expr.inner, groupRows, outRow);
    }

    // For other expressions (literals, column refs), evaluate from outRow context
    return await _evaluate(expr, outRow);
  }

  String _groupKey(Map<String, dynamic> row, List<String> groupBy) {
    return groupBy
        .map((col) {
          final v = _resolveColumn(row, col);
          return v?.toString() ?? 'NULL';
        })
        .join('|');
  }

  dynamic _resolveColumn(Map<String, dynamic> row, String name) {
    if (row.containsKey(name)) return row[name];
    // Try case-insensitive
    for (final key in row.keys) {
      if (key.toLowerCase() == name.toLowerCase()) return row[key];
    }
    // Try without table prefix
    for (final key in row.keys) {
      if (key.contains('.') &&
          key.split('.').last.toLowerCase() == name.toLowerCase()) {
        return row[key];
      }
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> _projectColumns(
    List<Map<String, dynamic>> rows,
    List<SelectColumn> selectColumns,
    String baseAlias,
  ) async {
    if (rows.isEmpty) {
      // Return empty with column names derived from expressions
      return [];
    }

    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final out = <String, dynamic>{};
      for (final col in selectColumns) {
        if (col.isStar) {
          if (col.starTablePrefix != null) {
            // t.*: only include keys prefixed with "t."
            final prefix = '${col.starTablePrefix!}.';
            for (final key in row.keys) {
              if (key.startsWith(prefix)) {
                out[key.substring(prefix.length)] = row[key];
              }
            }
          } else {
            // *: include all keys that DON'T contain a dot (plain column names)
            for (final key in row.keys) {
              if (!key.contains('.')) out[key] = row[key];
            }
          }
        } else {
          final expr = col.expression!;
          final name = col.alias ?? _inferColumnName(expr, row);
          out[name] = await _evaluate(expr, row);
        }
      }
      result.add(out);
    }
    return result;
  }

  String _inferColumnName(Expression expr, Map<String, dynamic> row) {
    if (expr is ColumnReferenceExpression) return expr.columnName;
    if (expr is FunctionCallExpression) {
      if (expr.isStar) return '${expr.functionName}(*)';
      final arg = expr.argument != null
          ? _inferColumnName(expr.argument!, row)
          : '*';
      return '${expr.functionName}($arg)';
    }
    if (expr is LiteralExpression) return expr.value?.toString() ?? 'NULL';
    return 'expr';
  }

  List<Map<String, dynamic>> _applyDistinct(List<Map<String, dynamic>> rows) {
    final seen = <String>[];
    final result = <Map<String, dynamic>>[];
    for (final row in rows) {
      final key = row.values.map((v) => v?.toString() ?? 'NULL').join('|');
      if (!seen.contains(key)) {
        seen.add(key);
        result.add(row);
      }
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> _applyOrderBy(
    List<Map<String, dynamic>> rows,
    List<OrderByClause> orderBy,
  ) async {
    // Pre-compute all sort keys
    final keysPerRow = <List<dynamic>>[];
    for (final row in rows) {
      final keys = <dynamic>[];
      for (final clause in orderBy) {
        keys.add(await _evaluate(clause.expression, row));
      }
      keysPerRow.add(keys);
    }

    // Sort using pre-computed keys
    final indexed = List.generate(rows.length, (i) => i);
    indexed.sort((i, j) {
      final aKeys = keysPerRow[i];
      final bKeys = keysPerRow[j];
      for (var k = 0; k < orderBy.length; k++) {
        final cmp = _compareValues(aKeys[k], bKeys[k]);
        if (cmp != 0) return orderBy[k].descending ? -cmp : cmp;
      }
      return 0;
    });

    return indexed.map((i) => rows[i]).toList();
  }

  List<Map<String, dynamic>> _applyLimitOffset(
    List<Map<String, dynamic>> rows,
    int? limit,
    int? offset,
  ) {
    var result = rows;
    if (offset != null && offset > 0) {
      result = offset < result.length ? result.sublist(offset) : [];
    }
    if (limit != null) {
      result = result.length > limit ? result.sublist(0, limit) : result;
    }
    return result;
  }

  // ===========================================================================
  // INSERT
  // ===========================================================================

  Future<QueryResult> _executeInsert(InsertStatement stmt) async {
    final tableKey = _findTableKey(stmt.tableName);
    if (tableKey == null) {
      return QueryResult.error('Table "${stmt.tableName}" does not exist');
    }
    final table = _tables[tableKey]!;
    int inserted = 0;
    for (final valueRow in stmt.valueRows) {
      final values = <String, dynamic>{};
      if (stmt.columns != null) {
        if (valueRow.length != stmt.columns!.length) {
          return QueryResult.error(
            'Column count mismatch: expected ${stmt.columns!.length}, got ${valueRow.length}',
          );
        }
        for (int i = 0; i < stmt.columns!.length; i++) {
          values[stmt.columns![i]] = await _evaluate(valueRow[i], {});
        }
      } else {
        final cols = table.schema.columns;
        for (int i = 0; i < cols.length && i < valueRow.length; i++) {
          values[cols[i].name] = await _evaluate(valueRow[i], {});
        }
      }
      // Fire BEFORE INSERT triggers
      await _fireTriggers(
        stmt.tableName,
        TriggerEvent.insert_,
        TriggerTiming.before,
        newRow: values,
      );
      final result = table.insert(values);
      if (!result.success) return QueryResult.error(result.errorMessage!);
      // Fire AFTER INSERT triggers
      await _fireTriggers(
        stmt.tableName,
        TriggerEvent.insert_,
        TriggerTiming.after,
        newRow: values,
      );
      inserted++;
    }
    return QueryResult.success(affectedRows: inserted);
  }

  // ===========================================================================
  // UPDATE
  // ===========================================================================

  Future<QueryResult> _executeUpdate(UpdateStatement stmt) async {
    final tableKey = _findTableKey(stmt.tableName);
    if (tableKey == null) {
      return QueryResult.error('Table "${stmt.tableName}" does not exist');
    }
    final table = _tables[tableKey]!;
    final tableAlias = stmt.tableName;

    // Collect the rows that match the WHERE clause first (before any mutation)
    final allRows = table.scan().toList();
    final matchingRows = <DatabaseRow>[];
    for (final row in allRows) {
      if (stmt.whereClause == null) {
        matchingRows.add(row);
      } else {
        if (await _evaluateAsBool(
          stmt.whereClause!,
          _rowToContext(row, tableAlias),
        )) {
          matchingRows.add(row);
        }
      }
    }

    int count = 0;
    for (final row in matchingRows) {
      final ctx = _rowToContext(row, tableAlias);
      final resolved = <String, dynamic>{};
      for (final assign in stmt.assignments) {
        resolved[assign.columnName] = await _evaluate(assign.value, ctx);
      }
      // Build old/new row maps for triggers
      final oldRow = _rowToRawMap(row);
      final newRow = {...oldRow, ...resolved};
      // Fire BEFORE UPDATE triggers
      await _fireTriggers(
        stmt.tableName,
        TriggerEvent.update_,
        TriggerTiming.before,
        oldRow: oldRow,
        newRow: newRow,
      );
      try {
        final updated = table.update((r) => r.rowId == row.rowId, resolved);
        count += updated;
      } catch (e) {
        return QueryResult.error('Update error: $e');
      }
      // Fire AFTER UPDATE triggers
      await _fireTriggers(
        stmt.tableName,
        TriggerEvent.update_,
        TriggerTiming.after,
        oldRow: oldRow,
        newRow: newRow,
      );
    }

    return QueryResult.success(affectedRows: count);
  }

  // ===========================================================================
  // DELETE
  // ===========================================================================

  Future<QueryResult> _executeDelete(DeleteStatement stmt) async {
    final tableKey = _findTableKey(stmt.tableName);
    if (tableKey == null) {
      return QueryResult.error('Table "${stmt.tableName}" does not exist');
    }
    final table = _tables[tableKey]!;
    final tableAlias = stmt.tableName;

    // Collect matching row IDs first
    final allRows = table.scan().toList();
    final toDelete = <int>[];
    for (final row in allRows) {
      if (stmt.whereClause == null) {
        toDelete.add(row.rowId);
      } else {
        if (await _evaluateAsBool(
          stmt.whereClause!,
          _rowToContext(row, tableAlias),
        )) {
          toDelete.add(row.rowId);
        }
      }
    }

    // Delete by rowId
    int count = 0;
    // Save full old row data before deletion, then fire BEFORE DELETE triggers
    final table2 = _tables[tableKey]!;
    // Build a map from rowId → full row data for use in AFTER triggers too
    final oldRowData = <int, Map<String, dynamic>>{};
    for (final rowId in toDelete) {
      final matchingRow = table2
          .scan()
          .where((r) => r.rowId == rowId)
          .firstOrNull;
      if (matchingRow != null) {
        oldRowData[rowId] = _rowToRawMap(matchingRow);
      }
    }
    for (final rowId in toDelete) {
      final oldRow = oldRowData[rowId];
      if (oldRow != null) {
        await _fireTriggers(
          stmt.tableName,
          TriggerEvent.delete_,
          TriggerTiming.before,
          oldRow: oldRow,
        );
      }
    }
    try {
      count = table.delete((row) => toDelete.contains(row.rowId));
    } catch (e) {
      return QueryResult.error('Delete error: $e');
    }
    // Fire AFTER DELETE triggers with full old row data
    for (final rowId in toDelete) {
      final oldRow = oldRowData[rowId] ?? {'rowid': rowId};
      await _fireTriggers(
        stmt.tableName,
        TriggerEvent.delete_,
        TriggerTiming.after,
        oldRow: oldRow,
      );
    }
    return QueryResult.success(affectedRows: count);
  }

  // ===========================================================================
  // DDL
  // ===========================================================================

  Future<QueryResult> _executeCreateTable(CreateTableStatement stmt) async {
    final key = stmt.tableName.toLowerCase();
    if (_tables.containsKey(key)) {
      if (stmt.ifNotExists) return QueryResult.success();
      return QueryResult.error('Table "${stmt.tableName}" already exists');
    }

    final columns = <ColumnDefinition>[];
    for (final colNode in stmt.columns) {
      columns.add(
        ColumnDefinition(
          name: colNode.name,
          type: parseDataType(colNode.dataType),
          constraints: ConstraintDefinition(
            notNull: colNode.notNull,
            primaryKey: colNode.primaryKey,
            unique: colNode.unique,
            autoIncrement: colNode.autoIncrement,
            hasDefault: colNode.defaultValue != null,
            defaultValue: colNode.defaultValue != null
                ? await _evaluate(colNode.defaultValue!, {})
                : null,
            foreignKeyTable: colNode.foreignKeyTable,
            foreignKeyColumn: colNode.foreignKeyColumn,
          ),
        ),
      );
    }

    // Also register table-level FOREIGN KEY constraints
    for (final fk in stmt.foreignKeys) {
      final colIdx = columns.indexWhere(
        (c) => fk.columns
            .map((fc) => fc.toLowerCase())
            .contains(c.name.toLowerCase()),
      );
      if (colIdx >= 0) {
        final col = columns[colIdx];
        columns[colIdx] = col.copyWith(
          constraints: col.constraints.copyWith(
            foreignKeyTable: fk.referencedTable,
            foreignKeyColumn: fk.referencedColumns.isNotEmpty
                ? fk.referencedColumns.first
                : null,
          ),
        );
      }
    }

    // Convert table-level constraints from AST to schema objects
    final tableConstraints = <TableConstraint>[];
    for (final constraintNode in stmt.tableConstraints) {
      if (constraintNode.type == 'PRIMARY KEY') {
        tableConstraints.add(
          TableConstraint(
            type: TableConstraintType.primaryKey,
            columns: constraintNode.columns,
          ),
        );
      } else if (constraintNode.type == 'UNIQUE') {
        tableConstraints.add(
          TableConstraint(
            type: TableConstraintType.unique,
            columns: constraintNode.columns,
          ),
        );
      }
    }

    final schema = TableSchema(
      tableName: stmt.tableName,
      columns: columns,
      tableConstraints: tableConstraints,
    );
    _tables[key] = Table(schema: schema);
    return QueryResult.success();
  }

  Future<QueryResult> _executeDropTable(DropTableStatement stmt) async {
    final key = _findTableKey(stmt.tableName);
    if (key == null) {
      if (stmt.ifExists) return QueryResult.success();
      return QueryResult.error('Table "${stmt.tableName}" does not exist');
    }
    _tables.remove(key);
    return QueryResult.success();
  }

  Future<QueryResult> _executeAlterTable(AlterTableStatement stmt) async {
    final key = _findTableKey(stmt.tableName);
    if (key == null) {
      return QueryResult.error('Table "${stmt.tableName}" does not exist');
    }
    final table = _tables[key]!;
    switch (stmt.action) {
      case AlterActionType.addColumn:
        final colNode = stmt.newColumn!;
        final col = ColumnDefinition(
          name: colNode.name,
          type: parseDataType(colNode.dataType),
          constraints: ConstraintDefinition(
            notNull: colNode.notNull,
            primaryKey: colNode.primaryKey,
            unique: colNode.unique,
            autoIncrement: colNode.autoIncrement,
            hasDefault: colNode.defaultValue != null,
            defaultValue: colNode.defaultValue != null
                ? await _evaluate(colNode.defaultValue!, {})
                : null,
          ),
        );
        table.addColumn(col);
      case AlterActionType.dropColumn:
        table.dropColumn(stmt.targetName!);
      case AlterActionType.renameColumn:
        table.renameColumn(stmt.targetName!, stmt.newName!);
    }
    return QueryResult.success();
  }

  // ===========================================================================
  // TRANSACTION STATEMENTS (WAL)
  // ===========================================================================

  /// Snapshots all current tables so that a ROLLBACK can restore them.
  Map<String, Table> _snapshotTables() =>
      _tables.map((k, v) => MapEntry(k, v.clone()));

  /// BEGIN [DEFERRED|IMMEDIATE|EXCLUSIVE] [TRANSACTION|WORK]
  QueryResult _executeBegin(BeginStatement stmt) {
    if (_txSnapshot != null) {
      return QueryResult.error(
        'Cannot begin: a transaction is already active. '
        'Use COMMIT or ROLLBACK to end the current transaction first.',
      );
    }
    _txSnapshot = _snapshotTables();
    _savepoints.clear();
    return QueryResult.success();
  }

  /// COMMIT [TRANSACTION|WORK] — persists current state; clears undo log.
  QueryResult _executeCommit() {
    if (_txSnapshot == null) {
      return QueryResult.error('Cannot commit: no active transaction.');
    }
    _txSnapshot = null;
    _savepoints.clear();
    return QueryResult.success();
  }

  /// ROLLBACK [TRANSACTION|WORK] [TO [SAVEPOINT] name]
  QueryResult _executeRollback(RollbackStatement stmt) {
    if (_txSnapshot == null) {
      return QueryResult.error('Cannot rollback: no active transaction.');
    }

    if (stmt.savepointName != null) {
      // ROLLBACK TO SAVEPOINT — restore to named savepoint only.
      final spName = stmt.savepointName!;
      final snapshot = _savepoints[spName];
      if (snapshot == null) {
        return QueryResult.error('Savepoint "$spName" does not exist.');
      }
      // Restore all tables to that savepoint.
      _restoreFromSnapshot(snapshot);
      // Remove all savepoints created after this one (we treat the map as
      // ordered; Dart's LinkedHashMap preserves insertion order).
      final keysToRemove = <String>[];
      bool found = false;
      for (final key in _savepoints.keys) {
        if (found) keysToRemove.add(key);
        if (key == spName) found = true;
      }
      for (final k in keysToRemove) {
        _savepoints.remove(k);
      }
      return QueryResult.success();
    }

    // Full ROLLBACK — restore to BEGIN snapshot and end transaction.
    _restoreFromSnapshot(_txSnapshot!);
    _txSnapshot = null;
    _savepoints.clear();
    return QueryResult.success();
  }

  /// Restores the live table map from a snapshot.
  void _restoreFromSnapshot(Map<String, Table> snapshot) {
    // Remove tables created after the snapshot.
    final keysToRemove = _tables.keys
        .where((k) => !snapshot.containsKey(k))
        .toList();
    for (final k in keysToRemove) {
      _tables.remove(k);
    }
    // Restore existing tables.
    for (final entry in snapshot.entries) {
      if (_tables.containsKey(entry.key)) {
        _tables[entry.key]!.restoreFrom(entry.value);
      } else {
        // Table was dropped during the transaction — re-add it.
        _tables[entry.key] = entry.value.clone();
      }
    }
  }

  /// SAVEPOINT name — creates a named restore point within a transaction.
  QueryResult _executeSavepoint(SavepointStatement stmt) {
    if (_txSnapshot == null) {
      return QueryResult.error(
        'Cannot create savepoint: no active transaction.',
      );
    }
    _savepoints[stmt.name] = _snapshotTables();
    return QueryResult.success();
  }

  /// RELEASE [SAVEPOINT] name — discards a savepoint.
  QueryResult _executeRelease(ReleaseStatement stmt) {
    if (_txSnapshot == null) {
      return QueryResult.error(
        'Cannot release savepoint: no active transaction.',
      );
    }
    if (!_savepoints.containsKey(stmt.name)) {
      return QueryResult.error('Savepoint "${stmt.name}" does not exist.');
    }
    _savepoints.remove(stmt.name);
    return QueryResult.success();
  }

  // ===========================================================================
  // VIEWS
  // ===========================================================================

  /// CREATE [OR REPLACE] VIEW [IF NOT EXISTS] name AS select
  QueryResult _executeCreateView(CreateViewStatement stmt) {
    final key = stmt.viewName.toLowerCase();
    final tableExists = _findTableKey(stmt.viewName) != null;
    if (tableExists) {
      return QueryResult.error(
        'Cannot create view "${stmt.viewName}": a table with that name already exists.',
      );
    }
    if (_views.containsKey(key)) {
      if (stmt.ifNotExists) return QueryResult.success();
      if (!stmt.orReplace) {
        return QueryResult.error('View "${stmt.viewName}" already exists.');
      }
    }
    _views[key] = stmt.selectStatement;
    return QueryResult.success();
  }

  /// DROP VIEW [IF EXISTS] name
  QueryResult _executeDropView(DropViewStatement stmt) {
    final key = stmt.viewName.toLowerCase();
    if (!_views.containsKey(key)) {
      if (stmt.ifExists) return QueryResult.success();
      return QueryResult.error('View "${stmt.viewName}" does not exist.');
    }
    _views.remove(key);
    return QueryResult.success();
  }

  /// Executes a SELECT on a view by fully executing the underlying SELECT of
  /// the view and then applying any additional WHERE / ORDER BY / LIMIT from
  /// the outer query on top of the virtual result set.
  Future<QueryResult> _executeSelectOnView(
    SelectStatement outer,
    SelectStatement viewDef,
  ) async {
    // Execute the view's inner SELECT first
    final inner = await _executeSelect(viewDef);
    if (!inner.success) return inner;

    // The inner result is a list of rows. We materialise it as a new virtual
    // Table so that the outer SELECT's WHERE/LIMIT/ORDER BY can be applied.
    // Build column list from the result.
    if (inner.rows.isEmpty &&
        outer.whereClause == null &&
        outer.orderBy.isEmpty &&
        outer.limit == null) {
      // Fast path: no further filtering needed
      final cols = outer.columns.any((c) => c.isStar)
          ? inner.columns
          : outer.columns
                .map(
                  (c) =>
                      c.alias ??
                      (c.expression is ColumnReferenceExpression
                          ? (c.expression as ColumnReferenceExpression)
                                .columnName
                          : 'expr'),
                )
                .toList();
      return QueryResult.success(columns: cols, rows: inner.rows);
    }

    // Apply outer WHERE/ORDER BY/LIMIT on the virtual result rows
    List<Map<String, dynamic>> rows = List.of(inner.rows);

    // Outer alias prefix for the view's columns
    final alias = outer.tableAlias ?? outer.tableName.toLowerCase();
    // Enrich each row with qualified keys if an alias was provided
    if (outer.tableAlias != null) {
      rows = rows.map((r) {
        final enriched = <String, dynamic>{...r};
        for (final entry in r.entries) {
          enriched['$alias.${entry.key}'] = entry.value;
        }
        return enriched;
      }).toList();
    }

    // Apply WHERE
    if (outer.whereClause != null) {
      final filtered = <Map<String, dynamic>>[];
      for (final row in rows) {
        if (await _evaluateAsBool(outer.whereClause!, row)) {
          filtered.add(row);
        }
      }
      rows = filtered;
    }

    // Apply ORDER BY
    if (outer.orderBy.isNotEmpty) {
      rows = await _applyOrderBy(rows, outer.orderBy);
    }

    // Apply LIMIT / OFFSET
    if (outer.offset != null) {
      rows = rows.skip(outer.offset!).toList();
    }
    if (outer.limit != null) {
      rows = rows.take(outer.limit!).toList();
    }

    // Project columns
    List<Map<String, dynamic>> projected;
    List<String> colNames;

    if (outer.columns.length == 1 && outer.columns.first.isStar) {
      projected = rows;
      colNames = inner.columns;
    } else {
      projected = [];
      colNames = [];
      for (final row in rows) {
        final out = <String, dynamic>{};
        for (final col in outer.columns) {
          if (col.isStar) {
            out.addAll(row);
          } else {
            final val = await _evaluate(col.expression!, row);
            final name =
                col.alias ??
                (col.expression is ColumnReferenceExpression
                    ? (col.expression as ColumnReferenceExpression).columnName
                    : 'expr');
            out[name] = val;
          }
        }
        projected.add(out);
      }
      if (rows.isNotEmpty) {
        colNames = projected.first.keys.toList();
      } else {
        colNames = outer.columns.expand<String>((c) {
          if (c.isStar) return inner.columns;
          return [
            c.alias ??
                (c.expression is ColumnReferenceExpression
                    ? (c.expression as ColumnReferenceExpression).columnName
                    : 'expr'),
          ];
        }).toList();
      }
    }

    return QueryResult.success(columns: colNames, rows: projected);
  }

  /// Returns the names of all defined views.
  List<String> get viewNames => List.unmodifiable(_views.keys);

  // ===========================================================================
  // EXPRESSION EVALUATION
  // ===========================================================================

  Future<dynamic> _evaluate(Expression expr, Map<String, dynamic> ctx) async {
    if (expr is LiteralExpression) return expr.value;

    if (expr is ColumnReferenceExpression) {
      final alias = expr.tableAlias?.toLowerCase();
      // Resolve NEW/OLD trigger row references
      if (alias == 'new' && _triggerNew != null) {
        final col = expr.columnName.toLowerCase();
        return _triggerNew![expr.columnName] ??
            _triggerNew!.entries
                .where((e) => e.key.toLowerCase() == col)
                .firstOrNull
                ?.value;
      }
      if (alias == 'old' && _triggerOld != null) {
        final col = expr.columnName.toLowerCase();
        return _triggerOld![expr.columnName] ??
            _triggerOld!.entries
                .where((e) => e.key.toLowerCase() == col)
                .firstOrNull
                ?.value;
      }
      final qualified = expr.tableAlias != null
          ? '${expr.tableAlias}.${expr.columnName}'
          : null;
      if (qualified != null && ctx.containsKey(qualified)) {
        return ctx[qualified];
      }
      if (ctx.containsKey(expr.columnName)) return ctx[expr.columnName];
      // Case-insensitive fallback
      return _resolveColumn(ctx, expr.columnName);
    }

    if (expr is ParenthesizedExpression) {
      return await _evaluate(expr.inner, ctx);
    }

    if (expr is UnaryExpression) {
      final val = await _evaluate(expr.operand, ctx);
      switch (expr.operator_) {
        case '-':
          if (val is int) return -val;
          if (val is double) return -val;
          return null;
        case '+':
          return val;
        case 'NOT':
          return !_toBool(val);
      }
    }

    if (expr is BinaryExpression) {
      return await _evalBinary(expr, ctx);
    }

    if (expr is IsNullExpression) {
      final val = await _evaluate(expr.operand, ctx);
      return expr.isNotNull ? val != null : val == null;
    }

    if (expr is BetweenExpression) {
      final val = await _evaluate(expr.operand, ctx);
      final lower = await _evaluate(expr.lower, ctx);
      final upper = await _evaluate(expr.upper, ctx);
      final inRange =
          _compareValues(val, lower) >= 0 && _compareValues(val, upper) <= 0;
      return expr.notBetween ? !inRange : inRange;
    }

    if (expr is InListExpression) {
      final val = await _evaluate(expr.operand, ctx);
      bool found = false;
      for (final e in expr.values) {
        if (await _evaluate(e, ctx) == val) {
          found = true;
          break;
        }
      }
      return expr.notIn ? !found : found;
    }

    if (expr is FunctionCallExpression) {
      final fn = expr.functionName.toUpperCase();
      // Spatial functions: compute from evaluated arguments
      if (fn.startsWith('ST_')) {
        final args = <dynamic>[];
        for (final a in expr.allArguments) {
          args.add(await _evaluate(a, ctx));
        }
        return _evaluateSpatialFunction(fn, args);
      }
      // Scalar string/math functions callable outside aggregates
      if (fn == 'COALESCE') {
        for (final a in expr.allArguments) {
          final v = await _evaluate(a, ctx);
          if (v != null) return v;
        }
        return null;
      }
      if (fn == 'IFNULL' || fn == 'NVL') {
        final args2 = expr.allArguments;
        if (args2.isEmpty) return null;
        final v = await _evaluate(args2[0], ctx);
        if (v != null) return v;
        if (args2.length > 1) return await _evaluate(args2[1], ctx);
        return null;
      }
      if (fn == 'LENGTH' || fn == 'LEN') {
        final args2 = expr.allArguments;
        if (args2.isEmpty) return null;
        final v = await _evaluate(args2[0], ctx);
        if (v == null) return null;
        return v.toString().length;
      }
      if (fn == 'UPPER') {
        final args2 = expr.allArguments;
        if (args2.isEmpty) return null;
        final v = await _evaluate(args2[0], ctx);
        return v?.toString().toUpperCase();
      }
      if (fn == 'LOWER') {
        final args2 = expr.allArguments;
        if (args2.isEmpty) return null;
        final v = await _evaluate(args2[0], ctx);
        return v?.toString().toLowerCase();
      }
      if (fn == 'SUBSTR' || fn == 'SUBSTRING') {
        final args2 = expr.allArguments;
        if (args2.length < 2) return null;
        final str = (await _evaluate(args2[0], ctx))?.toString() ?? '';
        final start = _toNum(await _evaluate(args2[1], ctx)).toInt();
        if (args2.length >= 3) {
          final len = _toNum(await _evaluate(args2[2], ctx)).toInt();
          final s = (start > 0 ? start - 1 : 0).clamp(0, str.length);
          return str.substring(s, (s + len).clamp(0, str.length));
        }
        final s = (start > 0 ? start - 1 : 0).clamp(0, str.length);
        return str.substring(s);
      }
      if (fn == 'ABS') {
        final args2 = expr.allArguments;
        if (args2.isEmpty) return null;
        final v = await _evaluate(args2[0], ctx);
        if (v is int) return v.abs();
        if (v is double) return v.abs();
        return null;
      }
      if (fn == 'ROUND') {
        final args2 = expr.allArguments;
        if (args2.isEmpty) return null;
        final v = _toNum(await _evaluate(args2[0], ctx));
        final d = args2.length > 1
            ? _toNum(await _evaluate(args2[1], ctx)).toInt()
            : 0;
        if (d == 0) return v.round();
        final factor = math.pow(10.0, d);
        return (v * factor).round() / factor;
      }
      if (fn == 'TRIM') {
        final args2 = expr.allArguments;
        if (args2.isEmpty) return null;
        final v = await _evaluate(args2[0], ctx);
        return v?.toString().trim();
      }
      if (fn == 'REPLACE') {
        final args2 = expr.allArguments;
        if (args2.length < 3) return null;
        final str = (await _evaluate(args2[0], ctx))?.toString() ?? '';
        final from = (await _evaluate(args2[1], ctx))?.toString() ?? '';
        final to2 = (await _evaluate(args2[2], ctx))?.toString() ?? '';
        return str.replaceAll(from, to2);
      }
      if (fn == 'CONCAT') {
        final buf = StringBuffer();
        for (final a in expr.allArguments) {
          final v = await _evaluate(a, ctx);
          if (v != null) buf.write(v);
        }
        return buf.toString();
      }
      throw ExecutorException(
        'Function ${expr.functionName} used outside of aggregate context',
      );
    }

    if (expr is SubqueryExpression) {
      // Execute the sub query and return scalar or list result
      final subResult = await _executeSelect(expr.subquery);
      if (!subResult.success) {
        throw ExecutorException('Subquery failed: ${subResult.errorMessage}');
      }

      // Scalar subquery: return first column of first row
      if (subResult.rows.isEmpty) return null;
      final firstRow = subResult.rows.first;
      if (firstRow.isEmpty) return null;
      return firstRow.values.first;
    }

    return null;
  }

  Future<dynamic> _evalBinary(
    BinaryExpression expr,
    Map<String, dynamic> ctx,
  ) async {
    // Short-circuit for AND/OR
    if (expr.operator_ == 'AND') {
      final l = await _evaluateAsBool(expr.left, ctx);
      return l && await _evaluateAsBool(expr.right, ctx);
    }
    if (expr.operator_ == 'OR') {
      final l = await _evaluateAsBool(expr.left, ctx);
      return l || await _evaluateAsBool(expr.right, ctx);
    }

    final l = await _evaluate(expr.left, ctx);
    final r = await _evaluate(expr.right, ctx);

    switch (expr.operator_) {
      case '=':
        return _eq(l, r);
      case '!=':
        return !_eq(l, r);
      case '<':
        return _compareValues(l, r) < 0;
      case '<=':
        return _compareValues(l, r) <= 0;
      case '>':
        return _compareValues(l, r) > 0;
      case '>=':
        return _compareValues(l, r) >= 0;
      case '+':
        if (l is String || r is String) return '${l ?? ''}${r ?? ''}';
        if (l is int && r is int) return l + r;
        return _toNum(l) + _toNum(r);
      case '-':
        if (l is int && r is int) return l - r;
        return _toNum(l) - _toNum(r);
      case '*':
        if (l is int && r is int) return l * r;
        return _toNum(l) * _toNum(r);
      case '/':
        if (r == 0 || r == 0.0) return null; // division by zero → null
        if (l is int && r is int) return l ~/ r;
        return _toNum(l) / _toNum(r);
      case '%':
        if (r == 0 || r == 0.0) return null;
        if (l is int && r is int) return l % r;
        return _toNum(l) % _toNum(r);
      case 'LIKE':
        if (l == null || r == null) return false;
        return _matchesLike(l.toString(), r.toString());
    }
    return null;
  }

  bool _eq(dynamic a, dynamic b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a is num && b is num) return a.toDouble() == b.toDouble();
    return a == b;
  }

  Future<bool> _evaluateAsBool(
    Expression expr,
    Map<String, dynamic> ctx,
  ) async {
    return _toBool(await _evaluate(expr, ctx));
  }

  bool _toBool(dynamic value) {
    if (value == null) return false;
    if (value is bool) return value;
    if (value is int) return value != 0;
    if (value is double) return value != 0.0;
    if (value is String) return value.isNotEmpty;
    return true;
  }

  num _toNum(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value;
    return double.tryParse(value.toString()) ?? 0;
  }

  /// Evaluates an aggregate function over a list of row-context maps.
  Future<dynamic> _evaluateAggregate(
    Expression expr,
    List<Map<String, dynamic>> group,
  ) async {
    if (expr is FunctionCallExpression) {
      switch (expr.functionName) {
        case 'COUNT':
          if (expr.isStar) return group.length;
          int count = 0;
          for (final row in group) {
            final val = await _evaluate(expr.argument!, row);
            if (val != null) count++;
          }
          return count;
        case 'SUM':
          num sum = 0;
          for (final row in group) {
            final val = await _evaluate(expr.argument!, row);
            if (val != null) sum += _toNum(val);
          }
          return sum;
        case 'AVG':
          if (group.isEmpty) return null;
          num total = 0;
          int count = 0;
          for (final row in group) {
            final val = await _evaluate(expr.argument!, row);
            if (val != null) {
              total += _toNum(val);
              count++;
            }
          }
          return count == 0 ? null : total / count;
        case 'MIN':
          dynamic min;
          for (final row in group) {
            final val = await _evaluate(expr.argument!, row);
            if (val != null && (min == null || _compareValues(val, min) < 0)) {
              min = val;
            }
          }
          return min;
        case 'MAX':
          dynamic max;
          for (final row in group) {
            final val = await _evaluate(expr.argument!, row);
            if (val != null && (max == null || _compareValues(val, max) > 0)) {
              max = val;
            }
          }
          return max;
      }
    }

    // For non-aggregate expressions in an aggregate context, evaluate on first row
    if (group.isNotEmpty) return await _evaluate(expr, group.first);
    return null;
  }

  bool _hasAggregate(Expression expr) {
    if (expr is FunctionCallExpression) return true;
    if (expr is BinaryExpression) {
      return _hasAggregate(expr.left) || _hasAggregate(expr.right);
    }
    if (expr is UnaryExpression) return _hasAggregate(expr.operand);
    if (expr is ParenthesizedExpression) return _hasAggregate(expr.inner);
    return false;
  }

  bool _matchesLike(String value, String pattern) {
    // Convert SQL LIKE pattern to regex
    final buf = StringBuffer('^');
    for (int i = 0; i < pattern.length; i++) {
      final ch = pattern[i];
      if (ch == '%') {
        buf.write('.*');
      } else if (ch == '_') {
        buf.write('.');
      } else {
        // Escape regex metacharacters
        buf.write(RegExp.escape(ch));
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString(), caseSensitive: false).hasMatch(value);
  }

  int _compareValues(dynamic a, dynamic b) {
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;
    if (a is num && b is num) return a.compareTo(b);
    if (a is String && b is String) return a.compareTo(b);
    if (a is DateTime && b is DateTime) return a.compareTo(b);
    if (a is bool && b is bool) return a == b ? 0 : (a ? 1 : -1);
    return a.toString().compareTo(b.toString());
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================

  /// Converts a [DatabaseRow] to an evaluation context map.
  Map<String, dynamic> _rowToContext(DatabaseRow row, String tableAlias) {
    final ctx = <String, dynamic>{};
    for (final entry in row.values.entries) {
      ctx[entry.key] = entry.value;
      ctx['$tableAlias.${entry.key}'] = entry.value;
    }
    return ctx;
  }

  /// Case-insensitive table lookup. Returns the actual map key or null.
  String? _findTableKey(String tableName) {
    final lower = tableName.toLowerCase();
    if (_tables.containsKey(lower)) return lower;
    for (final key in _tables.keys) {
      if (key.toLowerCase() == lower) return key;
    }
    return null;
  }

  // ===========================================================================
  // QUERY TRACKING & AUTO-INDEXING
  // ===========================================================================

  /// Tracks column usage in WHERE clause for automatic index creation.
  void _trackWhereClauseUsage(String tableName, Expression whereExpr) {
    final columns = _extractColumnsFromExpression(whereExpr);

    // Track individual column usage
    for (final col in columns) {
      queryTracker.recordColumnUsage(tableName, col);
    }

    // Track composite usage if multiple columns in AND conditions
    if (columns.length > 1) {
      final andColumns = _extractAndedColumns(whereExpr);
      if (andColumns.length > 1) {
        queryTracker.recordCompositeUsage(tableName, andColumns);
      }
    }
  }

  /// Extracts all column references from an expression.
  Set<String> _extractColumnsFromExpression(Expression expr) {
    final columns = <String>{};

    if (expr is ColumnReferenceExpression) {
      // Strip table alias if present
      final col = expr.columnName.contains('.')
          ? expr.columnName.split('.').last
          : expr.columnName;
      columns.add(col);
    } else if (expr is BinaryExpression) {
      columns.addAll(_extractColumnsFromExpression(expr.left));
      columns.addAll(_extractColumnsFromExpression(expr.right));
    } else if (expr is UnaryExpression) {
      columns.addAll(_extractColumnsFromExpression(expr.operand));
    } else if (expr is ParenthesizedExpression) {
      columns.addAll(_extractColumnsFromExpression(expr.inner));
    }

    return columns;
  }

  /// Extracts columns that are connected by AND operators (for composite tracking).
  List<String> _extractAndedColumns(Expression expr) {
    if (expr is BinaryExpression && expr.operator_ == 'AND') {
      final left = _extractAndedColumns(expr.left);
      final right = _extractAndedColumns(expr.right);
      return [...left, ...right];
    } else if (expr is BinaryExpression &&
        ['=', '>', '<', '>=', '<=', '!='].contains(expr.operator_)) {
      // Comparison with a column
      if (expr.left is ColumnReferenceExpression) {
        final col = (expr.left as ColumnReferenceExpression).columnName;
        final cleanCol = col.contains('.') ? col.split('.').last : col;
        return [cleanCol];
      }
    }
    return [];
  }

  /// Checks if any columns need automatic indexes and creates them.
  void _checkAndCreateAutoIndices(String tableKey) {
    final table = _tables[tableKey];
    if (table == null) return;

    // Check single-column indices
    final columnsNeedingIndex = queryTracker.getColumnsNeedingIndex(tableKey);
    for (final col in columnsNeedingIndex) {
      try {
        table.createAutoIndex(col);
        queryTracker.markColumnIndexed(tableKey, col);
      } catch (e) {
        // Index might already exist, ignore
      }
    }

    // Check composite indices
    final compositesNeedingIndex = queryTracker.getCompositesNeedingIndex(
      tableKey,
    );
    for (final cols in compositesNeedingIndex) {
      try {
        table.createCompositeIndex(cols, IndexType.auto, unique: false);
        queryTracker.markCompositeIndexed(tableKey, cols);
      } catch (e) {
        // Index might already exist, ignore
      }
    }
  }

  // ===========================================================================
  // TRIGGER DDL
  // ===========================================================================

  QueryResult _executeCreateTrigger(CreateTriggerStatement stmt) {
    final tableKey = stmt.tableName.toLowerCase();
    if (!stmt.ifNotExists) {
      final existing = _triggers[tableKey] ?? [];
      if (existing.any(
        (t) => t.name.toLowerCase() == stmt.name.toLowerCase(),
      )) {
        return QueryResult.error('Trigger "${stmt.name}" already exists');
      }
    }
    _triggers.putIfAbsent(tableKey, () => []);
    // Remove existing trigger with same name if IF NOT EXISTS
    _triggers[tableKey]!.removeWhere(
      (t) => t.name.toLowerCase() == stmt.name.toLowerCase(),
    );
    _triggers[tableKey]!.add(stmt);
    return QueryResult.success();
  }

  QueryResult _executeDropTrigger(DropTriggerStatement stmt) {
    final name = stmt.name.toLowerCase();
    bool found = false;
    for (final list in _triggers.values) {
      final before = list.length;
      list.removeWhere((t) => t.name.toLowerCase() == name);
      if (list.length < before) found = true;
    }
    if (!found && !stmt.ifExists) {
      return QueryResult.error('Trigger "${stmt.name}" does not exist');
    }
    return QueryResult.success();
  }

  /// Fires all matching triggers for a table/event/timing combination.
  Future<void> _fireTriggers(
    String tableName,
    TriggerEvent event,
    TriggerTiming timing, {
    Map<String, dynamic>? newRow,
    Map<String, dynamic>? oldRow,
  }) async {
    final tableKey = tableName.toLowerCase();
    final triggers = _triggers[tableKey];
    if (triggers == null || triggers.isEmpty) return;

    for (final trigger in triggers) {
      if (trigger.timing != timing || trigger.event != event) continue;

      // Filter by UPDATE OF columns if specified
      if (event == TriggerEvent.update_ && trigger.updateColumns.isNotEmpty) {
        if (oldRow != null && newRow != null) {
          final changed = trigger.updateColumns.any(
            (c) => oldRow[c] != newRow[c],
          );
          if (!changed) continue;
        }
      }

      // Execute trigger body with NEW/OLD context (set before WHEN eval too)
      final prevNew = _triggerNew;
      final prevOld = _triggerOld;
      _triggerNew = newRow;
      _triggerOld = oldRow;
      try {
        // Evaluate WHEN clause (needs _triggerNew/_triggerOld already set)
        if (trigger.whenExpr != null) {
          final whenCtx = <String, dynamic>{
            if (newRow != null)
              for (final e in newRow.entries) 'new.${e.key}': e.value,
            if (oldRow != null)
              for (final e in oldRow.entries) 'old.${e.key}': e.value,
          };
          final passes = await _evaluateAsBool(trigger.whenExpr!, whenCtx);
          if (!passes) continue;
        }

        for (final stmt in trigger.body) {
          final result = await execute(stmt);
          if (!result.success) {
            throw ExecutorException(
              'Trigger "${trigger.name}" body failed: ${result.errorMessage}',
            );
          }
        }
      } finally {
        _triggerNew = prevNew;
        _triggerOld = prevOld;
      }
    }
  }

  // ===========================================================================
  // INDEX DDL
  // ===========================================================================

  Future<QueryResult> _executeCreateIndex(CreateIndexStatement stmt) async {
    final tableKey = _findTableKey(stmt.tableName);
    if (tableKey == null) {
      return QueryResult.error('Table "${stmt.tableName}" does not exist');
    }
    final table = _tables[tableKey]!;
    final indexType = stmt.isSpatial
        ? IndexType.spatial
        : stmt.isUnique
        ? IndexType.unique
        : IndexType.manual;
    try {
      if (stmt.columns.length == 1) {
        table.createCompositeIndex(
          stmt.columns,
          indexType,
          unique: stmt.isUnique,
          name: stmt.indexName,
        );
      } else {
        table.createCompositeIndex(
          stmt.columns,
          indexType,
          unique: stmt.isUnique,
          name: stmt.indexName,
        );
      }
    } on StateError catch (e) {
      if (stmt.ifNotExists) return QueryResult.success();
      return QueryResult.error(e.message);
    }
    return QueryResult.success();
  }

  QueryResult _executeDropIndex(DropIndexStatement stmt) {
    if (stmt.tableName != null) {
      final tableKey = _findTableKey(stmt.tableName!);
      if (tableKey == null) {
        if (stmt.ifExists) return QueryResult.success();
        return QueryResult.error('Table "${stmt.tableName}" does not exist');
      }
      final dropped = _tables[tableKey]!.dropIndex(stmt.indexName);
      if (!dropped && !stmt.ifExists) {
        return QueryResult.error('Index "${stmt.indexName}" does not exist');
      }
    } else {
      // Search all tables
      bool found = false;
      for (final table in _tables.values) {
        if (table.dropIndex(stmt.indexName)) {
          found = true;
          break;
        }
      }
      if (!found && !stmt.ifExists) {
        return QueryResult.error('Index "${stmt.indexName}" does not exist');
      }
    }
    return QueryResult.success();
  }

  // ===========================================================================
  // SPATIAL FUNCTIONS
  // ===========================================================================

  /// Evaluates an ST_* spatial SQL function.
  dynamic _evaluateSpatialFunction(String fn, List<dynamic> args) {
    switch (fn) {
      case 'ST_MAKEPOINT':
      case 'ST_POINT':
        if (args.length < 2) return null;
        final x = _toNum(args[0]);
        final y = _toNum(args[1]);
        return {'x': x, 'y': y}; // Point as map
      case 'ST_X':
        if (args.isEmpty || args[0] is! Map) return null;
        return _toNum((args[0] as Map)['x']);
      case 'ST_Y':
        if (args.isEmpty || args[0] is! Map) return null;
        return _toNum((args[0] as Map)['y']);
      case 'ST_DISTANCE':
        if (args.length < 2) return null;
        final a = _toPoint(args[0]);
        final b = _toPoint(args[1]);
        if (a == null || b == null) return null;
        final dx = a[0] - b[0];
        final dy = a[1] - b[1];
        return math.sqrt(dx * dx + dy * dy);
      case 'ST_WITHIN':
        if (args.length < 2) return null;
        final pt = _toPoint(args[0]);
        final env = _toBBox(args[1]);
        if (pt == null || env == null) return false;
        return pt[0] >= env[0] &&
            pt[0] <= env[2] &&
            pt[1] >= env[1] &&
            pt[1] <= env[3];
      case 'ST_INTERSECTS':
        if (args.length < 2) return null;
        // For point vs bbox check
        final ptA = _toPoint(args[0]);
        final bboxB = _toBBox(args[1]);
        if (ptA != null && bboxB != null) {
          return ptA[0] >= bboxB[0] &&
              ptA[0] <= bboxB[2] &&
              ptA[1] >= bboxB[1] &&
              ptA[1] <= bboxB[3];
        }
        return false;
      case 'ST_CONTAINS':
        if (args.length < 2) return null;
        final container = _toBBox(args[0]);
        final point = _toPoint(args[1]);
        if (container == null || point == null) return false;
        return point[0] >= container[0] &&
            point[0] <= container[2] &&
            point[1] >= container[1] &&
            point[1] <= container[3];
      case 'ST_ENVELOPE':
      case 'ST_BBOX':
        if (args.isEmpty) return null;
        return args[0]; // Return as-is for bounding box
      default:
        return null;
    }
  }

  /// Extracts [x, y] from a point value (Map or List).
  List<double>? _toPoint(dynamic v) {
    if (v is Map) {
      final x = v['x'] ?? v['lng'] ?? v['lon'];
      final y = v['y'] ?? v['lat'];
      if (x != null && y != null) {
        return [_toNum(x).toDouble(), _toNum(y).toDouble()];
      }
    }
    if (v is List && v.length >= 2) {
      return [_toNum(v[0]).toDouble(), _toNum(v[1]).toDouble()];
    }
    return null;
  }

  /// Extracts [minX, minY, maxX, maxY] bounding box from value.
  List<double>? _toBBox(dynamic v) {
    if (v is Map) {
      final minX = v['minX'] ?? v['min_x'] ?? v['west'];
      final minY = v['minY'] ?? v['min_y'] ?? v['south'];
      final maxX = v['maxX'] ?? v['max_x'] ?? v['east'];
      final maxY = v['maxY'] ?? v['max_y'] ?? v['north'];
      if (minX != null && minY != null && maxX != null && maxY != null) {
        return [
          _toNum(minX).toDouble(),
          _toNum(minY).toDouble(),
          _toNum(maxX).toDouble(),
          _toNum(maxY).toDouble(),
        ];
      }
    }
    if (v is List && v.length >= 4) {
      return [
        _toNum(v[0]).toDouble(),
        _toNum(v[1]).toDouble(),
        _toNum(v[2]).toDouble(),
        _toNum(v[3]).toDouble(),
      ];
    }
    return null;
  }

  // ===========================================================================
  // HELPER
  // ===========================================================================

  /// Converts a DatabaseRow to a plain column→value map.
  Map<String, dynamic> _rowToRawMap(DatabaseRow row) {
    return Map<String, dynamic>.from(row.values);
  }

  /// Returns the names of all triggers across all tables.
  List<String> get triggerNames =>
      _triggers.values.expand((list) => list.map((t) => t.name)).toList();
}

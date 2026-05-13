import 'dart:convert';
import 'dart:io';
import '../storage/table.dart';
import '../storage/schema.dart';
import '../storage/database_row.dart';
import '../sql/parser.dart';
import '../sql/ast.dart';

/// Export and import utilities for backing up and restoring a JustDatabase.
/// All methods are static helpers that operate on the raw table map.
class BackupManager {
  BackupManager._();

  // ---------------------------------------------------------------------------
  // SQL dump / restore
  // ---------------------------------------------------------------------------

  /// Exports all tables as a SQL dump string (CREATE TABLE + INSERT statements).
  static String exportSql(Map<String, Table> tables) {
    final buf = StringBuffer();
    buf.writeln('-- JustDatabase SQL dump');
    buf.writeln('-- Generated: ${DateTime.now().toIso8601String()}');
    buf.writeln();
    for (final entry in tables.entries) {
      final table = entry.value;
      buf.writeln(_buildCreateTable(table));
      for (final row in table.scan()) {
        buf.writeln(_buildInsert(table.schema.tableName, table, row));
      }
      buf.writeln();
    }
    return buf.toString();
  }

  /// Imports from a SQL dump string. Executes each statement against the
  /// provided mutable table map using the full parser+executor pipeline.
  /// Returns the number of statements executed, and throws on parse/exec errors.
  static Future<int> importSql(
    String sql,
    Map<String, Table> tables, {
    bool ignoreErrors = false,
  }) async {
    final stmts = Parser.parseSQLStatements(sql);
    int count = 0;
    for (final stmt in stmts) {
      if (stmt is CreateTableStatement) {
        if (_applyCreateTable(stmt, tables, ignoreErrors)) count++;
      } else if (stmt is InsertStatement) {
        if (_applyInsert(stmt, tables, ignoreErrors)) count++;
      }
    }
    return count;
  }

  // ---------------------------------------------------------------------------
  // JSON backup / restore
  // ---------------------------------------------------------------------------

  /// Exports all tables as a JSON-serialisable map.
  static Map<String, dynamic> exportJson(Map<String, Table> tables) {
    final result = <String, dynamic>{};
    result['_meta'] = {
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'tables': tables.length,
    };
    final tableMap = <String, dynamic>{};
    for (final entry in tables.entries) {
      final table = entry.value;
      final colDefs = table.schema.columns.map((c) {
        final def = <String, dynamic>{
          'name': c.name,
          'type': c.type.name,
          'notNull': c.constraints.notNull,
          'primaryKey': c.constraints.primaryKey,
          'unique': c.constraints.unique,
          'autoIncrement': c.constraints.autoIncrement,
        };
        if (c.constraints.hasDefault) {
          def['default'] = c.constraints.defaultValue;
        }
        if (c.constraints.foreignKeyTable != null) {
          def['fkTable'] = c.constraints.foreignKeyTable;
          def['fkColumn'] = c.constraints.foreignKeyColumn;
        }
        return def;
      }).toList();
      final rows = table
          .scan()
          .map((r) => Map<String, dynamic>.from(r.values))
          .toList();
      tableMap[entry.key] = {
        'schema': {'tableName': table.schema.tableName, 'columns': colDefs},
        'rows': rows,
      };
    }
    result['tables'] = tableMap;
    return result;
  }

  /// Imports tables from a JSON backup map into the given table store.
  static int importJson(
    Map<String, dynamic> json,
    Map<String, Table> tables, {
    bool ignoreErrors = false,
  }) {
    int count = 0;
    final tableMap = json['tables'] as Map<String, dynamic>? ?? {};
    for (final entry in tableMap.entries) {
      final tableKey = entry.key;
      final tableData = entry.value as Map<String, dynamic>;
      try {
        final schemaData = tableData['schema'] as Map<String, dynamic>;
        final tableName = schemaData['tableName'] as String;
        final colsList = (schemaData['columns'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        final columns = colsList.map((c) {
          return ColumnDefinition(
            name: c['name'] as String,
            type: DataType.values.firstWhere(
              (t) => t.name == c['type'],
              orElse: () => DataType.text,
            ),
            constraints: ConstraintDefinition(
              notNull: c['notNull'] as bool? ?? false,
              primaryKey: c['primaryKey'] as bool? ?? false,
              unique: c['unique'] as bool? ?? false,
              autoIncrement: c['autoIncrement'] as bool? ?? false,
              hasDefault: c.containsKey('default'),
              defaultValue: c['default'],
              foreignKeyTable: c['fkTable'] as String?,
              foreignKeyColumn: c['fkColumn'] as String?,
            ),
          );
        }).toList();
        final schema = TableSchema(tableName: tableName, columns: columns);
        final table = tables.putIfAbsent(tableKey, () => Table(schema: schema));
        final rowsList = (tableData['rows'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        for (final rowData in rowsList) {
          table.insert(rowData);
        }
        count++;
      } catch (e) {
        if (!ignoreErrors) rethrow;
      }
    }
    return count;
  }

  // ---------------------------------------------------------------------------
  // File-based helpers
  // ---------------------------------------------------------------------------

  /// Writes a SQL dump to [filePath].
  static Future<void> backupToFile(
    Map<String, Table> tables,
    String filePath,
  ) async {
    final sql = exportSql(tables);
    await File(filePath).writeAsString(sql, encoding: utf8);
  }

  /// Restores from a SQL dump file at [filePath].
  static Future<int> restoreFromFile(
    String filePath,
    Map<String, Table> tables, {
    bool ignoreErrors = false,
  }) async {
    final sql = await File(filePath).readAsString(encoding: utf8);
    return importSql(sql, tables, ignoreErrors: ignoreErrors);
  }

  /// Writes a JSON backup to [filePath].
  static Future<void> backupToJsonFile(
    Map<String, Table> tables,
    String filePath,
  ) async {
    final json = exportJson(tables);
    await File(filePath).writeAsString(
      const JsonEncoder.withIndent('  ').convert(json),
      encoding: utf8,
    );
  }

  /// Restores from a JSON backup file at [filePath].
  static Future<int> restoreFromJsonFile(
    String filePath,
    Map<String, Table> tables, {
    bool ignoreErrors = false,
  }) async {
    final content = await File(filePath).readAsString(encoding: utf8);
    final json = jsonDecode(content) as Map<String, dynamic>;
    return importJson(json, tables, ignoreErrors: ignoreErrors);
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  static String _buildCreateTable(Table table) {
    final buf = StringBuffer();
    buf.write('CREATE TABLE IF NOT EXISTS ${table.schema.tableName} (');
    final cols = table.schema.columns.map((c) {
      final parts = [c.name, c.type.name.toUpperCase()];
      if (c.constraints.primaryKey) parts.add('PRIMARY KEY');
      if (c.constraints.autoIncrement) parts.add('AUTOINCREMENT');
      if (c.constraints.notNull && !c.constraints.primaryKey) {
        parts.add('NOT NULL');
      }
      if (c.constraints.unique && !c.constraints.primaryKey) {
        parts.add('UNIQUE');
      }
      if (c.constraints.hasDefault && c.constraints.defaultValue != null) {
        parts.add('DEFAULT ${_sqlValue(c.constraints.defaultValue)}');
      }
      if (c.constraints.foreignKeyTable != null) {
        parts.add(
          'REFERENCES ${c.constraints.foreignKeyTable}(${c.constraints.foreignKeyColumn ?? 'id'})',
        );
      }
      return parts.join(' ');
    });
    buf.write(cols.join(', '));
    buf.writeln(');');
    return buf.toString();
  }

  static String _buildInsert(String tableName, Table table, DatabaseRow row) {
    final cols = row.values.keys.toList();
    final vals = cols.map((c) => _sqlValue(row.values[c])).join(', ');
    return 'INSERT INTO $tableName (${cols.join(', ')}) VALUES ($vals);';
  }

  static String _sqlValue(dynamic value) {
    if (value == null) return 'NULL';
    if (value is int || value is double) return value.toString();
    if (value is bool) return value ? '1' : '0';
    if (value is DateTime) return "'${value.toIso8601String()}'";
    // Escape single quotes
    return "'${value.toString().replaceAll("'", "''")}'";
  }

  static bool _applyCreateTable(
    CreateTableStatement stmt,
    Map<String, Table> tables,
    bool ignoreErrors,
  ) {
    try {
      final key = stmt.tableName.toLowerCase();
      if (tables.containsKey(key)) {
        if (stmt.ifNotExists) return false;
        if (ignoreErrors) return false;
        throw StateError('Table "${stmt.tableName}" already exists');
      }
      final columns = stmt.columns.map((col) {
        return ColumnDefinition(
          name: col.name,
          type: parseDataType(col.dataType),
          constraints: ConstraintDefinition(
            notNull: col.notNull,
            primaryKey: col.primaryKey,
            unique: col.unique,
            autoIncrement: col.autoIncrement,
            hasDefault: col.defaultValue != null,
            foreignKeyTable: col.foreignKeyTable,
            foreignKeyColumn: col.foreignKeyColumn,
          ),
        );
      }).toList();
      final schema = TableSchema(tableName: stmt.tableName, columns: columns);
      tables[key] = Table(schema: schema);
      return true;
    } catch (e) {
      if (ignoreErrors) return false;
      rethrow;
    }
  }

  static bool _applyInsert(
    InsertStatement stmt,
    Map<String, Table> tables,
    bool ignoreErrors,
  ) {
    try {
      final key = stmt.tableName.toLowerCase();
      final table = tables[key];
      if (table == null) {
        if (ignoreErrors) return false;
        throw StateError('Table "${stmt.tableName}" does not exist');
      }
      for (final valueRow in stmt.valueRows) {
        final values = <String, dynamic>{};
        if (stmt.columns != null) {
          for (int i = 0; i < stmt.columns!.length; i++) {
            values[stmt.columns![i]] = valueRow[i] is LiteralExpression
                ? (valueRow[i] as LiteralExpression).value
                : null;
          }
        }
        table.insert(values);
      }
      return true;
    } catch (e) {
      if (ignoreErrors) return false;
      rethrow;
    }
  }
}

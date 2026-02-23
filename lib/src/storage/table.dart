import 'dart:convert';
import 'dart:typed_data';
import 'schema.dart';
import 'database_row.dart';
import 'index.dart';

/// Result of an INSERT operation.
class InsertResult {
  final bool success;
  final int? rowId;
  final String? errorMessage;

  const InsertResult.success(this.rowId) : success = true, errorMessage = null;

  const InsertResult.error(this.errorMessage) : success = false, rowId = null;
}

/// In-memory table holding rows, a schema, and optional indices.
class Table {
  TableSchema _schema;

  final List<DatabaseRow> _rows = [];
  final Map<int, int> _rowIdToIndex = {}; // rowId → index in _rows
  final Map<String, TableIndex> _indices = {};

  int _nextRowId = 1;
  int _autoIncrementValue = 0;

  Table({required TableSchema schema}) : _schema = schema {
    _initializeIndices();
  }

  /// Initializes all automatic indices for the table.
  void _initializeIndices() {
    // Auto-create composite primary key index if exists
    final pkCols = _schema.primaryKeyColumns;
    if (pkCols.isNotEmpty) {
      if (pkCols.length == 1) {
        // Single-column PK
        _indices[pkCols.first.toLowerCase()] = TableIndex(
          columnName: pkCols.first,
          unique: true,
          type: IndexType.primary,
        );
      } else {
        // Composite PK
        final indexName = 'pk_${pkCols.join("_").toLowerCase()}';
        _indices[indexName] = TableIndex.composite(
          columns: pkCols,
          unique: true,
          type: IndexType.primary,
          name: indexName,
        );
      }
    }

    // Create indices for table-level UNIQUE constraints
    for (final constraint in _schema.tableConstraints) {
      if (constraint.type == TableConstraintType.unique) {
        if (constraint.columns.length == 1) {
          final col = constraint.columns.first;
          final key = col.toLowerCase();
          if (!_indices.containsKey(key)) {
            _indices[key] = TableIndex(
              columnName: col,
              unique: true,
              type: IndexType.unique,
            );
          }
        } else {
          final indexName =
              constraint.name ??
              'unique_${constraint.columns.join("_").toLowerCase()}';
          _indices[indexName] = TableIndex.composite(
            columns: constraint.columns,
            unique: true,
            type: IndexType.unique,
            name: indexName,
          );
        }
      }
    }

    // Create indices for column-level UNIQUE constraints
    for (final col in _schema.columns) {
      final key = col.name.toLowerCase();
      if (col.constraints.unique && !_indices.containsKey(key)) {
        _indices[key] = TableIndex(
          columnName: col.name,
          unique: true,
          type: IndexType.unique,
        );
      }

      // Auto-index foreign key columns
      if (col.constraints.foreignKeyTable != null &&
          !_indices.containsKey(key)) {
        _indices[key] = TableIndex(
          columnName: col.name,
          unique: false,
          type: IndexType.foreign,
          name: 'fk_idx_${col.name.toLowerCase()}',
        );
      }
    }
  }

  TableSchema get schema => _schema;

  /// Returns a deep clone of this table — used by the WAL transaction system
  /// to snapshot state before a transaction begins.
  Table clone() {
    final copy = Table(schema: _schema);
    copy._nextRowId = _nextRowId;
    copy._autoIncrementValue = _autoIncrementValue;
    for (final row in _rows) {
      // DatabaseRow is already immutable: values map is copied by DatabaseRow.copyWith semantics
      // but we can share the same DatabaseRow instances since DatabaseRow is immutable.
      copy._rows.add(row);
      copy._rowIdToIndex[row.rowId] = copy._rows.length - 1;
    }
    return copy;
  }

  /// Restores this table's mutable state from a previously cloned snapshot.
  /// Called during ROLLBACK to undo changes.
  void restoreFrom(Table snapshot) {
    _schema = snapshot._schema;
    _nextRowId = snapshot._nextRowId;
    _autoIncrementValue = snapshot._autoIncrementValue;
    _rows
      ..clear()
      ..addAll(snapshot._rows);
    _rowIdToIndex
      ..clear()
      ..addAll(snapshot._rowIdToIndex);
    // Re-initialise indices from the restored schema
    _indices.clear();
    _initializeIndices();
  }

  // ---------------------------------------------------------------------------
  // INSERT
  // ---------------------------------------------------------------------------

  InsertResult insert(Map<String, dynamic> values) {
    final row = Map<String, dynamic>.from(values);

    // 1. Apply defaults for missing columns
    for (final col in _schema.columns) {
      if (!row.containsKey(col.name)) {
        if (col.constraints.hasDefault) {
          row[col.name] = col.constraints.defaultValue;
        } else if (col.constraints.autoIncrement ||
            col.constraints.primaryKey) {
          row[col.name] = null; // will be assigned below
        } else {
          row[col.name] = null;
        }
      }
    }

    // 2. Handle AUTOINCREMENT for primary key
    final pk = _schema.primaryKeyColumn;
    if (pk != null && (row[pk.name] == null)) {
      _autoIncrementValue++;
      row[pk.name] = _autoIncrementValue;
    }

    // 3. Validate NOT NULL
    for (final col in _schema.columns) {
      if (col.constraints.notNull && row[col.name] == null) {
        return InsertResult.error(
          'NOT NULL constraint failed for column "${col.name}"',
        );
      }
    }

    // 4. Validate UNIQUE and PRIMARY KEY (single-column)
    for (final col in _schema.columns) {
      if ((col.constraints.unique || col.constraints.primaryKey) &&
          row[col.name] != null) {
        final idx = _indices[col.name.toLowerCase()];
        if (idx != null && idx.containsValue(row[col.name])) {
          return InsertResult.error(
            'UNIQUE constraint failed for column "${col.name}": value already exists',
          );
        }
      }
    }

    // 4b. Validate composite PRIMARY KEY and UNIQUE constraints
    for (final idx in _indices.values) {
      if (idx.isComposite && idx.unique) {
        final testRow = DatabaseRow(rowId: -1, values: row);
        if (idx.containsValue(testRow)) {
          return InsertResult.error(
            'UNIQUE constraint failed for (${idx.columns.join(", ")}): combination already exists',
          );
        }
      }
    }

    // 5. Coerce types
    for (final col in _schema.columns) {
      if (row.containsKey(col.name) && row[col.name] != null) {
        row[col.name] = _coerce(row[col.name], col.type);
      }
    }

    // 6. Assign row ID and insert
    final rowId = _nextRowId++;
    final newRow = DatabaseRow(rowId: rowId, values: row);
    final index = _rows.length;
    _rows.add(newRow);
    _rowIdToIndex[rowId] = index;
    _addToIndices(newRow);

    return InsertResult.success(rowId);
  }

  // ---------------------------------------------------------------------------
  // UPDATE
  // ---------------------------------------------------------------------------

  int update(
    bool Function(DatabaseRow) predicate,
    Map<String, dynamic> updates,
  ) {
    int count = 0;
    for (int i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (predicate(row)) {
        // Validate UNIQUE constraints on updated columns
        for (final entry in updates.entries) {
          final col = _schema.getColumn(entry.key);
          if (col != null &&
              (col.constraints.unique || col.constraints.primaryKey) &&
              entry.value != null) {
            final idx = _indices[col.name.toLowerCase()];
            if (idx != null) {
              final existingIds = idx.lookup(entry.value);
              // Allow the same row to keep its own value
              if (existingIds.any((id) => id != row.rowId)) {
                throw StateError(
                  'UNIQUE constraint failed for column "${col.name}"',
                );
              }
            }
          }
        }

        // Coerce types
        final coerced = <String, dynamic>{};
        for (final entry in updates.entries) {
          final col = _schema.getColumn(entry.key);
          if (col != null && entry.value != null) {
            coerced[entry.key] = _coerce(entry.value, col.type);
          } else {
            coerced[entry.key] = entry.value;
          }
        }

        final updatedRow = row.copyWith(coerced);
        _removeFromIndices(row);
        _rows[i] = updatedRow;
        _addToIndices(updatedRow);
        count++;
      }
    }
    return count;
  }

  // ---------------------------------------------------------------------------
  // DELETE
  // ---------------------------------------------------------------------------

  int delete(bool Function(DatabaseRow) predicate) {
    final toDelete = _rows.where(predicate).toList();
    for (final row in toDelete) {
      _removeFromIndices(row);
      _rowIdToIndex.remove(row.rowId);
    }
    _rows.removeWhere(predicate);
    // Rebuild rowId→index map after removal
    for (int i = 0; i < _rows.length; i++) {
      _rowIdToIndex[_rows[i].rowId] = i;
    }
    return toDelete.length;
  }

  // ---------------------------------------------------------------------------
  // SCAN / LOOKUP
  // ---------------------------------------------------------------------------

  List<DatabaseRow> scan() => List.unmodifiable(_rows);

  DatabaseRow? getByPrimaryKey(dynamic value) {
    final pk = _schema.primaryKeyColumn;
    if (pk == null) return null;
    final idx = _indices[pk.name.toLowerCase()];
    if (idx == null) return null;
    final ids = idx.lookup(value);
    if (ids.isEmpty) return null;
    return getByRowId(ids.first);
  }

  DatabaseRow? getByRowId(int rowId) {
    final index = _rowIdToIndex[rowId];
    if (index == null) return null;
    return _rows[index];
  }

  // ---------------------------------------------------------------------------
  // SCHEMA MUTATION
  // ---------------------------------------------------------------------------

  void addColumn(ColumnDefinition column) {
    _schema = _schema.addColumn(column);
    // Back-fill existing rows with default or null
    for (int i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (!row.values.containsKey(column.name)) {
        _rows[i] = row.copyWith({
          column.name: column.constraints.hasDefault
              ? column.constraints.defaultValue
              : null,
        });
        _rowIdToIndex[_rows[i].rowId] = i;
      }
    }
    if (column.constraints.unique || column.constraints.primaryKey) {
      final idx = TableIndex(columnName: column.name, unique: true);
      idx.rebuild(_rows);
      _indices[column.name.toLowerCase()] = idx;
    }
  }

  void dropColumn(String columnName) {
    _schema = _schema.dropColumn(columnName);
    _indices.remove(columnName.toLowerCase());
    for (int i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      final updated = Map<String, dynamic>.from(row.values)..remove(columnName);
      _rows[i] = DatabaseRow(rowId: row.rowId, values: updated);
    }
  }

  void renameColumn(String oldName, String newName) {
    _schema = _schema.renameColumn(oldName, newName);
    final idx = _indices.remove(oldName.toLowerCase());
    if (idx != null) _indices[newName.toLowerCase()] = idx;

    for (int i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (row.values.containsKey(oldName)) {
        final updated = Map<String, dynamic>.from(row.values);
        final val = updated.remove(oldName);
        updated[newName] = val;
        _rows[i] = DatabaseRow(rowId: row.rowId, values: updated);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // STATS
  // ---------------------------------------------------------------------------

  int get rowCount => _rows.length;

  /// Rough estimate of serialized size in bytes.
  int get estimatedSizeBytes {
    int total = 0;
    for (final row in _rows) {
      for (final val in row.values.values) {
        if (val == null) {
          total += 4;
        } else if (val is String) {
          total += val.length * 2;
        } else if (val is int || val is double || val is bool) {
          total += 8;
        } else if (val is Uint8List) {
          total += val.length;
        } else if (val is DateTime) {
          total += 24;
        } else {
          total += 16;
        }
      }
    }
    return total + _schema.tableName.length + _schema.columns.length * 32;
  }

  // ---------------------------------------------------------------------------
  // INDEX MANAGEMENT
  // ---------------------------------------------------------------------------

  /// Creates a composite index on the given columns.
  void createCompositeIndex(
    List<String> columns,
    IndexType type, {
    bool unique = false,
    String? name,
  }) {
    final indexName = name ?? 'idx_${columns.join("_").toLowerCase()}';
    if (_indices.containsKey(indexName)) {
      throw StateError('Index "$indexName" already exists');
    }

    final idx = TableIndex.composite(
      columns: columns,
      unique: unique,
      type: type,
      name: indexName,
    );
    idx.rebuild(_rows);
    _indices[indexName] = idx;
  }

  /// Creates a single-column index.
  void createAutoIndex(String columnName) {
    final key = columnName.toLowerCase();
    if (_indices.containsKey(key)) return; // Already indexed

    final idx = TableIndex(
      columnName: columnName,
      unique: false,
      type: IndexType.auto,
      name: 'auto_idx_$key',
    );
    idx.rebuild(_rows);
    _indices[key] = idx;
  }

  /// Drops an index by name. Returns true if removed, false if not found.
  bool dropIndex(String name) {
    final key = name.toLowerCase();
    if (_indices.remove(key) != null) return true;
    // Try matching by metadata name (not key)
    final entry = _indices.entries
        .where((e) => e.value.metadata.name.toLowerCase() == key)
        .firstOrNull;
    if (entry != null) {
      _indices.remove(entry.key);
      return true;
    }
    return false;
  }

  /// Returns all index names on this table.
  List<String> get indexNames => _indices.keys.toList();

  /// Returns the index for the given columns, if it exists.
  TableIndex? getIndexForColumns(List<String> columns) {
    if (columns.isEmpty) return null;

    // Exact match
    for (final idx in _indices.values) {
      if (idx.columns.length == columns.length) {
        bool matches = true;
        for (int i = 0; i < columns.length; i++) {
          if (idx.columns[i].toLowerCase() != columns[i].toLowerCase()) {
            matches = false;
            break;
          }
        }
        if (matches) return idx;
      }
    }

    // For single column, try direct lookup by name
    if (columns.length == 1) {
      return _indices[columns.first.toLowerCase()];
    }

    return null;
  }

  /// Removes an index by name.
  void removeIndex(String name) {
    _indices.remove(name.toLowerCase());
  }

  /// Returns all index metadata.
  List<IndexMetadata> get indexMetadata {
    return _indices.values.map((idx) => idx.metadata).toList();
  }

  // ---------------------------------------------------------------------------
  // SERIALIZATION
  // ---------------------------------------------------------------------------

  /// Serializes table to JSON with rows as ordered arrays for compactness.
  Map<String, dynamic> toJson() {
    final colNames = _schema.columns.map((c) => c.name).toList();
    final rowArrays = _rows.map((row) {
      return colNames.map((name) {
        final v = row.values[name];
        if (v == null) return null;
        if (v is Uint8List) return {'__type': 'blob', 'data': base64.encode(v)};
        if (v is DateTime) {
          return {'__type': 'datetime', 'data': v.toUtc().toIso8601String()};
        }
        return v;
      }).toList();
    }).toList();

    // Serialize index metadata (exclude auto-created indices, keep custom ones)
    final indicesJson = <Map<String, dynamic>>[];
    for (final idx in _indices.values) {
      // Store all indices with their metadata
      indicesJson.add(idx.metadata.toJson());
    }

    return {
      'schema': _schema.toJson(),
      'autoIncrement': _autoIncrementValue,
      'nextRowId': _nextRowId,
      'rows': rowArrays,
      'indices': indicesJson,
    };
  }

  factory Table.fromJson(Map<String, dynamic> json) {
    final schema = TableSchema.fromJson(json['schema'] as Map<String, dynamic>);
    final table = Table(schema: schema);
    table._autoIncrementValue = json['autoIncrement'] as int? ?? 0;
    table._nextRowId = json['nextRowId'] as int? ?? 1;

    final colNames = schema.columns.map((c) => c.name).toList();
    final rows = json['rows'] as List<dynamic>? ?? [];

    for (final rawRow in rows) {
      final arr = rawRow as List<dynamic>;
      final values = <String, dynamic>{};
      for (int i = 0; i < colNames.length && i < arr.length; i++) {
        final v = arr[i];
        if (v == null) {
          values[colNames[i]] = null;
        } else if (v is Map && v['__type'] == 'blob') {
          values[colNames[i]] = base64.decode(v['data'] as String);
        } else if (v is Map && v['__type'] == 'datetime') {
          values[colNames[i]] = DateTime.parse(v['data'] as String);
        } else {
          values[colNames[i]] = v;
        }
      }
      final rowId = table._nextRowId++;
      final row = DatabaseRow(rowId: rowId, values: values);
      final idx = table._rows.length;
      table._rows.add(row);
      table._rowIdToIndex[rowId] = idx;
    }

    // Rebuild indices (automatic indices already created in constructor)
    for (final idx in table._indices.values) {
      idx.rebuild(table._rows);
    }

    // Restore custom indices from JSON
    final indicesJson = json['indices'] as List<dynamic>?;
    if (indicesJson != null) {
      for (final idxJson in indicesJson) {
        final metadata = IndexMetadata.fromJson(
          idxJson as Map<String, dynamic>,
        );

        // Check if this index already exists (from auto-creation)
        final existingKey = metadata.columns.length == 1
            ? metadata.columns.first.toLowerCase()
            : metadata.name.toLowerCase();

        if (!table._indices.containsKey(existingKey)) {
          // Create the index
          TableIndex newIdx;
          if (metadata.columns.length == 1) {
            newIdx = TableIndex(
              columnName: metadata.columns.first,
              unique: metadata.unique,
              type: metadata.type,
              name: metadata.name,
            );
          } else {
            newIdx = TableIndex.composite(
              columns: metadata.columns,
              unique: metadata.unique,
              type: metadata.type,
              name: metadata.name,
            );
          }
          newIdx.rebuild(table._rows);
          table._indices[existingKey] = newIdx;
        }
      }
    }

    return table;
  }

  // ---------------------------------------------------------------------------
  // PRIVATE HELPERS
  // ---------------------------------------------------------------------------

  void _addToIndices(DatabaseRow row) {
    for (final idx in _indices.values) {
      if (idx.isComposite) {
        idx.add(row, row.rowId);
      } else {
        final colName = idx.columns.first;
        idx.add(row.values[colName], row.rowId);
      }
    }
  }

  void _removeFromIndices(DatabaseRow row) {
    for (final idx in _indices.values) {
      if (idx.isComposite) {
        idx.remove(row, row.rowId);
      } else {
        final colName = idx.columns.first;
        idx.remove(row.values[colName], row.rowId);
      }
    }
  }

  dynamic _coerce(dynamic value, DataType type) {
    if (value == null) return null;
    switch (type) {
      case DataType.integer:
        if (value is int) return value;
        if (value is double) return value.toInt();
        if (value is String) return int.tryParse(value) ?? value;
        if (value is bool) return value ? 1 : 0;
        return value;
      case DataType.real:
        if (value is double) return value;
        if (value is int) return value.toDouble();
        if (value is String) return double.tryParse(value) ?? value;
        return value;
      case DataType.text:
        return value.toString();
      case DataType.boolean:
        if (value is bool) return value;
        if (value is int) return value != 0;
        if (value is String) {
          return value.toLowerCase() == 'true' || value == '1';
        }
        return value;
      case DataType.datetime:
        if (value is DateTime) return value.toUtc();
        if (value is String) {
          return DateTime.tryParse(value)?.toUtc() ?? value;
        }
        return value;
      case DataType.blob:
        if (value is Uint8List) return value;
        if (value is List<int>) return Uint8List.fromList(value);
        return value;
    }
  }
}

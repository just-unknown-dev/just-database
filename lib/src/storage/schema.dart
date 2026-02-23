/// The supported SQL data types.
enum DataType { integer, text, real, blob, boolean, datetime }

/// Parses a SQL type name string into a [DataType].
DataType parseDataType(String typeName) {
  switch (typeName.toUpperCase()) {
    case 'INTEGER':
    case 'INT':
    case 'BIGINT':
    case 'SMALLINT':
      return DataType.integer;
    case 'TEXT':
    case 'VARCHAR':
    case 'CHAR':
    case 'STRING':
      return DataType.text;
    case 'REAL':
    case 'FLOAT':
    case 'DOUBLE':
    case 'NUMERIC':
    case 'DECIMAL':
      return DataType.real;
    case 'BLOB':
    case 'BINARY':
      return DataType.blob;
    case 'BOOLEAN':
    case 'BOOL':
      return DataType.boolean;
    case 'DATETIME':
    case 'DATE':
    case 'TIMESTAMP':
      return DataType.datetime;
    default:
      return DataType.text; // fallback
  }
}

/// Constraint definitions for a column.
class ConstraintDefinition {
  final bool notNull;
  final bool primaryKey;
  final bool unique;
  final bool autoIncrement;
  final bool hasDefault;
  final dynamic defaultValue;
  final String? foreignKeyTable;
  final String? foreignKeyColumn;

  const ConstraintDefinition({
    this.notNull = false,
    this.primaryKey = false,
    this.unique = false,
    this.autoIncrement = false,
    this.hasDefault = false,
    this.defaultValue,
    this.foreignKeyTable,
    this.foreignKeyColumn,
  });

  ConstraintDefinition copyWith({
    bool? notNull,
    bool? primaryKey,
    bool? unique,
    bool? autoIncrement,
    bool? hasDefault,
    dynamic defaultValue,
    String? foreignKeyTable,
    String? foreignKeyColumn,
  }) {
    return ConstraintDefinition(
      notNull: notNull ?? this.notNull,
      primaryKey: primaryKey ?? this.primaryKey,
      unique: unique ?? this.unique,
      autoIncrement: autoIncrement ?? this.autoIncrement,
      hasDefault: hasDefault ?? this.hasDefault,
      defaultValue: defaultValue ?? this.defaultValue,
      foreignKeyTable: foreignKeyTable ?? this.foreignKeyTable,
      foreignKeyColumn: foreignKeyColumn ?? this.foreignKeyColumn,
    );
  }

  Map<String, dynamic> toJson() => {
    'notNull': notNull,
    'primaryKey': primaryKey,
    'unique': unique,
    'autoIncrement': autoIncrement,
    'hasDefault': hasDefault,
    'defaultValue': defaultValue,
    'foreignKeyTable': foreignKeyTable,
    'foreignKeyColumn': foreignKeyColumn,
  };

  factory ConstraintDefinition.fromJson(Map<String, dynamic> json) {
    return ConstraintDefinition(
      notNull: json['notNull'] as bool? ?? false,
      primaryKey: json['primaryKey'] as bool? ?? false,
      unique: json['unique'] as bool? ?? false,
      autoIncrement: json['autoIncrement'] as bool? ?? false,
      hasDefault: json['hasDefault'] as bool? ?? false,
      defaultValue: json['defaultValue'],
      foreignKeyTable: json['foreignKeyTable'] as String?,
      foreignKeyColumn: json['foreignKeyColumn'] as String?,
    );
  }
}

/// Definition of a single table column.
class ColumnDefinition {
  final String name;
  final DataType type;
  final ConstraintDefinition constraints;

  const ColumnDefinition({
    required this.name,
    required this.type,
    this.constraints = const ConstraintDefinition(),
  });

  ColumnDefinition copyWith({
    String? name,
    DataType? type,
    ConstraintDefinition? constraints,
  }) {
    return ColumnDefinition(
      name: name ?? this.name,
      type: type ?? this.type,
      constraints: constraints ?? this.constraints,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'type': type.name,
    'constraints': constraints.toJson(),
  };

  factory ColumnDefinition.fromJson(Map<String, dynamic> json) {
    return ColumnDefinition(
      name: json['name'] as String,
      type: DataType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => DataType.text,
      ),
      constraints: json['constraints'] != null
          ? ConstraintDefinition.fromJson(
              json['constraints'] as Map<String, dynamic>,
            )
          : const ConstraintDefinition(),
    );
  }

  @override
  String toString() => 'ColumnDefinition($name: $type)';
}

/// Table-level constraint (multi-column PRIMARY KEY or UNIQUE).
class TableConstraint {
  final TableConstraintType type;
  final List<String> columns;
  final String? name;

  const TableConstraint({required this.type, required this.columns, this.name});

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'columns': columns,
    'name': name,
  };

  factory TableConstraint.fromJson(Map<String, dynamic> json) {
    return TableConstraint(
      type: TableConstraintType.values.firstWhere(
        (e) => e.name == json['type'],
        orElse: () => TableConstraintType.unique,
      ),
      columns: (json['columns'] as List<dynamic>).cast<String>(),
      name: json['name'] as String?,
    );
  }

  @override
  String toString() => 'TableConstraint(${type.name} on ${columns.join(", ")})';
}

/// Type of table-level constraint.
enum TableConstraintType { primaryKey, unique }

/// Schema definition for a table.
class TableSchema {
  final String tableName;
  final List<ColumnDefinition> columns;
  final List<TableConstraint> tableConstraints;

  const TableSchema({
    required this.tableName,
    required this.columns,
    this.tableConstraints = const [],
  });

  /// Returns the primary key column, or null if none is defined.
  /// If a composite primary key exists, returns null (use primaryKeyColumns).
  ColumnDefinition? get primaryKeyColumn {
    for (final col in columns) {
      if (col.constraints.primaryKey) return col;
    }
    return null;
  }

  /// Returns the list of columns that form the primary key.
  /// For single-column PK, returns a list with one element.
  /// For composite PK, returns all columns in the constraint.
  List<String> get primaryKeyColumns {
    // Check for table-level composite PK first
    for (final constraint in tableConstraints) {
      if (constraint.type == TableConstraintType.primaryKey) {
        return constraint.columns;
      }
    }
    // Check for column-level PK
    final pk = primaryKeyColumn;
    if (pk != null) return [pk.name];
    return [];
  }

  /// Returns all UNIQUE constraints (both column-level and table-level).
  List<List<String>> get uniqueConstraints {
    final result = <List<String>>[];
    // Table-level unique constraints
    for (final constraint in tableConstraints) {
      if (constraint.type == TableConstraintType.unique) {
        result.add(constraint.columns);
      }
    }
    // Column-level unique constraints
    for (final col in columns) {
      if (col.constraints.unique) {
        result.add([col.name]);
      }
    }
    return result;
  }

  /// Returns the column with the given name (case-insensitive), or null.
  ColumnDefinition? getColumn(String name) {
    final lower = name.toLowerCase();
    for (final col in columns) {
      if (col.name.toLowerCase() == lower) return col;
    }
    return null;
  }

  bool hasColumn(String name) => getColumn(name) != null;

  /// Returns the 0-based index of the column, or null if not found.
  int? columnIndex(String name) {
    final lower = name.toLowerCase();
    for (int i = 0; i < columns.length; i++) {
      if (columns[i].name.toLowerCase() == lower) return i;
    }
    return null;
  }

  TableSchema addColumn(ColumnDefinition col) {
    return TableSchema(
      tableName: tableName,
      columns: [...columns, col],
      tableConstraints: tableConstraints,
    );
  }

  TableSchema dropColumn(String name) {
    return TableSchema(
      tableName: tableName,
      columns: columns
          .where((c) => c.name.toLowerCase() != name.toLowerCase())
          .toList(),
      tableConstraints: tableConstraints,
    );
  }

  TableSchema renameColumn(String oldName, String newName) {
    return TableSchema(
      tableName: tableName,
      columns: columns.map((c) {
        if (c.name.toLowerCase() == oldName.toLowerCase()) {
          return c.copyWith(name: newName);
        }
        return c;
      }).toList(),
      tableConstraints: tableConstraints,
    );
  }

  Map<String, dynamic> toJson() => {
    'tableName': tableName,
    'columns': columns.map((c) => c.toJson()).toList(),
    'tableConstraints': tableConstraints.map((c) => c.toJson()).toList(),
  };

  factory TableSchema.fromJson(Map<String, dynamic> json) {
    return TableSchema(
      tableName: json['tableName'] as String,
      columns: (json['columns'] as List<dynamic>)
          .map((c) => ColumnDefinition.fromJson(c as Map<String, dynamic>))
          .toList(),
      tableConstraints:
          (json['tableConstraints'] as List<dynamic>?)
              ?.map((c) => TableConstraint.fromJson(c as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  @override
  String toString() => 'TableSchema($tableName, ${columns.length} columns)';
}

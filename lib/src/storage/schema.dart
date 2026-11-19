/// The schema of a table: its columns and constraints, as declared by
/// `CREATE TABLE` and changed by `ALTER TABLE`.
library;

import 'values.dart';

/// The type affinity of a column, derived from its declared type by
/// SQLite's rules (section 3.1 of https://sqlite.org/datatype3.html).
enum Affinity {
  /// Declared type contains `INT`. Text that looks like a number is stored
  /// as a number; reals with no fractional part are stored as integers.
  integer,

  /// Declared type contains `CHAR`, `CLOB` or `TEXT`. Numbers are stored as
  /// text.
  text,

  /// Declared type contains `BLOB`, or no type was declared. Values are
  /// stored as given.
  blob,

  /// Declared type contains `REAL`, `FLOA` or `DOUB`. Integers are stored as
  /// reals.
  real,

  /// Any other declared type, such as `NUMERIC`, `DECIMAL`, `BOOLEAN` or
  /// `DATETIME`. Text that looks like a number is stored as a number.
  numeric;

  /// The affinity of a column declared with [declaredType].
  static Affinity of(String declaredType) {
    final t = declaredType.toUpperCase();
    if (t.contains('INT')) return Affinity.integer;
    if (t.contains('CHAR') || t.contains('CLOB') || t.contains('TEXT')) {
      return Affinity.text;
    }
    if (t.isEmpty || t.contains('BLOB')) return Affinity.blob;
    if (t.contains('REAL') || t.contains('FLOA') || t.contains('DOUB')) {
      return Affinity.real;
    }
    return Affinity.numeric;
  }

  /// Whether values of this affinity are compared as numbers.
  bool get isNumeric =>
      this == Affinity.integer ||
      this == Affinity.real ||
      this == Affinity.numeric;
}

/// What happens to child rows when the parent row they reference is deleted
/// (`ON DELETE`) or its referenced key changes (`ON UPDATE`).
enum ForeignKeyAction {
  /// The default. The change fails if, when the statement ends, a child row
  /// still references a parent row that no longer exists.
  noAction('NO ACTION'),

  /// The change fails at once while child rows reference the parent row.
  restrict('RESTRICT'),

  /// Child rows are deleted (`ON DELETE`) or take the new key (`ON UPDATE`).
  cascade('CASCADE'),

  /// The child's foreign key columns are set to NULL.
  setNull('SET NULL'),

  /// The child's foreign key columns are set to their DEFAULT values.
  setDefault('SET DEFAULT');

  const ForeignKeyAction(this.sql);

  /// The action as written in SQL, e.g. `SET NULL`.
  final String sql;

  /// Parses an action from its [name] (as stored in JSON), falling back to
  /// [noAction] for null or unknown values.
  static ForeignKeyAction fromName(String? name) => ForeignKeyAction.values
      .firstWhere((a) => a.name == name, orElse: () => noAction);
}

/// A foreign key: [columns] of this table reference [parentColumns] of
/// [parentTable].
final class ForeignKeyDefinition {
  /// Creates a foreign key. An empty [parentColumns] means the parent
  /// table's primary key.
  const ForeignKeyDefinition({
    required this.columns,
    required this.parentTable,
    this.parentColumns = const [],
    this.onDelete = ForeignKeyAction.noAction,
    this.onUpdate = ForeignKeyAction.noAction,
  });

  /// The referencing (child) columns of this table.
  final List<String> columns;

  /// The referenced (parent) table.
  final String parentTable;

  /// The referenced columns; empty for the parent's primary key.
  final List<String> parentColumns;

  /// The action on this table's rows when the parent row is deleted.
  final ForeignKeyAction onDelete;

  /// The action on this table's rows when the parent key changes.
  final ForeignKeyAction onUpdate;

  /// The `REFERENCES …` clause, without the leading `FOREIGN KEY (…)`.
  String get referencesSql {
    final b = StringBuffer('REFERENCES ${quoteIdentifier(parentTable)}');
    if (parentColumns.isNotEmpty) {
      b.write('(${parentColumns.map(quoteIdentifier).join(', ')})');
    }
    if (onDelete != ForeignKeyAction.noAction) {
      b.write(' ON DELETE ${onDelete.sql}');
    }
    if (onUpdate != ForeignKeyAction.noAction) {
      b.write(' ON UPDATE ${onUpdate.sql}');
    }
    return b.toString();
  }

  /// A copy with column names replaced through [rename] (old → new,
  /// compared case-insensitively) on the child side, the parent side, or
  /// both.
  ForeignKeyDefinition renamed({
    String Function(String)? child,
    String Function(String)? parent,
    String? parentTable,
  }) => ForeignKeyDefinition(
    columns: child == null ? columns : columns.map(child).toList(),
    parentTable: parentTable ?? this.parentTable,
    parentColumns: parent == null
        ? parentColumns
        : parentColumns.map(parent).toList(),
    onDelete: onDelete,
    onUpdate: onUpdate,
  );

  /// The JSON form stored in database files.
  Map<String, Object?> toJson() => {
    'columns': columns,
    'parentTable': parentTable,
    if (parentColumns.isNotEmpty) 'parentColumns': parentColumns,
    if (onDelete != ForeignKeyAction.noAction) 'onDelete': onDelete.name,
    if (onUpdate != ForeignKeyAction.noAction) 'onUpdate': onUpdate.name,
  };

  /// Reads the form written by [toJson].
  factory ForeignKeyDefinition.fromJson(Map<String, Object?> json) =>
      ForeignKeyDefinition(
        columns: (json['columns'] as List).cast<String>(),
        parentTable: json['parentTable'] as String,
        parentColumns:
            (json['parentColumns'] as List?)?.cast<String>() ?? const [],
        onDelete: ForeignKeyAction.fromName(json['onDelete'] as String?),
        onUpdate: ForeignKeyAction.fromName(json['onUpdate'] as String?),
      );
}

/// One column of a table.
final class ColumnDefinition {
  /// Creates a column definition.
  const ColumnDefinition({
    required this.name,
    this.type = '',
    this.notNull = false,
    this.primaryKey = false,
    this.autoIncrement = false,
    this.unique = false,
    this.defaultSql,
    this.collation,
    this.hidden = false,
  });

  /// The column's name, in the case it was declared with.
  final String name;

  /// The declared type exactly as written (`INTEGER`, `VARCHAR(20)`, …), or
  /// empty when none was given.
  final String type;

  /// Whether NULL is rejected.
  final bool notNull;

  /// Whether this column was declared `PRIMARY KEY` by itself.
  final bool primaryKey;

  /// Whether `AUTOINCREMENT` was declared (only on an `INTEGER PRIMARY KEY`).
  final bool autoIncrement;

  /// Whether this column was declared `UNIQUE` by itself.
  final bool unique;

  /// The `DEFAULT` expression as SQL text, or null when there is none.
  final String? defaultSql;

  /// The declared collation (`BINARY`, `NOCASE` or `RTRIM`), or null for
  /// the default.
  final String? collation;

  /// Internal: true for columns that are not part of `SELECT *`.
  final bool hidden;

  /// The column's type affinity.
  Affinity get affinity => Affinity.of(type);

  /// Whether a DEFAULT was declared.
  bool get hasDefault => defaultSql != null;

  /// A copy with the given fields replaced. Pass a value for [defaultSql]
  /// or [collation] to replace them; they cannot be cleared this way.
  ColumnDefinition copyWith({
    String? name,
    String? type,
    bool? notNull,
    bool? primaryKey,
    bool? autoIncrement,
    bool? unique,
    String? defaultSql,
    String? collation,
  }) => ColumnDefinition(
    name: name ?? this.name,
    type: type ?? this.type,
    notNull: notNull ?? this.notNull,
    primaryKey: primaryKey ?? this.primaryKey,
    autoIncrement: autoIncrement ?? this.autoIncrement,
    unique: unique ?? this.unique,
    defaultSql: defaultSql ?? this.defaultSql,
    collation: collation ?? this.collation,
    hidden: hidden,
  );

  /// The column as it appears in `CREATE TABLE`, without table-level
  /// constraints.
  String get sql {
    final b = StringBuffer(quoteIdentifier(name));
    if (type.isNotEmpty) b.write(' $type');
    if (primaryKey) {
      b.write(' PRIMARY KEY');
      if (autoIncrement) b.write(' AUTOINCREMENT');
    }
    if (notNull) b.write(' NOT NULL');
    if (unique) b.write(' UNIQUE');
    if (defaultSql != null) b.write(' DEFAULT $defaultSql');
    if (collation != null) b.write(' COLLATE $collation');
    return b.toString();
  }

  /// The JSON form stored in database files.
  Map<String, Object?> toJson() => {
    'name': name,
    if (type.isNotEmpty) 'type': type,
    if (notNull) 'notNull': true,
    if (primaryKey) 'primaryKey': true,
    if (autoIncrement) 'autoIncrement': true,
    if (unique) 'unique': true,
    if (defaultSql != null) 'default': defaultSql,
    if (collation != null) 'collation': collation,
  };

  /// Reads the form written by [toJson].
  factory ColumnDefinition.fromJson(Map<String, Object?> json) =>
      ColumnDefinition(
        name: json['name'] as String,
        type: json['type'] as String? ?? '',
        notNull: json['notNull'] as bool? ?? false,
        primaryKey: json['primaryKey'] as bool? ?? false,
        autoIncrement: json['autoIncrement'] as bool? ?? false,
        unique: json['unique'] as bool? ?? false,
        defaultSql: json['default'] as String?,
        collation: json['collation'] as String?,
      );

  @override
  String toString() => 'ColumnDefinition($sql)';
}

/// The kind of a [TableConstraint].
enum TableConstraintKind {
  /// `PRIMARY KEY (…)`.
  primaryKey,

  /// `UNIQUE (…)`.
  unique,

  /// `CHECK (…)`.
  check,

  /// `FOREIGN KEY (…) REFERENCES …`, or a column's `REFERENCES` clause.
  foreignKey,
}

/// A table constraint. Column-level `CHECK` and `REFERENCES` clauses are
/// stored as table constraints too; column-level `PRIMARY KEY` and `UNIQUE`
/// stay on the [ColumnDefinition].
final class TableConstraint {
  /// Creates a constraint.
  const TableConstraint({
    required this.kind,
    this.name,
    this.columns = const [],
    this.checkSql,
    this.foreignKey,
  });

  /// What kind of constraint this is.
  final TableConstraintKind kind;

  /// The `CONSTRAINT <name>`, if one was given.
  final String? name;

  /// The constrained columns (PRIMARY KEY, UNIQUE, FOREIGN KEY).
  final List<String> columns;

  /// The CHECK expression as SQL text.
  final String? checkSql;

  /// The foreign key, for [TableConstraintKind.foreignKey].
  final ForeignKeyDefinition? foreignKey;

  /// The constraint as it appears in `CREATE TABLE`.
  String get sql {
    final b = StringBuffer();
    if (name != null) b.write('CONSTRAINT ${quoteIdentifier(name!)} ');
    final cols = columns.map(quoteIdentifier).join(', ');
    switch (kind) {
      case TableConstraintKind.primaryKey:
        b.write('PRIMARY KEY ($cols)');
      case TableConstraintKind.unique:
        b.write('UNIQUE ($cols)');
      case TableConstraintKind.check:
        b.write('CHECK ($checkSql)');
      case TableConstraintKind.foreignKey:
        b.write('FOREIGN KEY ($cols) ${foreignKey!.referencesSql}');
    }
    return b.toString();
  }

  /// The JSON form stored in database files.
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    if (name != null) 'name': name,
    if (columns.isNotEmpty) 'columns': columns,
    if (checkSql != null) 'check': checkSql,
    if (foreignKey != null) 'foreignKey': foreignKey!.toJson(),
  };

  /// Reads the form written by [toJson]. Returns null for a kind this
  /// version does not know, so a newer file's constraint is never misread.
  static TableConstraint? fromJson(Map<String, Object?> json) {
    final kind = TableConstraintKind.values
        .where((k) => k.name == json['kind'])
        .firstOrNull;
    if (kind == null) return null;
    final fk = json['foreignKey'] as Map<String, Object?>?;
    return TableConstraint(
      kind: kind,
      name: json['name'] as String?,
      columns: (json['columns'] as List?)?.cast<String>() ?? const [],
      checkSql: json['check'] as String?,
      foreignKey: fk == null ? null : ForeignKeyDefinition.fromJson(fk),
    );
  }

  @override
  String toString() => 'TableConstraint($sql)';
}

/// The schema of one table.
final class TableSchema {
  /// Creates a schema.
  const TableSchema({
    required this.name,
    required this.columns,
    this.constraints = const [],
  });

  /// The table's name, in the case it was created with.
  final String name;

  /// The columns, in declaration order.
  final List<ColumnDefinition> columns;

  /// Table-level constraints, plus column-level CHECK and REFERENCES.
  final List<TableConstraint> constraints;

  /// The position of the column named [column] (case-insensitive), or null.
  int? indexOf(String column) {
    final lower = column.toLowerCase();
    for (var i = 0; i < columns.length; i++) {
      if (columns[i].name.toLowerCase() == lower) return i;
    }
    return null;
  }

  /// The column named [column] (case-insensitive), or null.
  ColumnDefinition? column(String column) {
    final i = indexOf(column);
    return i == null ? null : columns[i];
  }

  /// The primary key's columns, in key order; empty when there is none.
  List<String> get primaryKey {
    for (final c in constraints) {
      if (c.kind == TableConstraintKind.primaryKey) return c.columns;
    }
    for (final c in columns) {
      if (c.primaryKey) return [c.name];
    }
    return const [];
  }

  /// The position of the column that aliases the rowid: a single-column
  /// primary key declared exactly `INTEGER`, as in SQLite. Null when there
  /// is none.
  int? get rowidAlias {
    final pk = primaryKey;
    if (pk.length != 1) return null;
    final i = indexOf(pk.first);
    if (i == null || columns[i].type.toUpperCase() != 'INTEGER') return null;
    return i;
  }

  /// Whether the rowid alias was declared `AUTOINCREMENT`.
  bool get autoIncrement {
    final i = rowidAlias;
    return i != null && columns[i].autoIncrement;
  }

  /// Every unique key: the primary key (unless it aliases the rowid, which
  /// is unique by construction), then each UNIQUE constraint and column.
  List<List<String>> get uniqueKeys => [
    if (primaryKey.isNotEmpty && rowidAlias == null) primaryKey,
    for (final c in constraints)
      if (c.kind == TableConstraintKind.unique) c.columns,
    for (final c in columns)
      if (c.unique) [c.name],
  ];

  /// Every foreign key of this table.
  List<ForeignKeyDefinition> get foreignKeys => [
    for (final c in constraints)
      if (c.kind == TableConstraintKind.foreignKey) c.foreignKey!,
  ];

  /// Every CHECK expression, as SQL text.
  List<String> get checks => [
    for (final c in constraints)
      if (c.kind == TableConstraintKind.check) c.checkSql!,
  ];

  /// The visible column names, in order.
  List<String> get columnNames => [
    for (final c in columns)
      if (!c.hidden) c.name,
  ];

  /// A copy with [name], [columns] or [constraints] replaced.
  TableSchema copyWith({
    String? name,
    List<ColumnDefinition>? columns,
    List<TableConstraint>? constraints,
  }) => TableSchema(
    name: name ?? this.name,
    columns: columns ?? this.columns,
    constraints: constraints ?? this.constraints,
  );

  /// The `CREATE TABLE` statement that recreates this schema.
  String get sql {
    final parts = [
      for (final c in columns) c.sql,
      for (final c in constraints) c.sql,
    ];
    return 'CREATE TABLE ${quoteIdentifier(name)} (${parts.join(', ')})';
  }

  /// The JSON form stored in database files.
  Map<String, Object?> toJson() => {
    'name': name,
    'columns': [for (final c in columns) c.toJson()],
    if (constraints.isNotEmpty)
      'constraints': [for (final c in constraints) c.toJson()],
  };

  /// Reads the form written by [toJson].
  factory TableSchema.fromJson(Map<String, Object?> json) => TableSchema(
    name: json['name'] as String,
    columns: [
      for (final c in json['columns'] as List)
        ColumnDefinition.fromJson(c as Map<String, Object?>),
    ],
    constraints: [
      for (final c in (json['constraints'] as List?) ?? const [])
        ?TableConstraint.fromJson(c as Map<String, Object?>),
    ],
  );

  @override
  String toString() => 'TableSchema($name, ${columns.length} columns)';
}

/// Where an index came from.
enum IndexOrigin {
  /// Created for the table's PRIMARY KEY.
  primaryKey,

  /// Created for a UNIQUE constraint.
  unique,

  /// Created by `CREATE [UNIQUE] INDEX`.
  manual,

  /// Created by `CREATE SPATIAL INDEX`: an R-tree over two columns.
  spatial,

  /// Internal: kept on a foreign key's columns so that changing a parent
  /// row finds its children without a scan. Never listed or saved.
  foreignKey,
}

/// A description of one index, for introspection.
final class IndexInfo {
  /// Creates an index description.
  const IndexInfo({
    required this.name,
    required this.table,
    required this.columns,
    required this.unique,
    required this.origin,
  });

  /// The index's name. Constraint indexes are named
  /// `sqlite_autoindex_<table>_<n>`, as in SQLite.
  final String name;

  /// The indexed table.
  final String table;

  /// The indexed columns, in key order.
  final List<String> columns;

  /// Whether the index enforces uniqueness.
  final bool unique;

  /// What created the index.
  final IndexOrigin origin;

  @override
  String toString() =>
      'IndexInfo($name on $table(${columns.join(', ')})'
      '${unique ? ', unique' : ''})';
}

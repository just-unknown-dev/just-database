part of 'engine.dart';

extension _Ddl on Engine {
  void _checkName(String name) {
    if (name.toLowerCase().startsWith('sqlite_')) {
      throw SqlException('object name reserved for internal use: $name');
    }
  }

  /// Throws unless [name] is free in the table/view/index namespace;
  /// returns false (do nothing) when it is taken and [ifNotExists] is set.
  bool _claimName(String name, String kind, bool ifNotExists) {
    final use = catalog.nameUse(name);
    if (use == null) return true;
    if (ifNotExists && use == kind) return false;
    if (use == kind) throw SqlException.schema('$kind $name already exists');
    throw SqlException.schema('there is already a $use named $name');
  }

  /// Checks that a DEFAULT expression is constant.
  void _checkDefault(ColumnSpec c, {bool forAddColumn = false}) {
    final e = c.defaultExpr;
    if (e == null) return;
    final ctx = _Ctx(_Scope(const [], null));
    try {
      _compile(e, ctx);
    } on SqlException {
      throw SqlException('default value of column [${c.name}] is not constant');
    }
    if (ctx.volatile) {
      throw SqlException('default value of column [${c.name}] is not constant');
    }
    if (forAddColumn && (e is CurrentTime || _hasCurrentTime(e))) {
      throw const SqlException('Cannot add a column with non-constant default');
    }
  }

  bool _hasCurrentTime(Expr e) => switch (e) {
    CurrentTime() => true,
    Unary() => _hasCurrentTime(e.operand),
    Binary() => _hasCurrentTime(e.left) || _hasCurrentTime(e.right),
    FunctionCall() => e.args.any(_hasCurrentTime),
    Cast() => _hasCurrentTime(e.expr),
    _ => false,
  };

  ColumnDefinition _columnDefinition(ColumnSpec c) {
    if (c.collation != null && Collation.parse(c.collation) == null) {
      throw SqlException('no such collation sequence: ${c.collation}');
    }
    return ColumnDefinition(
      name: c.name,
      type: c.type,
      notNull: c.notNull,
      primaryKey: c.primaryKey,
      autoIncrement: c.autoIncrement,
      unique: c.unique,
      defaultSql: c.defaultSql,
      collation: c.collation,
    );
  }

  // ---------------------------------------------------------------------------
  // Tables
  // ---------------------------------------------------------------------------

  StatementResult _createTable(CreateTableStatement s) {
    _checkName(s.name);
    if (catalog.nameUse(s.name) != null) {
      if (s.ifNotExists && catalog.table(s.name) != null) {
        return StatementResult();
      }
      _claimName(s.name, 'table', false);
    }
    if (s.asSelect != null) return _createTableAs(s);

    final names = <String>{};
    for (final c in s.columns) {
      if (!names.add(c.name.toLowerCase())) {
        throw SqlException('duplicate column name: ${c.name}');
      }
    }
    final columnPks = s.columns.where((c) => c.primaryKey).length;
    final tablePks = s.constraints
        .where((c) => c.kind == TableConstraintKind.primaryKey)
        .length;
    if (columnPks + tablePks > 1) {
      throw SqlException('table "${s.name}" has more than one primary key');
    }
    for (final c in s.columns) {
      if (c.autoIncrement &&
          (!c.primaryKey || c.type.toUpperCase() != 'INTEGER')) {
        throw const SqlException(
          'AUTOINCREMENT is only allowed on an INTEGER PRIMARY KEY',
        );
      }
      _checkDefault(c);
    }
    final constraints = <TableConstraint>[];
    for (final k in s.constraints) {
      for (final col in k.columns) {
        if (!names.contains(col.toLowerCase())) {
          throw SqlException.schema('no such column: $col');
        }
      }
      constraints.add(
        TableConstraint(
          kind: k.kind,
          name: k.name,
          columns: [
            for (final col in k.columns)
              s.columns
                  .firstWhere((c) => c.name.toLowerCase() == col.toLowerCase())
                  .name,
          ],
          checkSql: k.checkSql,
          foreignKey: k.foreignKey,
        ),
      );
    }
    for (final c in s.columns) {
      for (final (_, sql) in c.checks) {
        constraints.add(
          TableConstraint(kind: TableConstraintKind.check, checkSql: sql),
        );
      }
      if (c.references != null) {
        constraints.add(
          TableConstraint(
            kind: TableConstraintKind.foreignKey,
            columns: [c.name],
            foreignKey: c.references,
          ),
        );
      }
    }
    final schema = TableSchema(
      name: s.name,
      columns: [for (final c in s.columns) _columnDefinition(c)],
      constraints: constraints,
    );
    // CHECK expressions must compile against the new columns.
    final scopeTable = TableData(schema, catalog.log);
    final scope = _Scope([_Source.table(scopeTable, null)], null);
    for (final sql in schema.checks) {
      final e = Parser.parseExpression(sql);
      _withSource(sql, () => _compile(e, _Ctx(scope)));
    }
    catalog.addTable(TableData(schema, catalog.log));
    return StatementResult();
  }

  StatementResult _createTableAs(CreateTableStatement s) {
    final plan = _compileSelect(s.asSelect!, null);
    final rows = plan.run(null);
    final columns = <ColumnDefinition>[];
    for (var i = 0; i < plan.columnNames.length; i++) {
      var type = plan.declaredTypes[i];
      if (type.isEmpty) {
        type = switch (plan.affinities[i]) {
          Affinity.integer => 'INT',
          Affinity.real => 'REAL',
          Affinity.text => 'TEXT',
          Affinity.numeric => 'NUM',
          _ => '',
        };
      }
      columns.add(ColumnDefinition(name: plan.columnNames[i], type: type));
    }
    final t = TableData(
      TableSchema(name: s.name, columns: columns),
      catalog.log,
    );
    catalog.addTable(t);
    for (final r in rows) {
      t.insert(t.newRowId(), [
        for (var i = 0; i < columns.length; i++)
          applyAffinity(r[i], columns[i].affinity),
      ]);
    }
    return StatementResult();
  }

  StatementResult _dropTable(DropTableStatement s) {
    final t = catalog.table(s.name);
    if (t == null) {
      if (catalog.view(s.name) != null) {
        throw SqlException('use DROP VIEW to delete view ${s.name}');
      }
      if (s.ifExists) return StatementResult();
      throw SqlException.schema('no such table: ${s.name}');
    }
    // With foreign keys on, dropping a parent first deletes its rows (no
    // triggers), so references are checked and actions run.
    if (foreignKeys && _referencing(t).any((r) => !identical(r.$1, t))) {
      for (final id in t.rowids.toList()) {
        final row = t.row(id);
        if (row == null) continue;
        _parentDeleted(t, row);
        if (t.row(id) != null) t.delete(id);
      }
    }
    for (final trig in catalog.triggers.toList()) {
      if (trig.table.toLowerCase() == t.name.toLowerCase()) {
        catalog.removeTrigger(trig.name);
      }
    }
    catalog.removeTable(t.name);
    return StatementResult();
  }

  TableData _alterTarget(String name) {
    final t = catalog.table(name);
    if (t != null) return t;
    if (catalog.view(name) != null) {
      throw SqlException('view $name may not be altered');
    }
    throw SqlException.schema('no such table: $name');
  }

  StatementResult _renameTable(RenameTableStatement s) {
    final t = _alterTarget(s.table);
    _checkName(s.newName);
    final old = t.name;
    if (old.toLowerCase() != s.newName.toLowerCase()) {
      _claimName(s.newName, 'table', false);
    }
    // Other tables' foreign keys.
    for (final other in catalog.tables) {
      if (identical(other, t)) continue;
      final cs = other.schema.constraints;
      if (!cs.any(
        (c) => c.foreignKey?.parentTable.toLowerCase() == old.toLowerCase(),
      )) {
        continue;
      }
      other.setSchema(
        other.schema.copyWith(
          constraints: [
            for (final c in cs)
              c.foreignKey != null &&
                      c.foreignKey!.parentTable.toLowerCase() ==
                          old.toLowerCase()
                  ? TableConstraint(
                      kind: c.kind,
                      name: c.name,
                      columns: c.columns,
                      foreignKey: c.foreignKey!.renamed(parentTable: s.newName),
                    )
                  : c,
          ],
        ),
      );
    }
    // The table itself (and its self-references).
    t.setSchema(
      t.schema.copyWith(
        name: s.newName,
        constraints: [
          for (final c in t.schema.constraints)
            c.foreignKey != null &&
                    c.foreignKey!.parentTable.toLowerCase() == old.toLowerCase()
                ? TableConstraint(
                    kind: c.kind,
                    name: c.name,
                    columns: c.columns,
                    foreignKey: c.foreignKey!.renamed(parentTable: s.newName),
                  )
                : c,
        ],
      ),
    );
    for (final i in t.indexes) {
      final prefix = 'sqlite_autoindex_${old}_';
      final fkPrefix = 'sqlite_fkindex_${old}_';
      if (i.name.startsWith(prefix)) {
        t.renameIndex(
          i,
          'sqlite_autoindex_${s.newName}_${i.name.substring(prefix.length)}',
        );
      } else if (i.name.startsWith(fkPrefix)) {
        t.renameIndex(
          i,
          'sqlite_fkindex_${s.newName}_${i.name.substring(fkPrefix.length)}',
        );
      }
    }
    catalog.rekeyTable(old, t);
    // Triggers and views that mention it.
    for (final trig in catalog.triggers.toList()) {
      final sql = _renameTableInSql(trig.sql, old, s.newName);
      final onIt = trig.table.toLowerCase() == old.toLowerCase();
      if (sql != trig.sql || onIt) {
        catalog.replaceTrigger(
          TriggerDefinition(
            name: trig.name,
            table: onIt ? s.newName : trig.table,
            sql: sql,
          ),
        );
      }
    }
    for (final v in catalog.views.toList()) {
      final sql = _renameTableInSql(v.sql, old, s.newName);
      if (sql != v.sql) {
        catalog.replaceView(ViewDefinition(name: v.name, sql: sql));
      }
    }
    return StatementResult();
  }

  StatementResult _renameColumn(RenameColumnStatement s) {
    final t = _alterTarget(s.table);
    final i = t.schema.indexOf(s.column);
    if (i == null) throw SqlException.schema('no such column: "${s.column}"');
    final oldName = t.schema.columns[i].name;
    final j = t.schema.indexOf(s.newName);
    if (j != null && j != i) {
      throw SqlException('duplicate column name: ${s.newName}');
    }
    String rename(String c) =>
        c.toLowerCase() == oldName.toLowerCase() ? s.newName : c;
    t.setSchema(
      t.schema.copyWith(
        columns: [
          for (var k = 0; k < t.schema.columns.length; k++)
            k == i
                ? t.schema.columns[k].copyWith(name: s.newName)
                : t.schema.columns[k],
        ],
        constraints: [
          for (final c in t.schema.constraints)
            TableConstraint(
              kind: c.kind,
              name: c.name,
              columns: [for (final x in c.columns) rename(x)],
              checkSql: c.checkSql == null
                  ? null
                  : _renameColumnInSql(
                      c.checkSql!,
                      oldName,
                      s.newName,
                      unqualified: true,
                    ),
              foreignKey: c.foreignKey?.renamed(
                child: rename,
                parent:
                    c.foreignKey!.parentTable.toLowerCase() ==
                        t.name.toLowerCase()
                    ? rename
                    : null,
              ),
            ),
        ],
      ),
    );
    // Other tables' foreign keys naming the column.
    for (final other in catalog.tables) {
      if (identical(other, t)) continue;
      final cs = other.schema.constraints;
      if (!cs.any(
        (c) => c.foreignKey?.parentTable.toLowerCase() == t.name.toLowerCase(),
      )) {
        continue;
      }
      other.setSchema(
        other.schema.copyWith(
          constraints: [
            for (final c in cs)
              c.foreignKey != null &&
                      c.foreignKey!.parentTable.toLowerCase() ==
                          t.name.toLowerCase()
                  ? TableConstraint(
                      kind: c.kind,
                      name: c.name,
                      columns: c.columns,
                      foreignKey: c.foreignKey!.renamed(parent: rename),
                    )
                  : c,
          ],
        ),
      );
    }
    for (final trig in catalog.triggers.toList()) {
      final onIt = trig.table.toLowerCase() == t.name.toLowerCase();
      final sql = _renameColumnInSql(
        trig.sql,
        oldName,
        s.newName,
        table: t.name,
        unqualified: onIt,
        pseudo: onIt,
      );
      if (sql != trig.sql) {
        catalog.replaceTrigger(
          TriggerDefinition(name: trig.name, table: trig.table, sql: sql),
        );
      }
    }
    for (final v in catalog.views.toList()) {
      final sql = _renameColumnInSql(v.sql, oldName, s.newName, table: t.name);
      if (sql != v.sql) {
        catalog.replaceView(ViewDefinition(name: v.name, sql: sql));
      }
    }
    catalog.schemaChanged();
    return StatementResult();
  }

  StatementResult _addColumn(AddColumnStatement s) {
    final t = _alterTarget(s.table);
    final c = s.column;
    if (t.schema.indexOf(c.name) != null) {
      throw SqlException('duplicate column name: ${c.name}');
    }
    if (c.primaryKey) {
      throw const SqlException('Cannot add a PRIMARY KEY column');
    }
    if (c.unique) throw const SqlException('Cannot add a UNIQUE column');
    _checkDefault(c, forAddColumn: true);
    final def = _columnDefinition(c);
    final temp = TableData(
      TableSchema(name: t.name, columns: [def]),
      catalog.log,
    );
    final value = c.defaultExpr == null ? null : _defaultValueOf(temp, 0);
    if (c.notNull && value == null) {
      throw const SqlException(
        'Cannot add a NOT NULL column with default value NULL',
      );
    }
    if (c.references != null && foreignKeys && value != null) {
      throw const SqlException(
        'Cannot add a REFERENCES column with non-NULL default value',
      );
    }
    t.addColumn(def, value);
    final added = [
      for (final (_, sql) in c.checks)
        TableConstraint(kind: TableConstraintKind.check, checkSql: sql),
      if (c.references != null)
        TableConstraint(
          kind: TableConstraintKind.foreignKey,
          columns: [c.name],
          foreignKey: c.references,
        ),
    ];
    if (added.isNotEmpty) {
      t.setSchema(
        t.schema.copyWith(constraints: [...t.schema.constraints, ...added]),
      );
      t.ensureForeignKeyIndexes();
      // Existing rows must satisfy the new CHECKs.
      if (c.checks.isNotEmpty) {
        for (final e in t.entries) {
          _validate(t, e.value, e.key, ConflictAction.abort);
        }
      }
    }
    catalog.schemaChanged();
    return StatementResult();
  }

  Object? _defaultValueOf(TableData t, int i) => _defaultValue(t, i);

  StatementResult _dropColumn(DropColumnStatement s) {
    final t = _alterTarget(s.table);
    final i = t.schema.indexOf(s.column);
    if (i == null) throw SqlException.schema('no such column: "${s.column}"');
    final col = t.schema.columns[i];
    final lower = col.name.toLowerCase();
    if (t.schema.columns.length == 1) {
      throw SqlException(
        'cannot drop column "${col.name}": no other columns exist',
      );
    }
    if (t.schema.primaryKey.any((c) => c.toLowerCase() == lower)) {
      throw SqlException('cannot drop PRIMARY KEY column: "${col.name}"');
    }
    if (col.unique ||
        t.schema.constraints.any(
          (c) =>
              c.kind == TableConstraintKind.unique &&
              c.columns.any((x) => x.toLowerCase() == lower),
        )) {
      throw SqlException('cannot drop UNIQUE column: "${col.name}"');
    }
    for (final idx in t.indexes) {
      if (idx.origin == IndexOrigin.manual && idx.columns.contains(i)) {
        throw SqlException(
          'error in index ${idx.name} after drop column: no such column: ${col.name}',
        );
      }
    }
    for (final sp in t.spatialIndexes) {
      if (sp.xColumn == i || sp.yColumn == i) {
        throw SqlException(
          'error in index ${sp.name} after drop column: no such column: ${col.name}',
        );
      }
    }
    if (t.schema.foreignKeys.any(
      (fk) => fk.columns.any((x) => x.toLowerCase() == lower),
    )) {
      throw SqlException(
        'cannot drop column "${col.name}": used in a foreign key',
      );
    }
    for (final (other, fk) in _referencing(t)) {
      if (fk.parentColumns.any((x) => x.toLowerCase() == lower)) {
        throw SqlException(
          'cannot drop column "${col.name}": referenced by a foreign key of ${other.name}',
        );
      }
    }
    final keptChecks = <TableConstraint>[];
    for (final c in t.schema.constraints) {
      if (c.kind != TableConstraintKind.check) {
        keptChecks.add(c);
        continue;
      }
      final idents = _identifiersIn(c.checkSql!);
      if (!idents.contains(lower)) {
        keptChecks.add(c);
        continue;
      }
      final others = t.schema.columns
          .where((x) => x.name.toLowerCase() != lower)
          .map((x) => x.name.toLowerCase());
      if (others.any(idents.contains)) {
        throw SqlException(
          'error in table ${t.name} after drop column: no such column: ${col.name}',
        );
      }
      // A CHECK on this column alone goes with it.
    }
    for (final trig in catalog.triggers) {
      if (trig.table.toLowerCase() == t.name.toLowerCase() &&
          _identifiersIn(trig.sql).contains(lower)) {
        throw SqlException(
          'error in trigger ${trig.name} after drop column: no such column: ${col.name}',
        );
      }
    }
    final schema = t.schema.copyWith(
      columns: [
        for (var k = 0; k < t.schema.columns.length; k++)
          if (k != i) t.schema.columns[k],
      ],
      constraints: keptChecks,
    );
    t.dropColumn(i, schema);
    catalog.schemaChanged();
    return StatementResult();
  }

  // ---------------------------------------------------------------------------
  // Indexes
  // ---------------------------------------------------------------------------

  StatementResult _createIndex(CreateIndexStatement s) {
    _checkName(s.name);
    if (!_claimName(s.name, 'index', s.ifNotExists)) return StatementResult();
    final t = catalog.table(s.table);
    if (t == null) {
      if (catalog.view(s.table) != null) {
        throw const SqlException('views may not be indexed');
      }
      throw SqlException.schema('no such table: ${s.table}');
    }
    final positions = <int>[];
    final collations = <Collation>[];
    for (final c in s.columns) {
      final p = t.schema.indexOf(c.name);
      if (p == null) throw SqlException.schema('no such column: ${c.name}');
      positions.add(p);
      final coll = c.collation ?? t.schema.columns[p].collation;
      final parsed =
          Collation.parse(coll) ?? (coll == null ? Collation.binary : null);
      if (parsed == null) {
        throw SqlException('no such collation sequence: $coll');
      }
      collations.add(parsed);
    }
    if (s.spatial) {
      if (positions.length != 2) {
        throw const SqlException(
          'a spatial index needs exactly two columns (x, y)',
        );
      }
      t.addSpatialIndex(
        SpatialIndex(
          name: s.name,
          xColumn: positions[0],
          yColumn: positions[1],
        ),
      );
      catalog.schemaChanged();
      return StatementResult();
    }
    final index = TableIndex(
      name: s.name,
      columns: positions,
      collations: collations,
      unique: s.unique,
      origin: IndexOrigin.manual,
    );
    if (t.addIndex(index) != null) {
      throw SqlException.constraint(_uniqueMessage(t, index));
    }
    catalog.schemaChanged();
    return StatementResult();
  }

  StatementResult _dropIndex(DropIndexStatement s) {
    final found = catalog.index(s.name);
    if (found != null) {
      final (t, i) = found;
      if (i.origin != IndexOrigin.manual) {
        throw const SqlException(
          'index associated with UNIQUE or PRIMARY KEY constraint cannot be dropped',
        );
      }
      t.dropIndex(i);
      catalog.schemaChanged();
      return StatementResult();
    }
    final spatial = catalog.spatialIndex(s.name);
    if (spatial != null) {
      spatial.$1.dropSpatialIndex(spatial.$2);
      catalog.schemaChanged();
      return StatementResult();
    }
    if (s.ifExists) return StatementResult();
    throw SqlException.schema('no such index: ${s.name}');
  }

  // ---------------------------------------------------------------------------
  // Views and triggers
  // ---------------------------------------------------------------------------

  StatementResult _createView(CreateViewStatement s, String sql) {
    _checkName(s.name);
    if (!_claimName(s.name, 'view', s.ifNotExists)) return StatementResult();
    final plan = _compileSelect(s.query, null);
    if (s.columns != null && s.columns!.length != plan.columnNames.length) {
      throw SqlException(
        "expected ${s.columns!.length} columns for '${s.name}' but got ${plan.columnNames.length}",
      );
    }
    catalog.addView(ViewDefinition(name: s.name, sql: sql));
    return StatementResult();
  }

  StatementResult _dropView(DropViewStatement s) {
    final v = catalog.view(s.name);
    if (v == null) {
      if (catalog.table(s.name) != null) {
        throw SqlException('use DROP TABLE to delete table ${s.name}');
      }
      if (s.ifExists) return StatementResult();
      throw SqlException.schema('no such view: ${s.name}');
    }
    for (final trig in catalog.triggers.toList()) {
      if (trig.table.toLowerCase() == v.name.toLowerCase()) {
        catalog.removeTrigger(trig.name);
      }
    }
    catalog.removeView(v.name);
    return StatementResult();
  }

  StatementResult _createTrigger(CreateTriggerStatement s, String sql) {
    _checkName(s.name);
    if (catalog.trigger(s.name) != null) {
      if (s.ifNotExists) return StatementResult();
      throw SqlException.schema('trigger ${s.name} already exists');
    }
    final t = catalog.table(s.table);
    final v = t == null ? catalog.view(s.table) : null;
    if (t == null && v == null) {
      throw SqlException.schema('no such table: ${s.table}');
    }
    if (t != null && s.timing == TriggerTiming.insteadOf) {
      throw SqlException(
        'cannot create INSTEAD OF trigger on table: ${s.table}',
      );
    }
    if (v != null && s.timing != TriggerTiming.insteadOf) {
      final when = s.timing == TriggerTiming.before ? 'BEFORE' : 'AFTER';
      throw SqlException('cannot create $when trigger on view: ${s.table}');
    }
    final columns = _targetColumns(
      s.table,
    ).$1.map((c) => c.toLowerCase()).toSet();
    for (final c in s.updateOf ?? const <String>[]) {
      if (!columns.contains(c.toLowerCase())) {
        throw SqlException.schema('no such column: $c');
      }
    }
    catalog.addTrigger(
      TriggerDefinition(name: s.name, table: t?.name ?? v!.name, sql: sql),
    );
    return StatementResult();
  }

  StatementResult _dropTrigger(DropTriggerStatement s) {
    if (catalog.trigger(s.name) == null) {
      if (s.ifExists) return StatementResult();
      throw SqlException.schema('no such trigger: ${s.name}');
    }
    catalog.removeTrigger(s.name);
    return StatementResult();
  }
}

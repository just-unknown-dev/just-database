part of 'engine.dart';

/// A trigger, compiled.
final class _TriggerPlan {
  _TriggerPlan(this.def, this.stmt, this.updateOf, this.when, this.body);
  final TriggerDefinition def;
  final CreateTriggerStatement stmt;

  /// For `UPDATE OF cols`: their positions.
  final Set<int>? updateOf;
  final _Eval? when;
  final List<void Function(_Frame)> body;
}

/// A foreign key check left for the end of the statement (NO ACTION).
final class _PendingFk {
  _PendingFk(this.child, this.fk, this.parent, this.key);
  final TableData child;
  final ForeignKeyDefinition fk;
  final TableData parent;
  final List<Object?> key;
}

/// Thrown by `RAISE(IGNORE)`: abandon the current row.
final class _IgnoreRow implements Exception {
  const _IgnoreRow();
}

final _defaultCache = Expando<_Eval>();
final _checkCache = Expando<List<(String, _Eval)>>();

extension _Dml on Engine {
  // ---------------------------------------------------------------------------
  // Errors and conflicts
  // ---------------------------------------------------------------------------

  /// Throws [message] the way [action] ends a statement.
  Never _fail(ConflictAction action, String message) {
    final e = SqlException.constraint(message);
    switch (action) {
      case ConflictAction.fail:
        throw _Fail(e);
      case ConflictAction.rollback:
        throw _RollbackTransaction(e);
      default:
        throw e;
    }
  }

  String _uniqueMessage(TableData t, TableIndex index) {
    final cols = [
      for (final c in index.columns) '${t.name}.${t.schema.columns[c].name}',
    ];
    return 'UNIQUE constraint failed: ${cols.join(', ')}';
  }

  // ---------------------------------------------------------------------------
  // Defaults, checks, values
  // ---------------------------------------------------------------------------

  /// The DEFAULT value of column [i] of [t], with its affinity applied.
  Object? _defaultValue(TableData t, int i) {
    final col = t.schema.columns[i];
    final sql = col.defaultSql;
    if (sql == null) return null;
    var eval = _defaultCache[col];
    if (eval == null) {
      final parsed = Parser.parseExpression(sql);
      eval = _withSource<_Eval>(
        sql,
        () => _compile(parsed, _Ctx(_Scope(const [], null))).eval,
      );
      _defaultCache[col] = eval;
    }
    return applyAffinity(eval(_Frame(0, null)), col.affinity);
  }

  List<(String, _Eval)> _checks(TableData t) {
    final cached = _checkCache[t.schema];
    if (cached != null) return cached;
    final scope = _Scope([_Source.table(t, null)], null);
    final out = <(String, _Eval)>[];
    for (final c in t.schema.constraints) {
      if (c.kind != TableConstraintKind.check) continue;
      final sql = c.checkSql!;
      final e = Parser.parseExpression(sql);
      final eval = _withSource(sql, () => _compile(e, _Ctx(scope)).eval);
      out.add((c.name ?? sql, eval));
    }
    _checkCache[t.schema] = out;
    return out;
  }

  /// Checks NOT NULL and CHECK on [values] for [t]. Returns false when the
  /// row is to be skipped (IGNORE); may fill a NOT NULL column from its
  /// default (REPLACE).
  bool _validate(
    TableData t,
    List<Object?> values,
    int? rowid,
    ConflictAction action,
  ) {
    final cols = t.schema.columns;
    for (var i = 0; i < cols.length; i++) {
      if (!cols[i].notNull || values[i] != null) continue;
      if (action == ConflictAction.ignore) return false;
      if (action == ConflictAction.replace && cols[i].hasDefault) {
        values[i] = _defaultValue(t, i);
        if (values[i] != null) continue;
      }
      _fail(action, 'NOT NULL constraint failed: ${t.name}.${cols[i].name}');
    }
    final checks = _checks(t);
    if (checks.isNotEmpty) {
      final f = _Frame(1, null);
      f.rows[0] = values;
      f.rowids[0] = rowid;
      for (final (label, eval) in checks) {
        if (truthOf(eval(f)) == false) {
          if (action == ConflictAction.ignore) return false;
          _fail(
            action == ConflictAction.replace ? ConflictAction.abort : action,
            'CHECK constraint failed: $label',
          );
        }
      }
    }
    return true;
  }

  /// The integer a rowid alias value stands for; throws when it is not an
  /// integer.
  int _rowidOf(Object v) {
    if (v is int) return v;
    final n = applyAffinity(v, Affinity.integer);
    if (n is int) return n;
    throw const SqlException('datatype mismatch');
  }

  // ---------------------------------------------------------------------------
  // Triggers
  // ---------------------------------------------------------------------------

  List<_TriggerPlan> _triggers(
    String table,
    TriggerEvent event,
    TriggerTiming timing,
  ) {
    final lower = table.toLowerCase();
    final out = <_TriggerPlan>[];
    for (final def in catalog.triggers) {
      if (def.table.toLowerCase() != lower) continue;
      final plan = _triggerPlan(def);
      if (plan.stmt.event == event && plan.stmt.timing == timing) out.add(plan);
    }
    return out;
  }

  _TriggerPlan _triggerPlan(TriggerDefinition def) {
    final cached = _triggerPlans[def];
    if (cached != null) return cached;
    final parsed = Parser.parseOne(def.sql);
    final stmt = parsed.statement as CreateTriggerStatement;
    final plan = _withSource(parsed.source, () {
      final columns = _targetColumns(stmt.table);
      _Source pseudo(String name) => _Source(
        name: name,
        columns: columns.$1,
        affinities: columns.$2,
        collations: columns.$3,
        declaredTypes: columns.$4,
        qualifiedOnly: true,
      );
      final scope = _Scope([pseudo('new'), pseudo('old')], null);
      Set<int>? updateOf;
      if (stmt.updateOf != null) {
        updateOf = {};
        for (final c in stmt.updateOf!) {
          final i = scope.sources[0].indexOf(c);
          if (i == null) throw SqlException.schema('no such column: $c');
          updateOf.add(i);
        }
      }
      final when = stmt.when == null
          ? null
          : _compile(stmt.when!, _Ctx(scope)).eval;
      final body = <void Function(_Frame)>[];
      for (final s in stmt.body) {
        switch (s) {
          case SelectStatement():
            final p = _compileSelect(s, scope);
            body.add((f) => p.run(f));
          case InsertStatement():
            final run = _compileInsert(s, scope);
            body.add((f) => run(f));
          case UpdateStatement():
            final run = _compileUpdate(s, scope);
            body.add((f) => run(f));
          case DeleteStatement():
            final run = _compileDelete(s, scope);
            body.add((f) => run(f));
          default:
            throw const SqlException('unsupported statement in trigger');
        }
      }
      return _TriggerPlan(def, stmt, updateOf, when, body);
    });
    _triggerPlans[def] = plan;
    return plan;
  }

  /// The columns of a table or view, for NEW/OLD.
  (List<String>, List<Affinity?>, List<Collation>, List<String>) _targetColumns(
    String name,
  ) {
    final t = catalog.table(name);
    if (t != null) {
      final s = _Source.table(t, null);
      return (s.columns, s.affinities, s.collations, s.declaredTypes);
    }
    final v = catalog.view(name);
    if (v != null) {
      final p = _viewPlan(v);
      return (p.columnNames, p.affinities, p.collations, p.declaredTypes);
    }
    throw SqlException.schema('no such table: $name');
  }

  /// Fires [plans] with NEW and OLD rows. Throws [_IgnoreRow] for
  /// `RAISE(IGNORE)`.
  void _fire(
    List<_TriggerPlan> plans,
    List<Object?>? newRow,
    int? newRowid,
    List<Object?>? oldRow,
    int? oldRowid, {
    Set<int>? changed,
  }) {
    for (final plan in plans) {
      if (_activeTriggers.contains(plan.def)) continue; // no recursion
      final of = plan.updateOf;
      if (of != null && changed != null && !of.any(changed.contains)) continue;
      final f = _Frame(2, null);
      f.rows[0] = newRow;
      f.rowids[0] = newRowid;
      f.rows[1] = oldRow;
      f.rowids[1] = oldRowid;
      if (plan.when != null && truthOf(plan.when!(f)) != true) continue;
      if (_triggerDepth >= 1000) {
        throw const SqlException('too many levels of trigger recursion');
      }
      _activeTriggers.add(plan.def);
      _triggerDepth++;
      try {
        for (final step in plan.body) {
          step(f);
        }
      } on _Raise catch (r) {
        switch (r.kind) {
          case RaiseKind.ignore:
            throw const _IgnoreRow();
          case RaiseKind.abort:
            throw SqlException(r.message ?? 'RAISE', kind: SqlErrorKind.raised);
          case RaiseKind.fail:
            throw _Fail(
              SqlException(r.message ?? 'RAISE', kind: SqlErrorKind.raised),
            );
          case RaiseKind.rollback:
            throw _RollbackTransaction(
              SqlException(r.message ?? 'RAISE', kind: SqlErrorKind.raised),
            );
        }
      } finally {
        _triggerDepth--;
        _activeTriggers.remove(plan.def);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Foreign keys
  // ---------------------------------------------------------------------------

  /// Every foreign key that references [parent]: (child table, key).
  List<(TableData, ForeignKeyDefinition)> _referencing(TableData parent) {
    final lower = parent.name.toLowerCase();
    return [
      for (final t in catalog.tables)
        for (final fk in t.schema.foreignKeys)
          if (fk.parentTable.toLowerCase() == lower) (t, fk),
    ];
  }

  /// The positions of the parent key [fk] references in [parent]. Throws
  /// "foreign key mismatch" when they are not the primary key or a UNIQUE
  /// key.
  List<int> _parentKey(
    TableData parent,
    ForeignKeyDefinition fk,
    String child,
  ) {
    final names = fk.parentColumns.isEmpty
        ? parent.schema.primaryKey
        : fk.parentColumns;
    final positions = <int>[];
    for (final n in names) {
      final p = parent.schema.indexOf(n);
      if (p == null) positions.clear();
      if (p == null) break;
      positions.add(p);
    }
    final alias = parent.schema.rowidAlias;
    final ok =
        positions.length == fk.columns.length &&
        positions.isNotEmpty &&
        ((positions.length == 1 && positions.single == alias) ||
            parent.indexes.any(
              (i) =>
                  i.unique &&
                  i.columns.length == positions.length &&
                  i.columns.toSet().containsAll(positions),
            ));
    if (!ok) {
      throw SqlException(
        'foreign key mismatch - "$child" referencing "${parent.name}"',
      );
    }
    return positions;
  }

  /// Whether [parent] has a row whose key columns [keyCols] equal [key].
  bool _parentExists(TableData parent, List<int> keyCols, List<Object?> key) {
    final values = [
      for (var i = 0; i < keyCols.length; i++)
        applyAffinity(key[i], parent.schema.columns[keyCols[i]].affinity),
    ];
    if (keyCols.length == 1 && keyCols.single == parent.schema.rowidAlias) {
      final v = values.single;
      return v is int && parent.row(v) != null;
    }
    for (final idx in parent.indexes) {
      if (!idx.unique || idx.columns.length != keyCols.length) continue;
      final ordered = <Object?>[];
      for (final c in idx.columns) {
        final at = keyCols.indexOf(c);
        if (at < 0) break;
        ordered.add(values[at]);
      }
      if (ordered.length != keyCols.length) continue;
      final k = idx.keyOfValues(ordered);
      return k != null && idx.lookup(k).isNotEmpty;
    }
    return false;
  }

  /// The rowids of [child] rows whose [fk] columns equal [key].
  List<int> _childRows(
    TableData child,
    ForeignKeyDefinition fk,
    List<Object?> key,
  ) {
    final positions = [for (final c in fk.columns) child.schema.indexOf(c)!];
    final values = [
      for (var i = 0; i < positions.length; i++)
        applyAffinity(key[i], child.schema.columns[positions[i]].affinity),
    ];
    if (values.contains(null)) return const [];
    final index = child.foreignKeyIndex(positions);
    if (index != null) {
      final k = index.keyOfValues(values);
      if (k == null) return const [];
      final ids = index.lookup(k).toList()..sort();
      return ids;
    }
    final want = [for (final v in values) keyOf(v)];
    return [
      for (final e in child.entries)
        if (() {
          for (var i = 0; i < positions.length; i++) {
            final v = e.value[positions[i]];
            if (v == null || keyOf(v) != want[i]) return false;
          }
          return true;
        }())
          e.key,
    ];
  }

  /// Checks that a child row's foreign keys point at existing parents.
  void _checkChild(
    TableData t,
    List<Object?> values,
    ConflictAction action, {
    List<Object?>? old,
  }) {
    if (!foreignKeys) return;
    for (final fk in t.schema.foreignKeys) {
      final positions = [for (final c in fk.columns) t.schema.indexOf(c)!];
      final key = [for (final p in positions) values[p]];
      if (key.contains(null)) continue;
      if (old != null &&
          positions.every(
            (p) => compareValues(old[p], values[p]) == 0 && old[p] != null,
          )) {
        continue; // unchanged
      }
      final parent = catalog.table(fk.parentTable);
      if (parent == null) {
        _fail(action, 'FOREIGN KEY constraint failed');
      }
      final keyCols = _parentKey(parent, fk, t.name);
      if (!_parentExists(parent, keyCols, key)) {
        _fail(action, 'FOREIGN KEY constraint failed');
      }
    }
  }

  /// Applies the ON DELETE actions of every key referencing [row] of
  /// [parent].
  void _parentDeleted(TableData parent, List<Object?> row) {
    if (!foreignKeys) return;
    for (final (child, fk) in _referencing(parent)) {
      final keyCols = _parentKey(parent, fk, child.name);
      final key = [for (final c in keyCols) row[c]];
      if (key.contains(null)) continue;
      final children = _childRows(child, fk, key);
      if (children.isEmpty) continue;
      switch (fk.onDelete) {
        case ForeignKeyAction.restrict:
          throw const SqlException.constraint('FOREIGN KEY constraint failed');
        case ForeignKeyAction.noAction:
          _pendingFks.add(_PendingFk(child, fk, parent, key));
        case ForeignKeyAction.cascade:
          for (final id in children) {
            if (child.row(id) != null) _deleteRow(child, id);
          }
        case ForeignKeyAction.setNull:
        case ForeignKeyAction.setDefault:
          _setChildKeys(child, fk, children, null, fk.onDelete);
      }
    }
  }

  /// Applies the ON UPDATE actions when [parent]'s row changed from [old]
  /// to [values].
  void _parentUpdated(
    TableData parent,
    List<Object?> old,
    List<Object?> values,
  ) {
    if (!foreignKeys) return;
    for (final (child, fk) in _referencing(parent)) {
      final keyCols = _parentKey(parent, fk, child.name);
      final oldKey = [for (final c in keyCols) old[c]];
      final newKey = [for (final c in keyCols) values[c]];
      var same = true;
      for (var i = 0; i < keyCols.length; i++) {
        final a = oldKey[i], b = newKey[i];
        if (a == null || b == null) {
          if (a != b) same = false;
        } else if (compareValues(a, b) != 0 || typeOf(a) != typeOf(b)) {
          same = false;
        }
      }
      if (same || oldKey.contains(null)) continue;
      final children = _childRows(child, fk, oldKey);
      if (children.isEmpty) continue;
      switch (fk.onUpdate) {
        case ForeignKeyAction.restrict:
          throw const SqlException.constraint('FOREIGN KEY constraint failed');
        case ForeignKeyAction.noAction:
          _pendingFks.add(_PendingFk(child, fk, parent, oldKey));
        case ForeignKeyAction.cascade:
          _setChildKeys(child, fk, children, newKey, fk.onUpdate);
        case ForeignKeyAction.setNull:
        case ForeignKeyAction.setDefault:
          _setChildKeys(child, fk, children, null, fk.onUpdate);
      }
    }
  }

  void _setChildKeys(
    TableData child,
    ForeignKeyDefinition fk,
    List<int> rowids,
    List<Object?>? newKey,
    ForeignKeyAction action,
  ) {
    final positions = [for (final c in fk.columns) child.schema.indexOf(c)!];
    for (final id in rowids) {
      final old = child.row(id);
      if (old == null) continue;
      final values = List<Object?>.of(old);
      for (var i = 0; i < positions.length; i++) {
        final p = positions[i];
        values[p] = switch (action) {
          ForeignKeyAction.cascade => applyAffinity(
            newKey![i],
            child.schema.columns[p].affinity,
          ),
          ForeignKeyAction.setDefault => _defaultValue(child, p),
          _ => null,
        };
      }
      var newRowid = id;
      final alias = child.schema.rowidAlias;
      if (alias != null && values[alias] != null) {
        newRowid = _rowidOf(values[alias]!);
      }
      _updateRow(
        child,
        id,
        values,
        newRowid,
        ConflictAction.abort,
        changed: positions.toSet(),
      );
    }
  }

  /// Checks the NO ACTION foreign keys left for the end of the statement.
  void _checkPendingForeignKeys() {
    if (_pendingFks.isEmpty) return;
    final pending = List.of(_pendingFks);
    _pendingFks.clear();
    for (final p in pending) {
      final keyCols = _parentKey(p.parent, p.fk, p.child.name);
      if (_parentExists(p.parent, keyCols, p.key)) continue;
      if (_childRows(p.child, p.fk, p.key).isNotEmpty) {
        throw const SqlException.constraint('FOREIGN KEY constraint failed');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Row operations shared by statements, triggers and FK actions
  // ---------------------------------------------------------------------------

  /// Deletes row [rowid] of [t] with its triggers and FK actions. Returns
  /// false when a BEFORE trigger ignored it.
  bool _deleteRow(TableData t, int rowid) {
    final old = t.row(rowid);
    if (old == null) return false;
    try {
      _fire(
        _triggers(t.name, TriggerEvent.delete, TriggerTiming.before),
        null,
        null,
        old,
        rowid,
      );
    } on _IgnoreRow {
      return false;
    }
    if (t.row(rowid) == null) return false; // a trigger removed it
    _parentDeleted(t, old);
    if (t.row(rowid) == null) return false;
    t.delete(rowid);
    try {
      _fire(
        _triggers(t.name, TriggerEvent.delete, TriggerTiming.after),
        null,
        null,
        old,
        rowid,
      );
    } on _IgnoreRow {
      // The row is already gone; IGNORE only skips the remaining triggers.
    }
    return true;
  }

  /// Resolves UNIQUE conflicts of [values] (as row [rowid], ignoring
  /// [except]) by [action]. Returns false when the row is to be skipped.
  bool _resolveConflicts(
    TableData t,
    List<Object?> values,
    int rowid,
    int? except,
    ConflictAction action,
  ) {
    while (true) {
      String? message;
      int? other;
      if (rowid != except && t.row(rowid) != null) {
        other = rowid;
        final alias = t.schema.rowidAlias;
        message = alias == null
            ? 'UNIQUE constraint failed: ${t.name}.rowid'
            : 'UNIQUE constraint failed: ${t.name}.${t.schema.columns[alias].name}';
      } else {
        final c = t.uniqueConflict(values, except: except);
        if (c == null) return true;
        other = c.$2;
        message = _uniqueMessage(t, c.$1);
      }
      switch (action) {
        case ConflictAction.ignore:
          return false;
        case ConflictAction.replace:
          // REPLACE deletes the conflicting row (without its delete
          // triggers, as SQLite without recursive_triggers).
          final old = t.row(other)!;
          _parentDeleted(t, old);
          if (t.row(other) != null) t.delete(other);
        default:
          _fail(action, message);
      }
    }
  }

  /// Updates row [rowid] of [t] to [values] (moving it to [newRowid]),
  /// with checks, triggers and FK actions. Returns false when skipped.
  bool _updateRow(
    TableData t,
    int rowid,
    List<Object?> values,
    int newRowid,
    ConflictAction action, {
    Set<int>? changed,
  }) {
    final old = t.row(rowid);
    if (old == null) return false;
    try {
      _fire(
        _triggers(t.name, TriggerEvent.update, TriggerTiming.before),
        values,
        newRowid,
        old,
        rowid,
        changed: changed,
      );
    } on _IgnoreRow {
      return false;
    }
    if (t.row(rowid) == null) return false;
    if (!_validate(t, values, newRowid, action)) return false;
    if (!_resolveConflicts(t, values, newRowid, rowid, action)) return false;
    if (t.row(rowid) == null) return false;
    _checkChild(t, values, action, old: old);
    if (t.row(rowid) == null) return false;
    t.update(rowid, values, newRowid: newRowid);
    // ON UPDATE actions run once the new key is stored, so cascaded child
    // rows find it; a RESTRICT failure undoes the whole statement.
    _parentUpdated(t, old, values);
    try {
      _fire(
        _triggers(t.name, TriggerEvent.update, TriggerTiming.after),
        values,
        newRowid,
        old,
        rowid,
        changed: changed,
      );
    } on _IgnoreRow {
      // Already updated.
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // INSERT
  // ---------------------------------------------------------------------------

  StatementResult _insert(InsertStatement s) {
    final run = _compileInsert(s, null);
    final changes = run(null);
    lastChanges = changes;
    totalChanges += changes;
    return StatementResult(changes: changes, lastInsertRowId: lastInsertRowId);
  }

  int Function(_Frame?) _compileInsert(InsertStatement s, _Scope? parent) {
    final table = catalog.table(s.table);
    if (table == null) {
      if (catalog.view(s.table) != null) return _compileViewInsert(s, parent);
      throw SqlException.schema('no such table: ${s.table}');
    }
    final schema = table.schema;
    final ncols = schema.columns.length;
    // Target columns.
    List<int> cols;
    if (s.columns == null) {
      cols = [for (var i = 0; i < ncols; i++) i];
    } else {
      cols = [];
      for (final name in s.columns!) {
        final i = schema.indexOf(name);
        if (i == null) {
          if (_rowidNames.contains(name.toLowerCase())) {
            cols.add(-1);
            continue;
          }
          throw SqlException.schema(
            'table ${schema.name} has no column named $name',
          );
        }
        if (cols.contains(i)) {
          throw SqlException(
            'column ${schema.columns[i].name} specified more than once',
          );
        }
        cols.add(i);
      }
    }
    // Source rows.
    final valueScope = _Scope(const [], parent);
    List<List<_Eval>>? valueRows;
    _SelectPlan? select;
    if (s.values != null) {
      valueRows = [];
      for (final row in s.values!) {
        if (row.length != cols.length) {
          throw SqlException(
            s.columns == null
                ? 'table ${schema.name} has ${cols.length} columns but ${row.length} values were supplied'
                : '${row.length} values for ${cols.length} columns',
          );
        }
        final ctx = _Ctx(valueScope);
        valueRows.add([for (final e in row) _compile(e, ctx).eval]);
      }
    } else if (s.select != null) {
      select = _compileSelect(s.select!, parent);
      if (select.columnNames.length != cols.length) {
        throw SqlException(
          s.columns == null
              ? 'table ${schema.name} has ${cols.length} columns but ${select.columnNames.length} values were supplied'
              : '${select.columnNames.length} values for ${cols.length} columns',
        );
      }
    }
    // Upsert.
    final upsert = s.upsert;
    List<(int, _Eval)>? upsertSets;
    _Eval? upsertWhere;
    List<int>? upsertTarget;
    if (upsert != null) {
      if (upsert.target != null) {
        upsertTarget = [];
        for (final c in upsert.target!) {
          final i = schema.indexOf(c);
          if (i == null) throw SqlException.schema('no such column: $c');
          upsertTarget.add(i);
        }
        final targetSet = upsertTarget.toSet();
        final matches =
            (upsertTarget.length == 1 &&
                upsertTarget.single == schema.rowidAlias) ||
            table.indexes.any(
              (i) =>
                  i.unique &&
                  i.columns.length == targetSet.length &&
                  targetSet.containsAll(i.columns),
            );
        if (!matches) {
          throw const SqlException(
            'ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE constraint',
          );
        }
      }
      if (!upsert.doNothing) {
        final base = _Source.table(table, 'excluded');
        // `excluded.x` only: bare names mean the target table, as in SQLite.
        final excluded = _Source(
          name: 'excluded',
          columns: base.columns,
          affinities: base.affinities,
          collations: base.collations,
          declaredTypes: base.declaredTypes,
          qualifiedOnly: true,
        );
        final scope = _Scope([_Source.table(table, null), excluded], parent);
        upsertSets = [];
        for (final a in upsert.sets) {
          final i = schema.indexOf(a.column);
          if (i == null) {
            throw SqlException.schema('no such column: ${a.column}');
          }
          upsertSets.add((i, _compile(a.value, _Ctx(scope)).eval));
        }
        if (upsert.where != null) {
          upsertWhere = _compile(upsert.where!, _Ctx(scope)).eval;
        }
      }
    }
    final action = s.conflict;
    final alias = schema.rowidAlias;

    return (parentFrame) {
      final pf = _Frame(0, parentFrame);
      final source = <List<Object?>>[
        if (valueRows != null)
          for (final r in valueRows) [for (final e in r) e(pf)],
        if (select != null) ...select.run(parentFrame),
        if (valueRows == null && select == null) const [],
      ];
      final before = _triggers(
        table.name,
        TriggerEvent.insert,
        TriggerTiming.before,
      );
      final after = _triggers(
        table.name,
        TriggerEvent.insert,
        TriggerTiming.after,
      );
      var changes = 0;
      for (final row in source) {
        final values = List<Object?>.filled(ncols, null);
        final given = List<bool>.filled(ncols, false);
        int? explicitRowid;
        for (var k = 0; k < cols.length; k++) {
          final c = cols[k];
          final v = bindValue(row.isEmpty ? null : row[k]);
          if (c == -1) {
            if (v != null) explicitRowid = _rowidOf(v);
            continue;
          }
          values[c] = applyAffinity(v, schema.columns[c].affinity);
          given[c] = true;
        }
        for (var i = 0; i < ncols; i++) {
          if (!given[i] && i != alias) values[i] = _defaultValue(table, i);
        }
        int? rowid = explicitRowid;
        if (alias != null) {
          final v = values[alias];
          if (v != null) {
            rowid = _rowidOf(v);
            values[alias] = rowid;
          } else if (rowid != null) {
            values[alias] = rowid;
          }
        }
        try {
          _fire(before, values, rowid, null, null);
        } on _IgnoreRow {
          continue;
        }
        rowid ??= table.newRowId();
        if (alias != null) values[alias] = rowid;
        if (!_validate(table, values, rowid, action)) continue;
        // Upsert and conflicts.
        if (upsert != null) {
          final conflict = _upsertConflict(table, values, rowid, upsertTarget);
          if (conflict != null) {
            if (upsert.doNothing) continue;
            final old = table.row(conflict)!;
            final f = _Frame(2, parentFrame);
            f.rows[0] = old;
            f.rowids[0] = conflict;
            f.rows[1] = values;
            f.rowids[1] = rowid;
            if (upsertWhere != null && truthOf(upsertWhere(f)) != true) {
              continue;
            }
            final updated = List<Object?>.of(old);
            for (final (i, e) in upsertSets!) {
              updated[i] = applyAffinity(e(f), schema.columns[i].affinity);
            }
            var newRowid = conflict;
            if (alias != null && updated[alias] != null) {
              newRowid = _rowidOf(updated[alias]!);
              updated[alias] = newRowid;
            }
            if (_updateRow(
              table,
              conflict,
              updated,
              newRowid,
              ConflictAction.abort,
              changed: {for (final (i, _) in upsertSets) i},
            )) {
              changes++;
            }
            continue;
          }
        }
        if (!_resolveConflicts(table, values, rowid, null, action)) continue;
        _checkChild(table, values, action);
        table.insert(rowid, values);
        lastInsertRowId = rowid;
        changes++;
        try {
          _fire(after, values, rowid, null, null);
        } on _IgnoreRow {
          // The row stays.
        }
      }
      return changes;
    };
  }

  /// The rowid of the row an upsert conflicts with, or null.
  int? _upsertConflict(
    TableData t,
    List<Object?> values,
    int rowid,
    List<int>? target,
  ) {
    final alias = t.schema.rowidAlias;
    if (target == null || (target.length == 1 && target.single == alias)) {
      if (t.row(rowid) != null) return rowid;
      if (target != null) return null;
    }
    for (final idx in t.indexes) {
      if (!idx.unique) continue;
      if (target != null &&
          !(idx.columns.length == target.length &&
              target.toSet().containsAll(idx.columns))) {
        continue;
      }
      final other = idx.conflict(values);
      if (other != null) return other;
    }
    return null;
  }

  int Function(_Frame?) _compileViewInsert(InsertStatement s, _Scope? parent) {
    final triggers = _triggers(
      s.table,
      TriggerEvent.insert,
      TriggerTiming.insteadOf,
    );
    if (triggers.isEmpty) {
      throw SqlException('cannot modify ${s.table} because it is a view');
    }
    final columns = _targetColumns(s.table).$1;
    final cols = <int>[];
    for (final name in s.columns ?? columns) {
      final i = columns.indexWhere(
        (c) => c.toLowerCase() == name.toLowerCase(),
      );
      if (i < 0) {
        throw SqlException.schema('table ${s.table} has no column named $name');
      }
      cols.add(i);
    }
    final valueScope = _Scope(const [], parent);
    final valueRows = s.values == null
        ? null
        : [
            for (final r in s.values!)
              [for (final e in r) _compile(e, _Ctx(valueScope)).eval],
          ];
    final select = s.select == null ? null : _compileSelect(s.select!, parent);
    return (parentFrame) {
      final pf = _Frame(0, parentFrame);
      final source = <List<Object?>>[
        if (valueRows != null)
          for (final r in valueRows) [for (final e in r) e(pf)],
        if (select != null) ...select.run(parentFrame),
      ];
      var changes = 0;
      for (final row in source) {
        if (row.length != cols.length) {
          throw SqlException('${row.length} values for ${cols.length} columns');
        }
        final values = List<Object?>.filled(columns.length, null);
        for (var k = 0; k < cols.length; k++) {
          values[cols[k]] = bindValue(row[k]);
        }
        try {
          _fire(triggers, values, null, null, null);
          changes++;
        } on _IgnoreRow {
          continue;
        }
      }
      return changes;
    };
  }

  // ---------------------------------------------------------------------------
  // UPDATE
  // ---------------------------------------------------------------------------

  StatementResult _update(UpdateStatement s) {
    final changes = _compileUpdate(s, null)(null);
    lastChanges = changes;
    totalChanges += changes;
    return StatementResult(changes: changes);
  }

  /// Compiles the WHERE of an UPDATE/DELETE on [table]: the filter and the
  /// candidate rowids it allows.
  (_Eval?, List<int> Function(_Frame)) _compileTarget(
    TableData table,
    String? alias,
    Expr? where,
    _Scope scope,
  ) {
    if (where != null && _containsAggregate(where)) {
      throw const SqlException('misuse of aggregate function in WHERE');
    }
    final conjuncts = <_Conjunct>[];
    for (final c in _conjuncts(where)) {
      final ctx = _Ctx(scope);
      final compiled = _compile(c, ctx);
      conjuncts.add(_Conjunct(c, compiled, ctx.sources, ctx.volatile));
    }
    final level = _Level(_FromEntry(scope.sources.first, table: table));
    _planFirstLevel(level, conjuncts, scope, const []);
    final filters = [for (final c in conjuncts) c.compiled.eval];
    return (
      filters.isEmpty
          ? null
          : (f) {
              for (final e in filters) {
                if (truthOf(e(f)) != true) return 0;
              }
              return 1;
            },
      (f) {
        final picked = _firstLevelRows(level, f);
        final ids = <int>[];
        for (final e in picked ?? table.entries) {
          f.rows[0] = e.value;
          f.rowids[0] = e.key;
          if (filters.every((x) => truthOf(x(f)) == true)) ids.add(e.key);
        }
        f.rows[0] = null;
        f.rowids[0] = null;
        return ids;
      },
    );
  }

  int Function(_Frame?) _compileUpdate(UpdateStatement s, _Scope? parent) {
    final table = catalog.table(s.table);
    if (table == null) {
      if (catalog.view(s.table) != null) return _compileViewUpdate(s, parent);
      throw SqlException.schema('no such table: ${s.table}');
    }
    final schema = table.schema;
    final scope = _Scope([_Source.table(table, s.alias)], parent);
    final sets = <(int, _Eval)>[];
    for (final a in s.sets) {
      var i = schema.indexOf(a.column);
      if (i == null) {
        if (_rowidNames.contains(a.column.toLowerCase())) {
          i = -1;
        } else {
          throw SqlException.schema('no such column: ${a.column}');
        }
      }
      if (_containsAggregate(a.value)) {
        throw const SqlException('misuse of aggregate function in UPDATE');
      }
      sets.add((i, _compile(a.value, _Ctx(scope)).eval));
    }
    final (_, candidates) = _compileTarget(table, s.alias, s.where, scope);
    final alias = schema.rowidAlias;
    final changedCols = {
      for (final (i, _) in sets) i == -1 ? (alias ?? -1) : i,
    };
    final action = s.conflict;
    return (parentFrame) {
      final f = _Frame(1, parentFrame);
      final ids = candidates(f);
      var changes = 0;
      for (final id in ids) {
        final old = table.row(id);
        if (old == null) continue;
        f.rows[0] = old;
        f.rowids[0] = id;
        final values = List<Object?>.of(old);
        var newRowid = id;
        Object? rowidValue;
        var rowidSet = false;
        for (final (i, e) in sets) {
          final v = e(f);
          if (i == -1) {
            rowidValue = v;
            rowidSet = true;
          } else {
            values[i] = applyAffinity(v, schema.columns[i].affinity);
          }
        }
        if (rowidSet) {
          if (rowidValue == null) throw const SqlException('datatype mismatch');
          newRowid = _rowidOf(rowidValue);
          if (alias != null) values[alias] = newRowid;
        }
        if (alias != null) {
          final v = values[alias];
          if (v == null) {
            // Setting an INTEGER PRIMARY KEY to NULL picks a new rowid.
            newRowid = table.newRowId();
            values[alias] = newRowid;
          } else {
            newRowid = _rowidOf(v);
            values[alias] = newRowid;
          }
        }
        if (_updateRow(
          table,
          id,
          values,
          newRowid,
          action,
          changed: changedCols,
        )) {
          changes++;
        }
      }
      f.rows[0] = null;
      return changes;
    };
  }

  int Function(_Frame?) _compileViewUpdate(UpdateStatement s, _Scope? parent) {
    final triggers = _triggers(
      s.table,
      TriggerEvent.update,
      TriggerTiming.insteadOf,
    );
    if (triggers.isEmpty) {
      throw SqlException('cannot modify ${s.table} because it is a view');
    }
    final v = catalog.view(s.table)!;
    final plan = _viewPlan(v);
    final src = _Source(
      name: s.alias ?? v.name,
      columns: plan.columnNames,
      affinities: plan.affinities,
      collations: plan.collations,
      declaredTypes: plan.declaredTypes,
    );
    final scope = _Scope([src], parent);
    final sets = <(int, _Eval)>[];
    for (final a in s.sets) {
      final i = src.indexOf(a.column);
      if (i == null) throw SqlException.schema('no such column: ${a.column}');
      sets.add((i, _compile(a.value, _Ctx(scope)).eval));
    }
    final where = s.where == null ? null : _compile(s.where!, _Ctx(scope)).eval;
    final changed = {for (final (i, _) in sets) i};
    return (parentFrame) {
      final f = _Frame(1, parentFrame);
      var changes = 0;
      for (final row in plan.run(null)) {
        f.rows[0] = row;
        if (where != null && truthOf(where(f)) != true) continue;
        final values = List<Object?>.of(row);
        for (final (i, e) in sets) {
          values[i] = e(f);
        }
        try {
          _fire(triggers, values, null, row, null, changed: changed);
          changes++;
        } on _IgnoreRow {
          continue;
        }
      }
      return changes;
    };
  }

  // ---------------------------------------------------------------------------
  // DELETE
  // ---------------------------------------------------------------------------

  StatementResult _delete(DeleteStatement s) {
    final changes = _compileDelete(s, null)(null);
    lastChanges = changes;
    totalChanges += changes;
    return StatementResult(changes: changes);
  }

  int Function(_Frame?) _compileDelete(DeleteStatement s, _Scope? parent) {
    final table = catalog.table(s.table);
    if (table == null) {
      if (catalog.view(s.table) != null) return _compileViewDelete(s, parent);
      throw SqlException.schema('no such table: ${s.table}');
    }
    final scope = _Scope([_Source.table(table, s.alias)], parent);
    final (_, candidates) = _compileTarget(table, s.alias, s.where, scope);
    final truncate = s.where == null;
    return (parentFrame) {
      if (truncate &&
          _triggers(
            table.name,
            TriggerEvent.delete,
            TriggerTiming.before,
          ).isEmpty &&
          _triggers(
            table.name,
            TriggerEvent.delete,
            TriggerTiming.after,
          ).isEmpty &&
          (!foreignKeys || _referencing(table).isEmpty)) {
        return table.clear();
      }
      final f = _Frame(1, parentFrame);
      var changes = 0;
      for (final id in candidates(f)) {
        if (_deleteRow(table, id)) changes++;
      }
      return changes;
    };
  }

  int Function(_Frame?) _compileViewDelete(DeleteStatement s, _Scope? parent) {
    final triggers = _triggers(
      s.table,
      TriggerEvent.delete,
      TriggerTiming.insteadOf,
    );
    if (triggers.isEmpty) {
      throw SqlException('cannot modify ${s.table} because it is a view');
    }
    final v = catalog.view(s.table)!;
    final plan = _viewPlan(v);
    final src = _Source(
      name: s.alias ?? v.name,
      columns: plan.columnNames,
      affinities: plan.affinities,
      collations: plan.collations,
      declaredTypes: plan.declaredTypes,
    );
    final scope = _Scope([src], parent);
    final where = s.where == null ? null : _compile(s.where!, _Ctx(scope)).eval;
    return (parentFrame) {
      final f = _Frame(1, parentFrame);
      var changes = 0;
      for (final row in plan.run(null)) {
        f.rows[0] = row;
        if (where != null && truthOf(where(f)) != true) continue;
        try {
          _fire(triggers, null, null, row, null);
          changes++;
        } on _IgnoreRow {
          continue;
        }
      }
      return changes;
    };
  }
}

import 'package:flutter/foundation.dart' show internal;

import 'index.dart';
import 'table.dart';
import 'undo_log.dart';

/// A view: its name and the full `CREATE VIEW` statement.
@internal
final class ViewDefinition {
  /// Creates a view definition.
  const ViewDefinition({required this.name, required this.sql});

  /// The view's name.
  final String name;

  /// The `CREATE VIEW …` statement.
  final String sql;
}

/// A trigger: its name, the table (or view) it is on, and the full
/// `CREATE TRIGGER` statement.
@internal
final class TriggerDefinition {
  /// Creates a trigger definition.
  const TriggerDefinition({
    required this.name,
    required this.table,
    required this.sql,
  });

  /// The trigger's name.
  final String name;

  /// The table or view it is on.
  final String table;

  /// The `CREATE TRIGGER …` statement.
  final String sql;
}

/// Everything a database holds: its tables, views and triggers, and the
/// undo log every change records into.
///
/// Names are case-insensitive. Tables, views and indexes share one
/// namespace, as in SQLite; triggers have their own.
@internal
final class Catalog {
  /// The undo log for statements and transactions.
  final UndoLog log = UndoLog();

  final Map<String, TableData> _tables = {};
  final Map<String, ViewDefinition> _views = {};
  final Map<String, TriggerDefinition> _triggers = {};

  /// Bumped by every schema change, so compiled statements can tell they
  /// are stale.
  int schemaVersion = 0;

  int _userVersion = 0;

  /// `PRAGMA user_version`: a number the application keeps in the file.
  int get userVersion => _userVersion;

  /// Sets [userVersion], recording the undo.
  void setUserVersion(int value) {
    final old = _userVersion;
    _userVersion = value;
    log.record(() => _userVersion = old);
  }

  /// Sets [userVersion] from a file, without recording undo.
  void loadUserVersion(int value) => _userVersion = value;

  /// The tables, in creation order.
  Iterable<TableData> get tables => _tables.values;

  /// The views, in creation order.
  Iterable<ViewDefinition> get views => _views.values;

  /// The triggers, in creation order.
  Iterable<TriggerDefinition> get triggers => _triggers.values;

  /// The table named [name], or null.
  TableData? table(String name) => _tables[name.toLowerCase()];

  /// The view named [name], or null.
  ViewDefinition? view(String name) => _views[name.toLowerCase()];

  /// The trigger named [name], or null.
  TriggerDefinition? trigger(String name) => _triggers[name.toLowerCase()];

  /// The index named [name] and its table, or null.
  (TableData, TableIndex)? index(String name) {
    final lower = name.toLowerCase();
    for (final t in _tables.values) {
      for (final i in t.indexes) {
        if (i.name.toLowerCase() == lower) return (t, i);
      }
    }
    return null;
  }

  /// The spatial index named [name] and its table, or null.
  (TableData, SpatialIndex)? spatialIndex(String name) {
    final lower = name.toLowerCase();
    for (final t in _tables.values) {
      for (final i in t.spatialIndexes) {
        if (i.name.toLowerCase() == lower) return (t, i);
      }
    }
    return null;
  }

  /// What already uses [name] in the table/view/index namespace: `table`,
  /// `view` or `index`; null when it is free.
  String? nameUse(String name) {
    if (table(name) != null) return 'table';
    if (view(name) != null) return 'view';
    if (index(name) != null || spatialIndex(name) != null) return 'index';
    return null;
  }

  void _bump() {
    schemaVersion++;
    // Undoing a schema change is itself a schema change.
    log.record(() => schemaVersion++);
  }

  /// Adds [table].
  void addTable(TableData table) {
    final key = table.name.toLowerCase();
    _tables[key] = table;
    log.touch(table.name);
    _bump();
    log.record(() => _tables.remove(key));
  }

  /// Removes the table named [name] and returns it.
  TableData removeTable(String name) {
    final key = name.toLowerCase();
    final keys = _tables.keys.toList();
    final at = keys.indexOf(key);
    final t = _tables.remove(key)!;
    log.touch(t.name);
    _bump();
    log.record(() => _reinsert(_tables, keys, at, key, t));
    return t;
  }

  /// Renames a table's key after its schema was renamed (the table object
  /// is kept).
  void rekeyTable(String oldName, TableData table) {
    final oldKey = oldName.toLowerCase();
    final newKey = table.name.toLowerCase();
    final keys = _tables.keys.toList();
    final at = keys.indexOf(oldKey);
    _tables.remove(oldKey);
    _tables[newKey] = table;
    log
      ..touch(oldName)
      ..touch(table.name);
    _bump();
    log.record(() {
      _tables.remove(newKey);
      _reinsert(_tables, keys, at, oldKey, table);
    });
  }

  /// Adds [view].
  void addView(ViewDefinition view) {
    final key = view.name.toLowerCase();
    _views[key] = view;
    _bump();
    log.record(() => _views.remove(key));
  }

  /// Removes the view named [name] and returns it.
  ViewDefinition removeView(String name) {
    final key = name.toLowerCase();
    final keys = _views.keys.toList();
    final at = keys.indexOf(key);
    final v = _views.remove(key)!;
    _bump();
    log.record(() => _reinsert(_views, keys, at, key, v));
    return v;
  }

  /// Adds [trigger], replacing none.
  void addTrigger(TriggerDefinition trigger) {
    final key = trigger.name.toLowerCase();
    _triggers[key] = trigger;
    _bump();
    log.record(() => _triggers.remove(key));
  }

  /// Removes the trigger named [name] and returns it.
  TriggerDefinition removeTrigger(String name) {
    final key = name.toLowerCase();
    final keys = _triggers.keys.toList();
    final at = keys.indexOf(key);
    final t = _triggers.remove(key)!;
    _bump();
    log.record(() => _reinsert(_triggers, keys, at, key, t));
    return t;
  }

  /// Replaces a trigger's definition (its table was renamed).
  void replaceTrigger(TriggerDefinition trigger) {
    final key = trigger.name.toLowerCase();
    final old = _triggers[key]!;
    _triggers[key] = trigger;
    _bump();
    log.record(() => _triggers[key] = old);
  }

  /// Replaces a view's definition (a table it uses was renamed).
  void replaceView(ViewDefinition view) {
    final key = view.name.toLowerCase();
    final old = _views[key]!;
    _views[key] = view;
    _bump();
    log.record(() => _views[key] = old);
  }

  /// Notes a schema change made inside a table (columns, indexes).
  void schemaChanged() => _bump();

  /// Adds a table read from a file, without recording undo.
  void loadTable(TableData table) => _tables[table.name.toLowerCase()] = table;

  /// Adds a view read from a file, without recording undo.
  void loadView(ViewDefinition view) => _views[view.name.toLowerCase()] = view;

  /// Adds a trigger read from a file, without recording undo.
  void loadTrigger(TriggerDefinition trigger) =>
      _triggers[trigger.name.toLowerCase()] = trigger;

  /// Removes everything, without recording undo (used before a restore).
  void clearAll() {
    _userVersion = 0;
    _tables.clear();
    _views.clear();
    _triggers.clear();
    schemaVersion++;
  }

  /// Puts [value] back at its old position [at] among [keys], keeping the
  /// creation order the listing shows.
  static void _reinsert<V>(
    Map<String, V> map,
    List<String> keys,
    int at,
    String key,
    V value,
  ) {
    final entries = map.entries.toList();
    map.clear();
    var placed = false;
    var i = 0;
    for (final e in entries) {
      if (!placed && keys.indexOf(e.key) > at) {
        map[key] = value;
        placed = true;
      }
      map[e.key] = e.value;
      i++;
    }
    if (!placed) map[key] = value;
    assert(i == entries.length);
  }
}

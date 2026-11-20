/// What the admin screen shows: a database, maybe one of its objects, and
/// which pane of it.
@internal
library;

import 'package:flutter/foundation.dart' show immutable, internal;

/// The kinds of database object the screen can show.
@internal
enum AdminObjectKind {
  table,
  view,
  trigger;

  /// The kind's name for people.
  String get label => switch (this) {
    table => 'Table',
    view => 'View',
    trigger => 'Trigger',
  };
}

/// The panes of a selection.
@internal
enum AdminPane {
  overview,
  data,
  structure,
  sql;

  /// The pane's tab label for an object of [kind] (null: the database).
  String labelFor(AdminObjectKind? kind) => switch (this) {
    overview => 'Overview',
    data => 'Data',
    structure => kind == AdminObjectKind.table ? 'Structure' : 'Definition',
    sql => 'SQL',
  };

  /// The panes an object of [kind] has (null: the database itself).
  static List<AdminPane> panesFor(AdminObjectKind? kind) => switch (kind) {
    null => const [overview, sql],
    AdminObjectKind.table => const [data, structure, sql],
    AdminObjectKind.view => const [data, structure, sql],
    AdminObjectKind.trigger => const [structure, sql],
  };
}

/// A database, an optional object of it, and the pane showing them.
@internal
@immutable
final class AdminSelection {
  /// Creates a selection; [pane] defaults to the first pane of [kind].
  AdminSelection(this.database, {this.kind, this.object, AdminPane? pane})
    : assert((kind == null) == (object == null)),
      pane = pane != null && AdminPane.panesFor(kind).contains(pane)
          ? pane
          : AdminPane.panesFor(kind).first;

  /// The database's name.
  final String database;

  /// The kind of [object], or null when the database itself is selected.
  final AdminObjectKind? kind;

  /// The object's name, or null.
  final String? object;

  /// The pane shown.
  final AdminPane pane;

  /// This selection showing [pane].
  AdminSelection withPane(AdminPane pane) =>
      AdminSelection(database, kind: kind, object: object, pane: pane);

  /// Whether this selects the object [name] of [kind] in [db] (names
  /// ignore case).
  bool isObject(String db, AdminObjectKind kind, String name) =>
      this.kind == kind &&
      database.toLowerCase() == db.toLowerCase() &&
      object?.toLowerCase() == name.toLowerCase();

  @override
  bool operator ==(Object other) =>
      other is AdminSelection &&
      other.database.toLowerCase() == database.toLowerCase() &&
      other.kind == kind &&
      other.object?.toLowerCase() == object?.toLowerCase() &&
      other.pane == pane;

  @override
  int get hashCode =>
      Object.hash(database.toLowerCase(), kind, object?.toLowerCase(), pane);

  @override
  String toString() =>
      'AdminSelection($database${object == null ? '' : '/$object'}, ${pane.name})';
}

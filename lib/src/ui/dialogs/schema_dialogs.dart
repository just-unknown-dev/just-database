/// Schema editing: the create-table designer, add column, rename, create
/// index, and the menu of a table, view or trigger.
@internal
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../../core/just_database.dart';
import '../../storage/schema.dart';
import '../admin_selection.dart';
import '../admin_style.dart';
import '../admin_utils.dart';
import '../just_database_admin_controller.dart';
import '../panes/sql_console.dart';
import '../sql_text.dart';
import '../widgets/admin_widgets.dart';
import 'backup_dialogs.dart';
import 'row_editor.dart';

/// Runs one statement that changes [db] and reports a failure (and
/// [success], when given). Returns whether it worked.
@internal
Future<bool> runSchemaSql(
  BuildContext context,
  JustDatabase db,
  String sql, {
  String? success,
}) async {
  final r = await db.execute(sql);
  if (!context.mounted) return r.success;
  if (r.success) {
    if (success != null) showAdminMessage(context, success);
  } else {
    showAdminError(context, r.errorMessage ?? 'The statement failed.');
  }
  return r.success;
}

/// Why [name] cannot name a new table, view or index of [db], or null.
@internal
String? newObjectNameProblem(JustDatabase db, String name) {
  if (name.trim().isEmpty) return 'Enter a name.';
  if (name != name.trim()) return 'No spaces at the start or end.';
  final lower = name.toLowerCase();
  if (lower.startsWith('sqlite_')) {
    return 'Names starting with sqlite_ are reserved.';
  }
  if (db.getTableSchema(name) != null) return 'A table has that name.';
  if (db.getViewSql(name) != null) return 'A view has that name.';
  for (final t in db.tableNames) {
    if (db.indexNamesForTable(t).any((i) => i.toLowerCase() == lower)) {
      return 'An index has that name.';
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Object menu
// ---------------------------------------------------------------------------

/// What can be done to a table, view or trigger from its menu.
@internal
enum ObjectAction {
  browse,
  structure,
  query,
  newRow,
  addColumn,
  createIndex,
  rename,
  exportRows,
  copySql,
  editSql,
  empty,
  drop,
}

/// The menu entries for the object [name] of [kind] in [db].
@internal
List<PopupMenuEntry<ObjectAction>> objectMenuItems(
  BuildContext context,
  JustDatabaseAdminController controller,
  AdminObjectKind kind,
  String name,
) {
  final writable = !controller.readOnly;
  final item = menuItem<ObjectAction>;
  final isTable = kind == AdminObjectKind.table;
  return [
    if (kind != AdminObjectKind.trigger)
      item(
        context,
        ObjectAction.browse,
        Icons.table_view_outlined,
        'Browse data',
      ),
    item(
      context,
      ObjectAction.structure,
      Icons.schema_outlined,
      isTable ? 'Structure' : 'Definition',
    ),
    if (kind != AdminObjectKind.trigger)
      item(context, ObjectAction.query, Icons.code, 'Query in SQL console'),
    if (isTable && writable) ...[
      item(context, ObjectAction.newRow, Icons.add_box_outlined, 'New row…'),
      item(
        context,
        ObjectAction.addColumn,
        Icons.view_column_outlined,
        'Add column…',
      ),
      item(
        context,
        ObjectAction.createIndex,
        Icons.manage_search,
        'Create index…',
      ),
      item(
        context,
        ObjectAction.rename,
        Icons.drive_file_rename_outline,
        'Rename…',
      ),
    ],
    if (kind != AdminObjectKind.trigger)
      item(
        context,
        ObjectAction.exportRows,
        Icons.upload_outlined,
        'Export rows…',
      ),
    item(context, ObjectAction.copySql, Icons.copy, 'Copy CREATE statement'),
    if (!isTable && writable)
      item(
        context,
        ObjectAction.editSql,
        Icons.edit_note,
        'Edit in SQL console',
      ),
    if (writable) ...[
      const PopupMenuDivider(),
      if (isTable)
        item(
          context,
          ObjectAction.empty,
          Icons.cleaning_services_outlined,
          'Delete all rows…',
          destructive: true,
        ),
      item(
        context,
        ObjectAction.drop,
        Icons.delete_outline,
        'Drop ${kind.label.toLowerCase()}…',
        destructive: true,
      ),
    ],
  ];
}

/// The `CREATE` statement of an object.
@internal
String? createSqlOf(JustDatabase db, AdminObjectKind kind, String name) =>
    switch (kind) {
      AdminObjectKind.table => db.getTableSchema(name)?.sql,
      AdminObjectKind.view => db.getViewSql(name),
      AdminObjectKind.trigger => db.getTriggerSql(name),
    };

/// Runs [action] on the object [name] of [kind] in [db].
@internal
Future<void> runObjectAction(
  BuildContext context,
  JustDatabaseAdminController controller,
  JustDatabase db,
  AdminObjectKind kind,
  String name,
  ObjectAction action,
) async {
  AdminSelection at(AdminPane pane) =>
      AdminSelection(db.name, kind: kind, object: name, pane: pane);
  final quoted = sqlName(name);
  switch (action) {
    case ObjectAction.browse:
      await controller.select(at(AdminPane.data));
    case ObjectAction.structure:
      await controller.select(at(AdminPane.structure));
    case ObjectAction.query:
      await showInConsole(
        controller,
        AdminSelection(db.name, kind: kind, object: name),
        'SELECT * FROM $quoted LIMIT 100;',
      );
    case ObjectAction.newRow:
      await showRowEditorDialog(context, db, name);
    case ObjectAction.addColumn:
      await showAddColumnDialog(context, db, name);
    case ObjectAction.createIndex:
      await showCreateIndexDialog(context, db, name);
    case ObjectAction.rename:
      final newName = await promptText(
        context,
        title: 'Rename table "$name"',
        label: 'New name',
        initial: name,
        confirmLabel: 'Rename',
        validate: (t) =>
            t == name ? 'Enter a different name.' : newObjectNameProblem(db, t),
      );
      if (newName == null || !context.mounted) return;
      if (await runSchemaSql(
            context,
            db,
            'ALTER TABLE $quoted RENAME TO ${sqlName(newName)}',
            success: 'Renamed "$name" to "$newName".',
          ) &&
          context.mounted) {
        await controller.select(
          AdminSelection(
            db.name,
            kind: kind,
            object: newName,
            pane: controller.selection?.pane,
          ),
        );
      }
    case ObjectAction.exportRows:
      await showTextExportDialog(
        context,
        title: 'Export the rows of "$name"',
        baseName: '${db.name}-$name',
        options: [
          for (final (label, ext, json) in [
            ('CSV', 'csv', false),
            ('JSON', 'json', true),
          ])
            TextExportOption('$label: every row', ext, () async {
              final r = await db.query('SELECT * FROM $quoted');
              if (!r.success) throw StateError(r.errorMessage ?? 'failed');
              return json
                  ? rowsToJson(r.columns, r.values)
                  : rowsToCsv(r.columns, r.values);
            }),
        ],
      );
    case ObjectAction.copySql:
      final sql = createSqlOf(db, kind, name);
      if (sql != null) await copyText(context, sql, what: 'SQL');
    case ObjectAction.editSql:
      final sql = createSqlOf(db, kind, name);
      if (sql == null) return;
      final drop = kind == AdminObjectKind.view ? 'VIEW' : 'TRIGGER';
      await showInConsole(
        controller,
        AdminSelection(db.name, kind: kind, object: name),
        'BEGIN;\nDROP $drop $quoted;\n$sql;\nCOMMIT;',
      );
    case ObjectAction.empty:
      final rows = db.rowCount(name);
      if (!await confirmAction(
            context,
            title: 'Delete every row of "$name"?',
            message:
                '${plural(rows, 'row')} are deleted for good (foreign keys '
                'and triggers apply). The table itself stays.',
          ) ||
          !context.mounted) {
        return;
      }
      await runSchemaSql(
        context,
        db,
        'DELETE FROM $quoted',
        success: 'Deleted every row of "$name".',
      );
    case ObjectAction.drop:
      final what = kind.label.toLowerCase();
      if (!await confirmAction(
            context,
            title: 'Drop $what "$name"?',
            message: kind == AdminObjectKind.table
                ? 'The table, its ${plural(db.rowCount(name), 'row')}, its '
                      'indexes and triggers are removed for good.'
                : 'The $what is removed for good.',
            confirmLabel: 'Drop',
          ) ||
          !context.mounted) {
        return;
      }
      await runSchemaSql(
        context,
        db,
        'DROP ${kind.name.toUpperCase()} $quoted',
        success: 'Dropped $what "$name".',
      );
  }
}

// ---------------------------------------------------------------------------
// Column drafts (designer and add column)
// ---------------------------------------------------------------------------

const _fkActions = [
  'NO ACTION',
  'CASCADE',
  'SET NULL',
  'RESTRICT',
  'SET DEFAULT',
];

class _ColumnDraft {
  _ColumnDraft({String name = '', this.type = 'TEXT'})
    : name = TextEditingController(text: name);

  final TextEditingController name;
  final TextEditingController defaultValue = TextEditingController();
  String type;
  bool primaryKey = false;
  bool autoIncrement = false;
  bool notNull = false;
  bool unique = false;
  String? refTable;
  String? refColumn;
  String onDelete = 'NO ACTION';

  void dispose() {
    name.dispose();
    defaultValue.dispose();
  }

  /// The column definition, as SQL. [inlinePrimaryKey] puts PRIMARY KEY on
  /// the column (one key column).
  String sql({required bool inlinePrimaryKey}) {
    final b = StringBuffer(sqlName(name.text.trim()));
    if (type.trim().isNotEmpty) b.write(' ${type.trim()}');
    if (primaryKey && inlinePrimaryKey) {
      b.write(' PRIMARY KEY');
      if (autoIncrement) b.write(' AUTOINCREMENT');
    }
    if (notNull) b.write(' NOT NULL');
    if (unique && !(primaryKey && inlinePrimaryKey)) b.write(' UNIQUE');
    final d = defaultValue.text.trim();
    if (d.isNotEmpty) b.write(' DEFAULT ${defaultSql(d)}');
    final ref = refTable;
    if (ref != null) {
      b.write(' REFERENCES ${sqlName(ref)}');
      if (refColumn != null) b.write(' (${sqlName(refColumn!)})');
      if (onDelete != 'NO ACTION') b.write(' ON DELETE $onDelete');
    }
    return b.toString();
  }
}

/// A DEFAULT value as SQL: literals and CURRENT_* as written, anything
/// else in parentheses.
@internal
String defaultSql(String text) {
  final t = text.trim();
  final literal =
      RegExp(r'^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$').hasMatch(t) ||
      RegExp(r"^'([^']|'')*'$").hasMatch(t) ||
      RegExp(r"^[xX]'[0-9A-Fa-f]*'$").hasMatch(t) ||
      const {
        'NULL',
        'TRUE',
        'FALSE',
        'CURRENT_TIME',
        'CURRENT_DATE',
        'CURRENT_TIMESTAMP',
      }.contains(t.toUpperCase()) ||
      (t.startsWith('(') && t.endsWith(')'));
  return literal ? t : '($t)';
}

/// The fields of one column draft.
class _ColumnDraftEditor extends StatelessWidget {
  const _ColumnDraftEditor({
    super.key,
    required this.draft,
    required this.db,
    required this.onChanged,
    required this.index,
    this.onRemove,
    this.forAddColumn = false,
    this.nameError,
  });

  final _ColumnDraft draft;
  final JustDatabase db;
  final VoidCallback onChanged;
  final int index;
  final VoidCallback? onRemove;
  final bool forAddColumn;
  final String? nameError;

  @override
  Widget build(BuildContext context) {
    final types = {...commonColumnTypes, draft.type};
    final refColumns = draft.refTable == null
        ? const <String>[]
        : db.getTableSchema(draft.refTable!)?.columnNames ?? const <String>[];
    final isInteger = draft.type.toUpperCase() == 'INTEGER';
    Widget chip(String label, bool value, ValueChanged<bool>? set) =>
        FilterChip(
          label: Text(label),
          selected: value,
          onSelected: set == null
              ? null
              : (v) {
                  set(v);
                  onChanged();
                },
          visualDensity: VisualDensity.compact,
        );
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    key: ValueKey('jdb-col-name-$index'),
                    controller: draft.name,
                    onChanged: (_) => onChanged(),
                    decoration: InputDecoration(
                      labelText: 'Column name',
                      isDense: true,
                      border: const OutlineInputBorder(),
                      errorText: nameError,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('jdb-col-type-$index'),
                    initialValue: draft.type,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Type',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    items: [
                      for (final t in types)
                        DropdownMenuItem(
                          value: t,
                          child: Text(t.isEmpty ? '(none)' : t),
                        ),
                    ],
                    onChanged: (v) {
                      draft.type = v ?? draft.type;
                      if (draft.type.toUpperCase() != 'INTEGER') {
                        draft.autoIncrement = false;
                      }
                      onChanged();
                    },
                  ),
                ),
                if (onRemove != null)
                  IconButton(
                    tooltip: 'Remove column',
                    icon: const Icon(Icons.close),
                    onPressed: onRemove,
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                if (!forAddColumn) ...[
                  chip('Primary key', draft.primaryKey, (v) {
                    draft.primaryKey = v;
                    if (!v) draft.autoIncrement = false;
                  }),
                  if (draft.primaryKey && isInteger)
                    chip(
                      'Autoincrement',
                      draft.autoIncrement,
                      (v) => draft.autoIncrement = v,
                    ),
                ],
                chip('Not null', draft.notNull, (v) => draft.notNull = v),
                if (!forAddColumn)
                  chip('Unique', draft.unique, (v) => draft.unique = v),
              ],
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: TextField(
                key: ValueKey('jdb-col-default-$index'),
                controller: draft.defaultValue,
                onChanged: (_) => onChanged(),
                style: AdminStyle.mono(context, fontSize: 13),
                decoration: const InputDecoration(
                  labelText: 'Default',
                  hintText: "0, 'none', CURRENT_TIMESTAMP…",
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 180,
                    child: DropdownButtonFormField<String?>(
                      key: ValueKey('jdb-col-ref-$index'),
                      initialValue: draft.refTable,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'References',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('Nothing'),
                        ),
                        for (final t in db.tableNames)
                          DropdownMenuItem(value: t, child: Text(t)),
                      ],
                      onChanged: (v) {
                        draft.refTable = v;
                        final cols = v == null
                            ? const <String>[]
                            : db.getTableSchema(v)?.primaryKey ?? const [];
                        draft.refColumn = cols.length == 1 ? cols.first : null;
                        onChanged();
                      },
                    ),
                  ),
                  if (draft.refTable != null) ...[
                    SizedBox(
                      width: 150,
                      child: DropdownButtonFormField<String?>(
                        key: ValueKey(
                          'jdb-col-refcol-$index-${draft.refTable}',
                        ),
                        initialValue: refColumns.contains(draft.refColumn)
                            ? draft.refColumn
                            : null,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Column',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Its key'),
                          ),
                          for (final c in refColumns)
                            DropdownMenuItem(value: c, child: Text(c)),
                        ],
                        onChanged: (v) {
                          draft.refColumn = v;
                          onChanged();
                        },
                      ),
                    ),
                    SizedBox(
                      width: 160,
                      child: DropdownButtonFormField<String>(
                        initialValue: draft.onDelete,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'On delete',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          for (final a in _fkActions)
                            DropdownMenuItem(value: a, child: Text(a)),
                        ],
                        onChanged: (v) {
                          draft.onDelete = v ?? draft.onDelete;
                          onChanged();
                        },
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Create table
// ---------------------------------------------------------------------------

/// The create-table designer. Returns the new table's name. With
/// [controller], "Edit as SQL" moves the statement to the SQL console.
@internal
Future<String?> showCreateTableDialog(
  BuildContext context,
  JustDatabase db, {
  JustDatabaseAdminController? controller,
}) => showDialog<String>(
  context: context,
  builder: (_) => _CreateTableDialog(db: db, controller: controller),
);

class _CreateTableDialog extends StatefulWidget {
  const _CreateTableDialog({required this.db, required this.controller});

  final JustDatabase db;
  final JustDatabaseAdminController? controller;

  @override
  State<_CreateTableDialog> createState() => _CreateTableDialogState();
}

class _CreateTableDialogState extends State<_CreateTableDialog> {
  final _name = TextEditingController();
  final List<_ColumnDraft> _columns = [
    _ColumnDraft(name: 'id', type: 'INTEGER')..primaryKey = true,
    _ColumnDraft(),
  ];
  bool _showErrors = false;
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    for (final c in _columns) {
      c.dispose();
    }
    super.dispose();
  }

  List<_ColumnDraft> get _used => [
    for (final c in _columns)
      if (c.name.text.trim().isNotEmpty) c,
  ];

  String get _sql {
    final cols = _used;
    final keys = [
      for (final c in cols)
        if (c.primaryKey) c,
    ];
    final inline = keys.length == 1;
    final parts = [
      for (final c in cols) c.sql(inlinePrimaryKey: inline),
      if (keys.length > 1)
        'PRIMARY KEY (${keys.map((c) => sqlName(c.name.text.trim())).join(', ')})',
    ];
    final name = _name.text.trim().isEmpty ? 'new_table' : _name.text.trim();
    return 'CREATE TABLE ${sqlName(name)} (\n  ${parts.join(',\n  ')}\n)';
  }

  String? _columnError(int i) {
    final name = _columns[i].name.text.trim();
    if (name.isEmpty) return i < 1 && _used.isEmpty ? 'Enter a name.' : null;
    final lower = name.toLowerCase();
    for (var j = 0; j < i; j++) {
      if (_columns[j].name.text.trim().toLowerCase() == lower) {
        return 'Used twice.';
      }
    }
    return null;
  }

  String? get _problem {
    final nameProblem = newObjectNameProblem(widget.db, _name.text);
    if (nameProblem != null) return 'Table name: $nameProblem';
    if (_used.isEmpty) return 'Add a column.';
    for (var i = 0; i < _columns.length; i++) {
      final e = _columnError(i);
      if (e != null) return 'Column ${i + 1}: $e';
    }
    final keys = [
      for (final c in _used)
        if (c.primaryKey) c,
    ];
    if (keys.length > 1 && keys.any((c) => c.autoIncrement)) {
      return 'AUTOINCREMENT needs a single INTEGER PRIMARY KEY.';
    }
    return null;
  }

  Future<void> _create() async {
    final problem = _problem;
    if (problem != null) {
      setState(() {
        _showErrors = true;
        _error = problem;
      });
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    final r = await widget.db.execute(_sql);
    if (!mounted) return;
    if (r.success) {
      final name = _name.text.trim();
      Navigator.pop(context, name);
      showAdminMessage(context, 'Created table "$name".');
    } else {
      setState(() {
        _working = false;
        _error = r.errorMessage;
      });
    }
  }

  void _editAsSql() {
    final controller = widget.controller;
    if (controller == null) return;
    final sql = '$_sql;';
    Navigator.pop(context);
    showInConsole(controller, AdminSelection(widget.db.name), sql);
  }

  @override
  Widget build(BuildContext context) {
    return AdminDialog(
      title: 'New table in "${widget.db.name}"',
      width: 680,
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (widget.controller != null)
          OutlinedButton(
            onPressed: _working ? null : _editAsSql,
            child: const Text('Edit as SQL'),
          ),
        FilledButton(
          key: const ValueKey('jdb-create-table'),
          onPressed: _working ? null : _create,
          child: Text(_working ? 'Creating…' : 'Create table'),
        ),
      ],
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: AdminStyle.isWide(context)
              ? MediaQuery.sizeOf(context).height * 0.7
              : double.infinity,
        ),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(top: 8),
          children: [
            if (_error != null)
              MessageBanner(
                message: _error!,
                tone: BannerTone.error,
                margin: const EdgeInsets.only(bottom: 12),
              ),
            TextField(
              key: const ValueKey('jdb-table-name'),
              controller: _name,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: 'Table name',
                border: const OutlineInputBorder(),
                errorText: _showErrors
                    ? newObjectNameProblem(widget.db, _name.text)
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text('Columns', style: AdminStyle.heading(context)),
                ),
                TextButton.icon(
                  key: const ValueKey('jdb-add-column-draft'),
                  onPressed: () => setState(() => _columns.add(_ColumnDraft())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add column'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < _columns.length; i++)
              _ColumnDraftEditor(
                key: ObjectKey(_columns[i]),
                draft: _columns[i],
                db: widget.db,
                index: i,
                nameError: _showErrors ? _columnError(i) : null,
                onChanged: () => setState(() {}),
                onRemove: _columns.length == 1
                    ? null
                    : () => setState(() => _columns.removeAt(i).dispose()),
              ),
            const SizedBox(height: 8),
            Text('SQL', style: AdminStyle.heading(context)),
            const SizedBox(height: 6),
            SqlBlock(sql: _sql),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add column
// ---------------------------------------------------------------------------

/// Adds a column to [table]. Returns whether it was added.
@internal
Future<bool> showAddColumnDialog(
  BuildContext context,
  JustDatabase db,
  String table,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _AddColumnDialog(db: db, table: table),
    ) ==
    true;

class _AddColumnDialog extends StatefulWidget {
  const _AddColumnDialog({required this.db, required this.table});

  final JustDatabase db;
  final String table;

  @override
  State<_AddColumnDialog> createState() => _AddColumnDialogState();
}

class _AddColumnDialogState extends State<_AddColumnDialog> {
  final _draft = _ColumnDraft();
  bool _working = false;
  bool _showErrors = false;
  String? _error;

  @override
  void dispose() {
    _draft.dispose();
    super.dispose();
  }

  String get _sql =>
      'ALTER TABLE ${sqlName(widget.table)} ADD COLUMN '
      '${_draft.sql(inlinePrimaryKey: false)}';

  String? get _nameError {
    final name = _draft.name.text.trim();
    if (name.isEmpty) return 'Enter a name.';
    final schema = widget.db.getTableSchema(widget.table);
    if (schema != null && schema.indexOf(name) != null) {
      return 'The table has a column of that name.';
    }
    return null;
  }

  Future<void> _add() async {
    if (_nameError != null) {
      setState(() => _showErrors = true);
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    final r = await widget.db.execute(_sql);
    if (!mounted) return;
    if (r.success) {
      Navigator.pop(context, true);
      showAdminMessage(context, 'Added column "${_draft.name.text.trim()}".');
    } else {
      setState(() {
        _working = false;
        _error = r.errorMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.db.rowCount(widget.table);
    return AdminDialog(
      title: 'Add a column to "${widget.table}"',
      width: 560,
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('jdb-add-column'),
          onPressed: _working ? null : _add,
          child: const Text('Add column'),
        ),
      ],
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              MessageBanner(
                message: _error!,
                tone: BannerTone.error,
                margin: const EdgeInsets.only(bottom: 12),
              ),
            _ColumnDraftEditor(
              draft: _draft,
              db: widget.db,
              index: 0,
              forAddColumn: true,
              nameError: _showErrors ? _nameError : null,
              onChanged: () => setState(() {}),
            ),
            if (rows > 0 && _draft.notNull)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'The ${plural(rows, 'existing row')} get the default, so NOT NULL '
                  'needs one.',
                  style: AdminStyle.caption(context),
                ),
              ),
            SqlBlock(sql: _sql),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Create index
// ---------------------------------------------------------------------------

/// Creates an index on [table]. Returns whether one was created.
@internal
Future<bool> showCreateIndexDialog(
  BuildContext context,
  JustDatabase db,
  String table,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => _CreateIndexDialog(db: db, table: table),
    ) ==
    true;

class _CreateIndexDialog extends StatefulWidget {
  const _CreateIndexDialog({required this.db, required this.table});

  final JustDatabase db;
  final String table;

  @override
  State<_CreateIndexDialog> createState() => _CreateIndexDialogState();
}

class _CreateIndexDialogState extends State<_CreateIndexDialog> {
  final _name = TextEditingController();
  final List<String> _picked = [];
  bool _unique = false;
  bool _spatial = false;
  bool _nameEdited = false;
  bool _working = false;
  bool _showErrors = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _suggest();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _suggest() {
    if (_nameEdited) return;
    final cols = _picked.isEmpty ? '' : '_${_picked.join('_')}';
    _name.text = '${_spatial ? 'spatial' : 'idx'}_${widget.table}$cols'
        .replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  }

  String get _sql {
    final kind = _spatial ? 'SPATIAL ' : (_unique ? 'UNIQUE ' : '');
    final name = _name.text.trim().isEmpty ? 'idx' : _name.text.trim();
    final cols = _picked.isEmpty ? '…' : _picked.map(sqlName).join(', ');
    return 'CREATE ${kind}INDEX ${sqlName(name)} ON ${sqlName(widget.table)} ($cols)';
  }

  String? get _problem {
    final nameProblem = newObjectNameProblem(widget.db, _name.text);
    if (nameProblem != null) return nameProblem;
    if (_picked.isEmpty) return 'Pick at least one column.';
    if (_spatial && _picked.length != 2) {
      return 'A spatial index takes exactly two columns: x, then y.';
    }
    return null;
  }

  Future<void> _create() async {
    final problem = _problem;
    if (problem != null) {
      setState(() {
        _showErrors = true;
        _error = problem;
      });
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    final r = await widget.db.execute(_sql);
    if (!mounted) return;
    if (r.success) {
      Navigator.pop(context, true);
      showAdminMessage(context, 'Created index "${_name.text.trim()}".');
    } else {
      setState(() {
        _working = false;
        _error = r.errorMessage;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final columns =
        widget.db.getTableSchema(widget.table)?.columnNames ?? const <String>[];
    return AdminDialog(
      title: 'New index on "${widget.table}"',
      width: 520,
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('jdb-create-index'),
          onPressed: _working ? null : _create,
          child: const Text('Create index'),
        ),
      ],
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              MessageBanner(
                message: _error!,
                tone: BannerTone.error,
                margin: const EdgeInsets.only(bottom: 12),
              ),
            Text(
              'Columns, in key order (tap to add or remove)',
              style: AdminStyle.heading(context),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final c in columns)
                  FilterChip(
                    key: ValueKey('jdb-index-col-$c'),
                    label: Text(
                      _picked.contains(c) ? '${_picked.indexOf(c) + 1}. $c' : c,
                    ),
                    selected: _picked.contains(c),
                    onSelected: (v) => setState(() {
                      v ? _picked.add(c) : _picked.remove(c);
                      _suggest();
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Unique'),
              subtitle: const Text('No two rows may have the same key.'),
              value: _unique,
              onChanged: _spatial ? null : (v) => setState(() => _unique = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Spatial'),
              subtitle: const Text(
                'An R-tree over two columns (x, y) for the ST_* functions.',
              ),
              value: _spatial,
              onChanged: (v) => setState(() {
                _spatial = v;
                if (v) _unique = false;
                _suggest();
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const ValueKey('jdb-index-name'),
              controller: _name,
              onChanged: (_) => setState(() => _nameEdited = true),
              decoration: InputDecoration(
                labelText: 'Index name',
                border: const OutlineInputBorder(),
                errorText: _showErrors
                    ? newObjectNameProblem(widget.db, _name.text)
                    : null,
              ),
            ),
            const SizedBox(height: 12),
            SqlBlock(sql: _sql),
          ],
        ),
      ),
    );
  }
}

/// Renames the column [column] of [table].
@internal
Future<void> renameColumn(
  BuildContext context,
  JustDatabase db,
  String table,
  String column,
) async {
  final schema = db.getTableSchema(table);
  final newName = await promptText(
    context,
    title: 'Rename column "$column"',
    label: 'New name',
    initial: column,
    confirmLabel: 'Rename',
    validate: (t) {
      if (t.trim().isEmpty) return 'Enter a name.';
      if (t == column) return 'Enter a different name.';
      if (schema != null &&
          schema.indexOf(t) != null &&
          t.toLowerCase() != column.toLowerCase()) {
        return 'The table has a column of that name.';
      }
      return null;
    },
  );
  if (newName == null || !context.mounted) return;
  await runSchemaSql(
    context,
    db,
    'ALTER TABLE ${sqlName(table)} RENAME COLUMN ${sqlName(column)} TO ${sqlName(newName)}',
    success: 'Renamed "$column" to "$newName".',
  );
}

/// Drops the column [column] of [table], after asking.
@internal
Future<void> dropColumn(
  BuildContext context,
  JustDatabase db,
  String table,
  String column,
) async {
  if (!await confirmAction(
        context,
        title: 'Drop column "$column"?',
        message:
            'Its values in ${plural(db.rowCount(table), 'row')} of "$table" '
            'are removed for good.',
        confirmLabel: 'Drop',
      ) ||
      !context.mounted) {
    return;
  }
  await runSchemaSql(
    context,
    db,
    'ALTER TABLE ${sqlName(table)} DROP COLUMN ${sqlName(column)}',
    success: 'Dropped column "$column".',
  );
}

/// Drops the index [index], after asking.
@internal
Future<void> dropIndex(
  BuildContext context,
  JustDatabase db,
  IndexInfo index,
) async {
  if (!await confirmAction(
        context,
        title: 'Drop index "${index.name}"?',
        message: 'Queries on ${index.columns.join(', ')} may get slower.',
        confirmLabel: 'Drop',
      ) ||
      !context.mounted) {
    return;
  }
  await runSchemaSql(
    context,
    db,
    'DROP INDEX ${sqlName(index.name)}',
    success: 'Dropped index "${index.name}".',
  );
}

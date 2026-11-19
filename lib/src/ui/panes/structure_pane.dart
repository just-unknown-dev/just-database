/// The structure of a table (columns, keys, indexes, triggers, references)
/// or the definition of a view or trigger, with the actions that change
/// them.
@internal
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../../core/just_database.dart';
import '../../storage/schema.dart';
import '../admin_selection.dart';
import '../admin_style.dart';
import '../admin_utils.dart';
import '../dialogs/schema_dialogs.dart';
import '../just_database_admin_controller.dart';
import '../sql_text.dart';
import '../widgets/admin_widgets.dart';

/// The structure or definition of one object.
@internal
class StructurePane extends StatelessWidget {
  const StructurePane({
    super.key,
    required this.controller,
    required this.database,
    required this.kind,
    required this.object,
  });

  final JustDatabaseAdminController controller;
  final JustDatabase database;
  final AdminObjectKind kind;
  final String object;

  bool get _writable => !controller.readOnly;

  @override
  Widget build(BuildContext context) {
    if (!database.isOpen) {
      return const EmptyState(
        icon: Icons.storage,
        title: 'The database is closed',
      );
    }
    final Widget body = switch (kind) {
      AdminObjectKind.table => _table(context),
      AdminObjectKind.view => _view(context),
      AdminObjectKind.trigger => _trigger(context),
    };
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: body,
      ),
    );
  }

  Set<String> get _names => {
    for (final t in database.tableNames) t.toLowerCase(),
    for (final v in database.viewNames) v.toLowerCase(),
  };

  Future<void> _act(BuildContext context, ObjectAction action) =>
      runObjectAction(context, controller, database, kind, object, action);

  Widget _actions(
    BuildContext context,
    List<(ObjectAction, IconData, String)> items,
  ) {
    // On a phone the page's app bar menu has these actions.
    if (!AdminStyle.isWide(context)) return const SizedBox.shrink();
    final error = Theme.of(context).colorScheme.error;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (action, icon, label) in items)
          OutlinedButton.icon(
            key: ValueKey('jdb-action-${action.name}'),
            style: action == ObjectAction.drop || action == ObjectAction.empty
                ? OutlinedButton.styleFrom(foregroundColor: error)
                : null,
            onPressed: () => _act(context, action),
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
      ],
    );
  }

  Widget _header(
    BuildContext context,
    IconData icon,
    String subtitle,
    Widget actions,
  ) {
    final cs = Theme.of(context).colorScheme;
    final wide = AdminStyle.isWide(context);
    final title = Row(
      children: [
        Icon(icon, color: cs.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                object,
                style: Theme.of(context).textTheme.titleLarge,
                overflow: TextOverflow.ellipsis,
              ),
              Text(subtitle, style: AdminStyle.caption(context)),
            ],
          ),
        ),
        if (!wide) actions,
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          title,
          if (wide) ...[const SizedBox(height: 12), actions],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Table
  // ---------------------------------------------------------------------------

  Widget _table(BuildContext context) {
    final schema = database.getTableSchema(object);
    if (schema == null) {
      return EmptyState(
        icon: Icons.table_chart_outlined,
        title: '"$object" no longer exists',
      );
    }
    final columns = [
      for (final c in schema.columns)
        if (!c.hidden) c,
    ];
    final alias = schema.rowidAlias;
    final pk = schema.primaryKey;
    final indexes = database.indexesForTable(object);
    final triggers = database.triggerNamesForTable(object);
    final referencedBy = <(String, ForeignKeyDefinition)>[
      for (final t in database.tableNames)
        for (final fk
            in database.getTableSchema(t)?.foreignKeys ??
                const <ForeignKeyDefinition>[])
          if (fk.parentTable.toLowerCase() == object.toLowerCase()) (t, fk),
    ];
    final uniques = [
      for (final c in schema.constraints)
        if (c.kind == TableConstraintKind.unique) c.columns,
    ];
    final rows = database.rowCount(object);
    final gap = const SizedBox(height: 12);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _header(
          context,
          Icons.table_chart_outlined,
          '${plural(columns.length, 'column')} · ${plural(rows, 'row')}'
          '${alias == null ? ' · rows addressed by their hidden rowid' : ''}',
          _actions(context, [
            if (_writable) ...[
              (
                ObjectAction.addColumn,
                Icons.view_column_outlined,
                'Add column',
              ),
              (ObjectAction.createIndex, Icons.manage_search, 'Create index'),
              (ObjectAction.rename, Icons.drive_file_rename_outline, 'Rename'),
            ],
            (ObjectAction.query, Icons.code, 'Query'),
            (ObjectAction.exportRows, Icons.upload_outlined, 'Export rows'),
            if (_writable) ...[
              (
                ObjectAction.empty,
                Icons.cleaning_services_outlined,
                'Delete all rows',
              ),
              (ObjectAction.drop, Icons.delete_outline, 'Drop table'),
            ],
          ]),
        ),
        SectionCard(
          title: 'Columns',
          children: [
            for (var i = 0; i < columns.length; i++)
              _ColumnRow(
                key: ValueKey('jdb-column-${columns[i].name}'),
                column: columns[i],
                inPrimaryKey:
                    columns[i].primaryKey ||
                    pk.any(
                      (k) => k.toLowerCase() == columns[i].name.toLowerCase(),
                    ),
                isRowidAlias:
                    alias != null &&
                    identical(schema.columns[alias], columns[i]),
                foreignKey: schema.foreignKeys
                    .where(
                      (fk) =>
                          fk.columns.length == 1 &&
                          fk.columns.first.toLowerCase() ==
                              columns[i].name.toLowerCase(),
                    )
                    .firstOrNull,
                writable: _writable,
                onRename: () =>
                    renameColumn(context, database, object, columns[i].name),
                onDrop: () =>
                    dropColumn(context, database, object, columns[i].name),
              ),
          ],
        ),
        if (pk.length > 1 ||
            uniques.isNotEmpty ||
            schema.checks.isNotEmpty ||
            schema.foreignKeys.any((fk) => fk.columns.length > 1)) ...[
          gap,
          SectionCard(
            title: 'Keys and checks',
            children: [
              if (pk.length > 1)
                _DetailRow(label: 'PRIMARY KEY', value: '(${pk.join(', ')})'),
              for (final u in uniques)
                _DetailRow(label: 'UNIQUE', value: '(${u.join(', ')})'),
              for (final fk in schema.foreignKeys)
                if (fk.columns.length > 1)
                  _DetailRow(
                    label: 'FOREIGN KEY',
                    value: '(${fk.columns.join(', ')}) ${fk.referencesSql}',
                  ),
              for (final check in schema.checks)
                _DetailRow(label: 'CHECK', value: check),
            ],
          ),
        ],
        gap,
        SectionCard(
          title: 'Indexes',
          children: [
            if (indexes.isEmpty)
              const _Note(
                'None. Equality lookups on unindexed columns scan the table.',
              ),
            for (final index in indexes)
              ListTile(
                key: ValueKey('jdb-index-${index.name}'),
                dense: true,
                leading: Icon(
                  index.origin == IndexOrigin.spatial
                      ? Icons.place_outlined
                      : Icons.manage_search,
                  size: 20,
                ),
                title: Text(index.name),
                subtitle: Text(
                  [
                    index.columns.join(', '),
                    if (index.unique) 'unique',
                    switch (index.origin) {
                      IndexOrigin.primaryKey => 'for the primary key',
                      IndexOrigin.unique => 'for a UNIQUE constraint',
                      IndexOrigin.manual => 'created by CREATE INDEX',
                      IndexOrigin.spatial => 'spatial (R-tree)',
                      IndexOrigin.foreignKey => 'for a foreign key',
                    },
                  ].join(' · '),
                ),
                trailing:
                    _writable &&
                        (index.origin == IndexOrigin.manual ||
                            index.origin == IndexOrigin.spatial)
                    ? IconButton(
                        tooltip: 'Drop index',
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () => dropIndex(context, database, index),
                      )
                    : null,
              ),
          ],
        ),
        if (triggers.isNotEmpty) ...[
          gap,
          _TriggersCard(
            controller: controller,
            database: database,
            triggers: triggers,
          ),
        ],
        if (referencedBy.isNotEmpty) ...[
          gap,
          SectionCard(
            title: 'Referenced by',
            children: [
              for (final (table, fk) in referencedBy)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.call_received, size: 20),
                  title: Text('$table (${fk.columns.join(', ')})'),
                  subtitle: Text(
                    'ON DELETE ${fk.onDelete.sql} · ON UPDATE ${fk.onUpdate.sql}',
                  ),
                  onTap: () => controller.select(
                    AdminSelection(
                      database.name,
                      kind: AdminObjectKind.table,
                      object: table,
                      pane: AdminPane.structure,
                    ),
                  ),
                ),
            ],
          ),
        ],
        gap,
        Text('CREATE statement', style: AdminStyle.heading(context)),
        const SizedBox(height: 6),
        SqlBlock(sql: schema.sql, tables: _names),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // View
  // ---------------------------------------------------------------------------

  Widget _view(BuildContext context) {
    final sql = database.getViewSql(object);
    if (sql == null) {
      return EmptyState(
        icon: Icons.view_agenda_outlined,
        title: '"$object" no longer exists',
      );
    }
    final triggers = database.triggerNamesForTable(object);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _header(
          context,
          Icons.view_agenda_outlined,
          'View',
          _actions(context, [
            (ObjectAction.browse, Icons.table_view_outlined, 'Browse'),
            (ObjectAction.query, Icons.code, 'Query'),
            if (_writable) ...[
              (ObjectAction.editSql, Icons.edit_note, 'Edit in SQL console'),
              (ObjectAction.drop, Icons.delete_outline, 'Drop view'),
            ],
          ]),
        ),
        FutureBuilder(
          future: database.query('SELECT * FROM ${sqlName(object)} LIMIT 0'),
          builder: (context, snap) {
            final r = snap.data;
            return SectionCard(
              title: 'Columns',
              children: [
                if (r == null)
                  const LinearProgressIndicator()
                else if (!r.success)
                  _Note('The view cannot be read: ${r.errorMessage}')
                else
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final c in r.columns) AdminTag.neutral(context, c),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
        if (triggers.isNotEmpty) ...[
          const SizedBox(height: 12),
          _TriggersCard(
            controller: controller,
            database: database,
            triggers: triggers,
          ),
        ],
        const SizedBox(height: 12),
        Text('Definition', style: AdminStyle.heading(context)),
        const SizedBox(height: 6),
        SqlBlock(sql: sql, tables: _names),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Trigger
  // ---------------------------------------------------------------------------

  Widget _trigger(BuildContext context) {
    final sql = database.getTriggerSql(object);
    final on = database.getTriggerTable(object);
    if (sql == null || on == null) {
      return EmptyState(icon: Icons.bolt, title: '"$object" no longer exists');
    }
    final isView = database.getViewSql(on) != null;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _header(
          context,
          Icons.bolt,
          'Trigger on ${isView ? 'view' : 'table'} $on',
          _actions(context, [
            if (_writable) ...[
              (ObjectAction.editSql, Icons.edit_note, 'Edit in SQL console'),
              (ObjectAction.drop, Icons.delete_outline, 'Drop trigger'),
            ],
          ]),
        ),
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: Icon(
              isView ? Icons.view_agenda_outlined : Icons.table_chart_outlined,
            ),
            title: Text(on),
            subtitle: Text(isView ? 'View' : 'Table'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => controller.select(
              AdminSelection(
                database.name,
                kind: isView ? AdminObjectKind.view : AdminObjectKind.table,
                object: on,
                pane: AdminPane.structure,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('Definition', style: AdminStyle.heading(context)),
        const SizedBox(height: 6),
        SqlBlock(sql: sql, tables: _names),
      ],
    );
  }
}

class _ColumnRow extends StatelessWidget {
  const _ColumnRow({
    super.key,
    required this.column,
    required this.inPrimaryKey,
    required this.isRowidAlias,
    required this.foreignKey,
    required this.writable,
    required this.onRename,
    required this.onDrop,
  });

  final ColumnDefinition column;
  final bool inPrimaryKey;
  final bool isRowidAlias;
  final ForeignKeyDefinition? foreignKey;
  final bool writable;
  final VoidCallback onRename;
  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fk = foreignKey;
    final flags = [
      if (inPrimaryKey) isRowidAlias ? 'PRIMARY KEY (rowid)' : 'PRIMARY KEY',
      if (column.autoIncrement) 'AUTOINCREMENT',
      if (column.notNull) 'NOT NULL',
      if (column.unique) 'UNIQUE',
      if (column.defaultSql != null) 'DEFAULT ${column.defaultSql}',
      if (column.collation != null) 'COLLATE ${column.collation}',
      if (fk != null) fk.referencesSql,
    ];
    return ListTile(
      dense: true,
      leading: Icon(
        inPrimaryKey
            ? Icons.key
            : (fk != null ? Icons.link : Icons.view_column_outlined),
        size: 20,
        color: inPrimaryKey || fk != null ? cs.primary : null,
      ),
      title: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            column.name,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          Tooltip(
            message: '${column.affinity.name.toUpperCase()} affinity',
            child: AdminTag(
              label: column.type.isEmpty ? 'ANY' : column.type.toUpperCase(),
              background: cs.secondaryContainer,
              foreground: cs.onSecondaryContainer,
            ),
          ),
        ],
      ),
      subtitle: flags.isEmpty ? null : Text(flags.join(' · ')),
      trailing: writable
          ? PopupMenuButton<String>(
              key: ValueKey('jdb-column-menu-${column.name}'),
              tooltip: 'Actions for ${column.name}',
              onSelected: (v) => v == 'rename' ? onRename() : onDrop(),
              itemBuilder: (context) => [
                menuItem(
                  context,
                  'rename',
                  Icons.drive_file_rename_outline,
                  'Rename…',
                ),
                menuItem(
                  context,
                  'drop',
                  Icons.delete_outline,
                  'Drop…',
                  destructive: true,
                ),
              ],
            )
          : null,
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label  ',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text: value,
              style: AdminStyle.mono(context, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Text(text, style: AdminStyle.caption(context)),
  );
}

class _TriggersCard extends StatelessWidget {
  const _TriggersCard({
    required this.controller,
    required this.database,
    required this.triggers,
  });

  final JustDatabaseAdminController controller;
  final JustDatabase database;
  final List<String> triggers;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: 'Triggers',
      children: [
        for (final t in triggers)
          ExpansionTile(
            key: ValueKey('jdb-trigger-$t'),
            dense: true,
            leading: const Icon(Icons.bolt, size: 20),
            title: Text(t),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              SqlBlock(sql: database.getTriggerSql(t) ?? ''),
              if (!controller.readOnly)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => runObjectAction(
                      context,
                      controller,
                      database,
                      AdminObjectKind.trigger,
                      t,
                      ObjectAction.drop,
                    ),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Drop trigger'),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

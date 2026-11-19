import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_signals/just_signals.dart';

import '../../core/just_database.dart';
import '../../storage/schema.dart';
import '../admin_utils.dart';
import '../database_provider.dart';
import '../widgets/admin_widgets.dart';

/// The tables (columns, keys, checks, indexes), views and triggers of the
/// selected database.
class SchemaTab extends StatelessWidget {
  /// Creates the tab.
  const SchemaTab({super.key, required this.provider});

  /// The admin state.
  final DatabaseProvider provider;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder<int>(
      signal: provider.revision,
      builder: (context, _, _) {
        final db = provider.currentDatabase;
        if (db == null) {
          return const EmptyState(
            icon: Icons.schema,
            title: 'No database selected',
            message: 'Open a database on the Databases tab.',
          );
        }
        final tables = db.tableNames;
        final views = db.viewNames;
        final triggers = db.triggerNames;
        if (tables.isEmpty && views.isEmpty) {
          return EmptyState(
            icon: Icons.table_chart_outlined,
            title: 'No tables in "${db.name}"',
            message: 'Use the Query tab to CREATE TABLE.',
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
          children: [
            for (final t in tables)
              if (db.getTableSchema(t) case final schema?)
                _TableSchemaCard(
                  db: db,
                  schema: schema,
                  initiallyExpanded: tables.length <= 3,
                ),
            if (views.isNotEmpty)
              _NameListCard(
                title: 'Views',
                icon: Icons.view_agenda_outlined,
                names: views,
              ),
            if (triggers.isNotEmpty)
              _NameListCard(
                title: 'Triggers',
                icon: Icons.bolt,
                names: triggers,
              ),
          ],
        );
      },
    );
  }
}

class _TableSchemaCard extends StatelessWidget {
  const _TableSchemaCard({
    required this.db,
    required this.schema,
    required this.initiallyExpanded,
  });

  final JustDatabase db;
  final TableSchema schema;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final columns = [
      for (final c in schema.columns)
        if (!c.hidden) c,
    ];
    final pk = schema.primaryKey;
    final alias = schema.rowidAlias;
    final indexes = db.indexesForTable(schema.name);
    final rows = db.rowCount(schema.name);
    final small = TextStyle(fontSize: 12, color: cs.onSurfaceVariant);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(Icons.table_chart_outlined, color: cs.primary),
        title: Text(
          schema.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${plural(columns.length, 'column')} · ${plural(rows, 'row')}',
          style: small,
        ),
        initiallyExpanded: initiallyExpanded,
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 24,
              headingRowHeight: 36,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 48,
              columns: const [
                DataColumn(label: Text('Column')),
                DataColumn(label: Text('Type')),
                DataColumn(label: Text('Constraints')),
              ],
              rows: [
                for (var i = 0; i < schema.columns.length; i++)
                  if (!schema.columns[i].hidden)
                    _columnRow(context, schema.columns[i], pk, i == alias),
              ],
            ),
          ),
          if (alias == null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'No INTEGER PRIMARY KEY: rows are addressed by their hidden rowid.',
                style: small,
              ),
            ),
          if (pk.length > 1)
            _detail(context, 'Primary key', '(${pk.join(', ')})'),
          for (final fk in schema.foreignKeys)
            _detail(
              context,
              'Foreign key',
              '(${fk.columns.join(', ')}) ${fk.referencesSql}',
            ),
          for (final check in schema.checks) _detail(context, 'Check', check),
          if (indexes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              'Indexes',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            for (final index in indexes)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '${index.name}${index.unique ? ' (unique)' : ''}: '
                  '${index.columns.join(', ')} · ${index.origin.name}',
                  style: small,
                ),
              ),
          ],
          const SizedBox(height: 8),
          _SqlBox(sql: schema.sql),
        ],
      ),
    );
  }

  Widget _detail(BuildContext context, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: cs.onSurface,
              ),
            ),
            TextSpan(
              text: value,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ],
        ),
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  DataRow _columnRow(
    BuildContext context,
    ColumnDefinition col,
    List<String> pk,
    bool isRowidAlias,
  ) {
    final cs = Theme.of(context).colorScheme;
    final inPk =
        col.primaryKey ||
        (pk.length == 1 && pk.first.toLowerCase() == col.name.toLowerCase());
    final flags = [
      if (inPk) isRowidAlias ? 'PRIMARY KEY (rowid)' : 'PRIMARY KEY',
      if (col.autoIncrement) 'AUTOINCREMENT',
      if (col.notNull) 'NOT NULL',
      if (col.unique) 'UNIQUE',
      if (col.defaultSql != null) 'DEFAULT ${col.defaultSql}',
      if (col.collation != null) 'COLLATE ${col.collation}',
    ];
    return DataRow(
      cells: [
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (inPk)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(Icons.key, size: 14, color: cs.primary),
                ),
              Text(
                col.name,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
        DataCell(
          Tooltip(
            message: '${col.affinity.name.toUpperCase()} affinity',
            child: AdminTag(
              label: col.type.isEmpty ? 'ANY' : col.type.toUpperCase(),
              background: cs.secondaryContainer,
              foreground: cs.onSecondaryContainer,
            ),
          ),
        ),
        DataCell(
          Text(
            flags.isEmpty ? '—' : flags.join(' · '),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _SqlBox extends StatelessWidget {
  const _SqlBox({required this.sql});

  final String sql;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: SelectableText(
              sql,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: cs.onSurface,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy CREATE statement',
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: sql));
              if (context.mounted) showAdminMessage(context, 'Copied.');
            },
          ),
        ],
      ),
    );
  }
}

class _NameListCard extends StatelessWidget {
  const _NameListCard({
    required this.title,
    required this.icon,
    required this.names,
  });

  final String title;
  final IconData icon;
  final List<String> names;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Text(
                  '$title (${names.length})',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: cs.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final n in names) AdminTag.neutral(context, n)],
            ),
          ],
        ),
      ),
    );
  }
}

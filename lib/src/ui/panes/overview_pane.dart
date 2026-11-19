/// A database at a glance: its state, stats, objects, versions and the
/// actions on it.
@internal
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../../core/just_database.dart';
import '../../core/query_result.dart';
import '../admin_selection.dart';
import '../admin_style.dart';
import '../admin_utils.dart';
import '../dialogs/database_dialogs.dart';
import '../just_database_admin_controller.dart';
import '../widgets/admin_widgets.dart';

/// The overview of an open database.
@internal
class OverviewPane extends StatelessWidget {
  const OverviewPane({
    super.key,
    required this.controller,
    required this.database,
    this.onSeed,
  });

  final JustDatabaseAdminController controller;
  final JustDatabase database;
  final SeedDatabaseCallback? onSeed;

  bool get _writable => !controller.readOnly;

  Future<void> _do(BuildContext context, DatabaseAction action) =>
      runDatabaseAction(
        context,
        controller,
        database.name,
        action,
        onSeed: onSeed,
      );

  @override
  Widget build(BuildContext context) {
    final db = database;
    if (!db.isOpen) {
      return const EmptyState(
        icon: Icons.storage,
        title: 'The database is closed',
      );
    }
    final cs = Theme.of(context).colorScheme;
    final info = controller.infoFor(db.name);
    final encrypted = controller.isEncrypted(db.name);
    final mine = controller.opened(db.name);
    final tables = db.tableNames;
    final views = db.viewNames;
    final triggers = db.triggerNames;
    final indexCount = tables.fold<int>(
      0,
      (n, t) => n + db.indexesForTable(t).length,
    );
    final saveError = db.saveError;
    final gap = const SizedBox(height: 12);

    final actions = <(DatabaseAction, IconData, String)>[
      if (_writable)
        (DatabaseAction.newTable, Icons.add_box_outlined, 'New table'),
      (DatabaseAction.export, Icons.upload_outlined, 'Export'),
      if (_writable) (DatabaseAction.import, Icons.download_outlined, 'Import'),
      if (_writable) (DatabaseAction.duplicate, Icons.copy_all, 'Duplicate'),
      if (_writable && db.persist)
        (DatabaseAction.encryption, Icons.lock_outline, 'Encryption'),
      if (db.persist) (DatabaseAction.flush, Icons.save_outlined, 'Save now'),
      if (controller.canChangeMode(db.name))
        (DatabaseAction.changeMode, Icons.tune, 'Change mode'),
      (DatabaseAction.benchmark, Icons.speed, 'Benchmark'),
      if (_writable && onSeed != null)
        (DatabaseAction.seed, Icons.auto_awesome_outlined, 'Seed sample data'),
      if (mine) (DatabaseAction.close, Icons.close, 'Close'),
      if (_writable) (DatabaseAction.delete, Icons.delete_outline, 'Delete'),
    ];

    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1000),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                Icon(
                  encrypted ? Icons.lock_outline : Icons.storage,
                  color: cs.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    db.name,
                    style: Theme.of(context).textTheme.titleLarge,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                AdminTag.mode(context, db.mode),
                AdminTag.neutral(
                  context,
                  db.persist ? 'Saved' : 'In memory',
                  icon: db.persist ? Icons.save_outlined : Icons.memory,
                ),
                if (encrypted) AdminTag.encrypted(context),
                AdminTag.neutral(
                  context,
                  mine ? 'Opened here' : 'Opened by the app',
                  icon: mine ? Icons.visibility_outlined : Icons.apps,
                ),
                if (controller.readOnly) AdminTag.readOnly(context),
              ],
            ),
            if (saveError != null)
              MessageBanner(
                key: const ValueKey('jdb-save-error'),
                tone: BannerTone.error,
                margin: const EdgeInsets.only(top: 12),
                message: 'The last save failed: ${describeError(saveError)}',
                actions: [
                  TextButton(
                    onPressed: () => _do(context, DatabaseAction.flush),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            if (db.inTransaction)
              MessageBanner(
                tone: BannerTone.warning,
                margin: const EdgeInsets.only(top: 12),
                message:
                    'A transaction is open: its changes are saved at COMMIT '
                    'and undone by ROLLBACK.',
                actions: _writable
                    ? [
                        TextButton(
                          onPressed: () => db.execute('COMMIT'),
                          child: const Text('Commit'),
                        ),
                        TextButton(
                          onPressed: () => db.execute('ROLLBACK'),
                          child: const Text('Roll back'),
                        ),
                      ]
                    : const [],
              ),
            gap,
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('jdb-open-console'),
                  onPressed: () => controller.showPane(AdminPane.sql),
                  icon: const Icon(Icons.code, size: 18),
                  label: const Text('SQL console'),
                ),
                for (final (action, icon, label) in actions)
                  OutlinedButton.icon(
                    key: ValueKey('jdb-db-action-${action.name}'),
                    style: action == DatabaseAction.delete
                        ? OutlinedButton.styleFrom(foregroundColor: cs.error)
                        : null,
                    onPressed: () => _do(context, action),
                    icon: Icon(icon, size: 18),
                    label: Text(label),
                  ),
              ],
            ),
            gap,
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                StatTile(
                  icon: Icons.table_chart_outlined,
                  label: 'Tables',
                  value: '${tables.length}',
                ),
                StatTile(
                  icon: Icons.format_list_numbered,
                  label: 'Rows',
                  value: '${db.totalRows}',
                ),
                StatTile(
                  icon: Icons.view_agenda_outlined,
                  label: 'Views',
                  value: '${views.length}',
                ),
                StatTile(
                  icon: Icons.bolt,
                  label: 'Triggers',
                  value: '${triggers.length}',
                ),
                StatTile(
                  icon: Icons.manage_search,
                  label: 'Indexes',
                  value: '$indexCount',
                ),
                StatTile(
                  icon: Icons.memory,
                  label: 'In memory',
                  value: formatBytes(db.estimatedSizeBytes),
                ),
                if (db.persist && info != null)
                  StatTile(
                    icon: Icons.insert_drive_file_outlined,
                    label: encrypted ? 'File (encrypted)' : 'File',
                    value: formatBytes(info.sizeBytes),
                  ),
              ],
            ),
            gap,
            SectionCard(
              title: 'Tables',
              children: [
                if (tables.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      _writable
                          ? 'No tables yet: create one with New table or the SQL console.'
                          : 'No tables yet.',
                      style: AdminStyle.caption(context),
                    ),
                  ),
                for (final t in tables)
                  ListTile(
                    key: ValueKey('jdb-overview-table-$t'),
                    dense: true,
                    leading: const Icon(Icons.table_chart_outlined, size: 20),
                    title: Text(t),
                    subtitle: Text(
                      '${plural(db.rowCount(t), 'row')} · '
                      '${plural(db.getTableSchema(t)?.columnNames.length ?? 0, 'column')}',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => controller.select(
                      AdminSelection(
                        db.name,
                        kind: AdminObjectKind.table,
                        object: t,
                      ),
                    ),
                  ),
              ],
            ),
            if (views.isNotEmpty || triggers.isNotEmpty) ...[
              gap,
              SectionCard(
                title: 'Views and triggers',
                children: [
                  for (final v in views)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.view_agenda_outlined, size: 20),
                      title: Text(v),
                      subtitle: const Text('View'),
                      onTap: () => controller.select(
                        AdminSelection(
                          db.name,
                          kind: AdminObjectKind.view,
                          object: v,
                        ),
                      ),
                    ),
                  for (final t in triggers)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.bolt, size: 20),
                      title: Text(t),
                      subtitle: Text(
                        'Trigger on ${db.getTriggerTable(t) ?? '?'}',
                      ),
                      onTap: () => controller.select(
                        AdminSelection(
                          db.name,
                          kind: AdminObjectKind.trigger,
                          object: t,
                        ),
                      ),
                    ),
                ],
              ),
            ],
            gap,
            _VersionsCard(controller: controller, database: db),
          ],
        ),
      ),
    );
  }
}

class _VersionsCard extends StatelessWidget {
  const _VersionsCard({required this.controller, required this.database});

  final JustDatabaseAdminController controller;
  final JustDatabase database;

  Future<void> _setUserVersion(BuildContext context, int current) async {
    final text = await promptText(
      context,
      title: 'Set user_version',
      label: 'user_version',
      initial: '$current',
      helper:
          'A number your app keeps in the file (PRAGMA user_version). '
          'Migrations use their own table, not this.',
      confirmLabel: 'Set',
      validate: (t) =>
          int.tryParse(t.trim()) == null ? 'Enter a whole number.' : null,
    );
    if (text == null || !context.mounted) return;
    final r = await database.execute(
      'PRAGMA user_version = ${int.parse(text.trim())}',
    );
    if (!context.mounted) return;
    reportOutcome(
      context,
      r.success,
      success: 'user_version is now ${text.trim()}.',
      error: r.errorMessage,
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasMigrations = database.getTableSchema('_migrations') != null;
    return FutureBuilder<(QueryResult, QueryResult?)>(
      future: () async {
        final version = await database.query('PRAGMA user_version');
        final migrations = hasMigrations
            ? await database.query(
                'SELECT version, name, applied_at FROM _migrations ORDER BY version',
              )
            : null;
        return (version, migrations);
      }(),
      builder: (context, snap) {
        final data = snap.data;
        final version = data?.$1.scalar as int? ?? 0;
        final migrations = data?.$2;
        return SectionCard(
          title: 'Versions',
          children: [
            ListTile(
              dense: true,
              leading: const Icon(Icons.tag, size: 20),
              title: const Text('user_version'),
              subtitle: Text(data == null ? '…' : '$version'),
              trailing: controller.readOnly || data == null
                  ? null
                  : IconButton(
                      tooltip: 'Set user_version',
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: () => _setUserVersion(context, version),
                    ),
            ),
            if (!hasMigrations)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Text(
                  'No migrations applied (no _migrations table).',
                  style: AdminStyle.caption(context),
                ),
              )
            else if (migrations != null && migrations.success)
              for (final row in migrations.rows)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.history_edu_outlined, size: 20),
                  title: Text('${row['version']}. ${row['name']}'),
                  subtitle: Text('Applied ${row['applied_at']}'),
                ),
          ],
        );
      },
    );
  }
}

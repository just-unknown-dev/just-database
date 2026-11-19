/// The workspace of the wide layout: a header with the selection and its
/// panes, and the pane shown.
@internal
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../../core/just_database.dart';
import '../admin_selection.dart';
import '../admin_style.dart';
import '../dialogs/database_dialogs.dart';
import '../dialogs/schema_dialogs.dart';
import '../just_database_admin_controller.dart';
import '../panes/data_pane.dart';
import '../panes/overview_pane.dart';
import '../panes/sql_console.dart';
import '../panes/structure_pane.dart';
import '../widgets/admin_widgets.dart';

/// The pane for [selection] of the open [database].
@internal
Widget paneFor(
  JustDatabaseAdminController controller,
  JustDatabase database,
  AdminSelection selection, {
  SeedDatabaseCallback? onSeed,
}) {
  final object = selection.object;
  final kind = selection.kind;
  final key = ValueKey(
    'jdb-pane-${database.name}/${kind?.name}/$object/${selection.pane.name}',
  );
  return switch (selection.pane) {
    AdminPane.overview => OverviewPane(
      key: key,
      controller: controller,
      database: database,
      onSeed: onSeed,
    ),
    AdminPane.sql => SqlConsole(
      key: ValueKey('jdb-console-${database.name}'),
      controller: controller,
      database: database,
    ),
    AdminPane.data => DataPane(
      key: key,
      controller: controller,
      database: database,
      object: object!,
      isView: kind == AdminObjectKind.view,
    ),
    AdminPane.structure => StructurePane(
      key: key,
      controller: controller,
      database: database,
      kind: kind!,
      object: object!,
    ),
  };
}

/// The right-hand side of the wide layout.
@internal
class AdminWorkspace extends StatelessWidget {
  const AdminWorkspace({super.key, required this.controller, this.onSeed});

  final JustDatabaseAdminController controller;
  final SeedDatabaseCallback? onSeed;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final sel = c.selection;
    if (sel == null) {
      if (!c.hasLoaded) return const Center(child: CircularProgressIndicator());
      if (c.databases.isEmpty) {
        return EmptyState(
          icon: Icons.storage,
          title: 'No databases yet',
          message: c.readOnly
              ? 'Databases the app opens or saves appear here.'
              : 'Create one, or import a SQL or JSON export.',
          action: c.readOnly
              ? null
              : FilledButton.icon(
                  onPressed: () => showCreateDatabaseDialog(context, c),
                  icon: const Icon(Icons.add),
                  label: const Text('New database'),
                ),
        );
      }
      return const EmptyState(
        icon: Icons.touch_app_outlined,
        title: 'Pick a database',
        message:
            'Choose one on the left to browse its tables, run SQL or see '
            'its overview.',
      );
    }
    final db = JustDatabase.findOpen(sel.database);
    if (db == null) {
      return EmptyState(
        icon: Icons.storage,
        title: '"${sel.database}" is closed',
        action: FilledButton.icon(
          onPressed: () => selectWithPrompt(context, c, sel),
          icon: const Icon(Icons.folder_open_outlined),
          label: const Text('Open'),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(controller: c, database: db, selection: sel, onSeed: onSeed),
        const Divider(height: 1),
        Expanded(child: paneFor(c, db, sel, onSeed: onSeed)),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.controller,
    required this.database,
    required this.selection,
    required this.onSeed,
  });

  final JustDatabaseAdminController controller;
  final JustDatabase database;
  final AdminSelection selection;
  final SeedDatabaseCallback? onSeed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final kind = selection.kind;
    final object = selection.object;
    final panes = AdminPane.panesFor(kind);
    final crumbs = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        TextButton.icon(
          key: const ValueKey('jdb-crumb-database'),
          onPressed: object == null
              ? null
              : () => controller.select(AdminSelection(database.name)),
          icon: const Icon(Icons.storage, size: 18),
          label: Text(
            database.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        if (object != null) ...[
          Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 4),
          Icon(switch (kind!) {
            AdminObjectKind.table => Icons.table_chart_outlined,
            AdminObjectKind.view => Icons.view_agenda_outlined,
            AdminObjectKind.trigger => Icons.bolt,
          }, size: 18),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              object,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                crumbs,
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final pane in panes)
                      _PaneTab(
                        key: ValueKey('jdb-pane-tab-${pane.name}'),
                        label: pane.labelFor(kind),
                        selected: selection.pane == pane,
                        onTap: () => controller.showPane(pane),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (controller.readOnly)
            Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 10),
              child: AdminTag.readOnly(context),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: object == null
                ? PopupMenuButton<DatabaseAction>(
                    key: const ValueKey('jdb-workspace-menu'),
                    tooltip: 'Database actions',
                    onSelected: (a) => runDatabaseAction(
                      context,
                      controller,
                      database.name,
                      a,
                      onSeed: onSeed,
                    ),
                    itemBuilder: (context) => databaseMenuItems(
                      context,
                      controller,
                      database.name,
                      canSeed: onSeed != null,
                    ),
                  )
                : PopupMenuButton<ObjectAction>(
                    key: const ValueKey('jdb-workspace-menu'),
                    tooltip: '${kind!.label} actions',
                    onSelected: (a) => runObjectAction(
                      context,
                      controller,
                      database,
                      kind,
                      object,
                      a,
                    ),
                    itemBuilder: (context) =>
                        objectMenuItems(context, controller, kind, object),
                  ),
          ),
        ],
      ),
    );
  }
}

class _PaneTab extends StatelessWidget {
  const _PaneTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: selected ? cs.primary : cs.primary.withAlpha(0),
              width: 2.5,
            ),
          ),
        ),
        child: Text(
          label,
          style: AdminStyle.label(context).copyWith(
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? cs.primary : cs.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// The phone layout: a list of databases, a page per database (objects,
/// SQL console, overview) and a page per table, view or trigger.
@internal
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../../core/database_manager.dart';
import '../../core/just_database.dart';
import '../admin_selection.dart';
import '../admin_style.dart';
import '../admin_utils.dart';
import '../dialogs/database_dialogs.dart';
import '../dialogs/schema_dialogs.dart';
import '../just_database_admin_controller.dart';
import '../panes/data_pane.dart';
import '../panes/overview_pane.dart';
import '../panes/sql_console.dart';
import '../panes/structure_pane.dart';
import '../widgets/admin_widgets.dart';

/// Pops a compact page once the window is wide: the wide layout shows the
/// same selection.
mixin _PopWhenWide<T extends StatefulWidget> on State<T> {
  bool _popping = false;

  void popIfWide(BuildContext context) {
    if (_popping ||
        MediaQuery.sizeOf(context).width < AdminStyle.wideBreakpoint) {
      return;
    }
    _popping = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Remove this page's own route: two pages popping "the top route" in
      // one frame would both pop the same one.
      final route = mounted ? ModalRoute.of(context) : null;
      if (route != null && route.isActive) {
        Navigator.of(context).removeRoute(route);
      }
    });
  }
}

/// Opens [name] and pushes its page.
@internal
Future<void> openCompactDatabase(
  BuildContext context,
  JustDatabaseAdminController controller,
  String name, {
  SeedDatabaseCallback? onSeed,
}) async {
  if (!await selectWithPrompt(context, controller, AdminSelection(name)) ||
      !context.mounted) {
    return;
  }
  await pushAdminPage<void>(
    context,
    CompactDatabasePage(controller: controller, name: name, onSeed: onSeed),
  );
}

/// The list of databases, as cards.
@internal
class CompactDatabaseList extends StatelessWidget {
  const CompactDatabaseList({super.key, required this.controller, this.onSeed});

  final JustDatabaseAdminController controller;
  final SeedDatabaseCallback? onSeed;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (!c.hasLoaded) {
      return c.lastError == null || c.isBusy
          ? const Center(child: CircularProgressIndicator())
          : EmptyState(
              icon: Icons.error_outline,
              title: 'Could not list the databases',
              message: c.lastError,
              action: FilledButton.icon(
                onPressed: c.refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            );
    }
    if (c.databases.isEmpty) {
      return EmptyState(
        icon: Icons.storage,
        title: 'No databases yet',
        message: c.readOnly
            ? 'Databases the app opens or saves appear here.'
            : 'Create one with the button below, or import an export.',
      );
    }
    return RefreshIndicator(
      onRefresh: c.refresh,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        children: [
          for (final info in c.databases)
            _DatabaseCard(controller: c, info: info, onSeed: onSeed),
        ],
      ),
    );
  }
}

class _DatabaseCard extends StatelessWidget {
  const _DatabaseCard({
    required this.controller,
    required this.info,
    required this.onSeed,
  });

  final JustDatabaseAdminController controller;
  final DatabaseInfo info;
  final SeedDatabaseCallback? onSeed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final db = JustDatabase.findOpen(info.name);
    final details = [
      formatBytes(info.sizeBytes),
      if (db != null) plural(db.tableNames.length, 'table'),
      if (db != null) plural(db.totalRows, 'row'),
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 5),
      child: ListTile(
        key: ValueKey('jdb-db-${info.name}'),
        contentPadding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
        onTap: () =>
            openCompactDatabase(context, controller, info.name, onSeed: onSeed),
        leading: CircleAvatar(
          backgroundColor: db != null ? cs.primary : cs.surfaceContainerHighest,
          foregroundColor: db != null ? cs.onPrimary : cs.onSurfaceVariant,
          child: Icon(
            info.isEncrypted
                ? Icons.lock_outline
                : (info.isPersisted ? Icons.storage : Icons.memory),
            size: 20,
          ),
        ),
        title: Text(
          info.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (db != null)
                AdminTag.mode(context, db.mode)
              else
                AdminTag.neutral(
                  context,
                  'Closed',
                  icon: Icons.circle_outlined,
                ),
              if (info.isEncrypted) AdminTag.encrypted(context),
              if (!info.isPersisted)
                AdminTag.neutral(context, 'In memory', icon: Icons.memory),
              if (db?.saveError != null)
                AdminTag.warning(context, 'Save failed'),
              Text(details, style: AdminStyle.caption(context)),
            ],
          ),
        ),
        trailing: PopupMenuButton<DatabaseAction>(
          tooltip: 'Actions for ${info.name}',
          onSelected: (a) => runDatabaseAction(
            context,
            controller,
            info.name,
            a,
            onSeed: onSeed,
          ),
          itemBuilder: (context) => databaseMenuItems(
            context,
            controller,
            info.name,
            canSeed: onSeed != null,
          ),
        ),
      ),
    );
  }
}

/// A database on a phone: its objects, SQL console and overview.
@internal
class CompactDatabasePage extends StatefulWidget {
  const CompactDatabasePage({
    super.key,
    required this.controller,
    required this.name,
    this.onSeed,
  });

  final JustDatabaseAdminController controller;
  final String name;
  final SeedDatabaseCallback? onSeed;

  @override
  State<CompactDatabasePage> createState() => _CompactDatabasePageState();
}

class _CompactDatabasePageState extends State<CompactDatabasePage>
    with _PopWhenWide {
  int _tab = 0;
  AdminSelection? _seen;
  final _filter = TextEditingController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    popIfWide(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final db = JustDatabase.findOpen(widget.name);
        // "Query in SQL console" elsewhere shows this page's SQL tab.
        final s = c.selection;
        if (s != _seen) {
          _seen = s;
          if (s != null &&
              s.pane == AdminPane.sql &&
              s.database.toLowerCase() == widget.name.toLowerCase()) {
            _tab = 1;
          }
        }
        final Widget body;
        if (db == null) {
          body = EmptyState(
            icon: Icons.storage,
            title: '"${widget.name}" is closed',
            action: FilledButton.icon(
              onPressed: () =>
                  selectWithPrompt(context, c, AdminSelection(widget.name)),
              icon: const Icon(Icons.folder_open_outlined),
              label: const Text('Open'),
            ),
          );
        } else {
          body = switch (_tab) {
            0 => _objects(context, db),
            1 => SqlConsole(
              key: ValueKey('jdb-console-${db.name}'),
              controller: c,
              database: db,
            ),
            _ => OverviewPane(
              controller: c,
              database: db,
              onSeed: widget.onSeed,
            ),
          };
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(widget.name, overflow: TextOverflow.ellipsis),
            actions: [
              if (c.readOnly)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Center(child: AdminTag.readOnly(context)),
                ),
              PopupMenuButton<DatabaseAction>(
                tooltip: 'Database actions',
                onSelected: (a) async {
                  await runDatabaseAction(
                    context,
                    c,
                    widget.name,
                    a,
                    onSeed: widget.onSeed,
                  );
                  if (a == DatabaseAction.delete &&
                      c.infoFor(widget.name) == null &&
                      context.mounted) {
                    Navigator.of(context).maybePop();
                  }
                },
                itemBuilder: (context) => databaseMenuItems(
                  context,
                  c,
                  widget.name,
                  canSeed: widget.onSeed != null,
                ),
              ),
            ],
          ),
          body: SafeArea(child: body),
          floatingActionButton: _tab == 0 && db != null && !c.readOnly
              ? FloatingActionButton(
                  key: const ValueKey('jdb-new-table'),
                  tooltip: 'New table',
                  onPressed: () async {
                    final table = await showCreateTableDialog(
                      context,
                      db,
                      controller: c,
                    );
                    if (table != null && context.mounted) {
                      await _openObject(
                        context,
                        db,
                        AdminObjectKind.table,
                        table,
                        pane: AdminPane.structure,
                      );
                    }
                  },
                  child: const Icon(Icons.add),
                )
              : null,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: const [
              NavigationDestination(
                key: ValueKey('jdb-nav-objects'),
                icon: Icon(Icons.table_chart_outlined),
                label: 'Tables',
              ),
              NavigationDestination(
                key: ValueKey('jdb-nav-sql'),
                icon: Icon(Icons.code),
                label: 'SQL',
              ),
              NavigationDestination(
                key: ValueKey('jdb-nav-overview'),
                icon: Icon(Icons.dashboard_outlined),
                label: 'Overview',
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _openObject(
    BuildContext context,
    JustDatabase db,
    AdminObjectKind kind,
    String name, {
    AdminPane? pane,
  }) async {
    final c = widget.controller;
    await c.select(
      AdminSelection(db.name, kind: kind, object: name, pane: pane),
    );
    if (!context.mounted) return;
    await pushAdminPage<void>(
      context,
      CompactObjectPage(
        controller: c,
        database: db.name,
        kind: kind,
        object: name,
        initialPane: pane,
      ),
    );
  }

  Widget _objects(BuildContext context, JustDatabase db) {
    final filter = _filter.text.trim().toLowerCase();
    bool shown(String n) => filter.isEmpty || n.toLowerCase().contains(filter);
    final total =
        db.tableNames.length + db.viewNames.length + db.triggerNames.length;
    if (total == 0) {
      return EmptyState(
        icon: Icons.table_chart_outlined,
        title: 'No tables yet',
        message: widget.controller.readOnly
            ? null
            : 'Create one with +, or in the SQL tab.',
      );
    }
    Widget header(String label, int count) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        '${label.toUpperCase()} · $count',
        style: AdminStyle.caption(context).copyWith(letterSpacing: 0.6),
      ),
    );
    Widget tile(
      AdminObjectKind kind,
      String name,
      IconData icon,
      String? sub,
    ) => ListTile(
      key: ValueKey('jdb-object-${kind.name}-$name'),
      leading: Icon(icon),
      title: Text(name),
      subtitle: sub == null ? null : Text(sub),
      trailing: PopupMenuButton<ObjectAction>(
        tooltip: 'Actions for $name',
        onSelected: (a) {
          if (a == ObjectAction.browse || a == ObjectAction.structure) {
            unawaited(
              _openObject(
                context,
                db,
                kind,
                name,
                pane: a == ObjectAction.browse
                    ? AdminPane.data
                    : AdminPane.structure,
              ),
            );
            return;
          }
          if (a == ObjectAction.query || a == ObjectAction.editSql) {
            setState(() => _tab = 1);
          }
          unawaited(
            runObjectAction(context, widget.controller, db, kind, name, a),
          );
        },
        itemBuilder: (context) =>
            objectMenuItems(context, widget.controller, kind, name),
      ),
      onTap: () => _openObject(context, db, kind, name),
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        if (total > 8)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: TextField(
              controller: _filter,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'Filter',
                prefixIcon: Icon(Icons.filter_list),
                border: OutlineInputBorder(),
              ),
            ),
          ),
        if (db.tableNames.isNotEmpty) header('Tables', db.tableNames.length),
        for (final t in db.tableNames.where(shown))
          tile(
            AdminObjectKind.table,
            t,
            Icons.table_chart_outlined,
            '${plural(db.rowCount(t), 'row')} · '
            '${plural(db.getTableSchema(t)?.columnNames.length ?? 0, 'column')}',
          ),
        if (db.viewNames.isNotEmpty) header('Views', db.viewNames.length),
        for (final v in db.viewNames.where(shown))
          tile(AdminObjectKind.view, v, Icons.view_agenda_outlined, null),
        if (db.triggerNames.isNotEmpty)
          header('Triggers', db.triggerNames.length),
        for (final t in db.triggerNames.where(shown))
          tile(
            AdminObjectKind.trigger,
            t,
            Icons.bolt,
            'on ${db.getTriggerTable(t) ?? '?'}',
          ),
      ],
    );
  }
}

/// A table, view or trigger on a phone: its data and structure.
@internal
class CompactObjectPage extends StatefulWidget {
  const CompactObjectPage({
    super.key,
    required this.controller,
    required this.database,
    required this.kind,
    required this.object,
    this.initialPane,
  });

  final JustDatabaseAdminController controller;
  final String database;
  final AdminObjectKind kind;
  final String object;
  final AdminPane? initialPane;

  @override
  State<CompactObjectPage> createState() => _CompactObjectPageState();
}

class _CompactObjectPageState extends State<CompactObjectPage>
    with _PopWhenWide {
  late final List<AdminPane> _panes = [
    for (final p in AdminPane.panesFor(widget.kind))
      if (p != AdminPane.sql) p,
  ];

  @override
  Widget build(BuildContext context) {
    popIfWide(context);
    final initial = _panes.indexOf(widget.initialPane ?? _panes.first);
    return DefaultTabController(
      length: _panes.length,
      initialIndex: initial < 0 ? 0 : initial,
      child: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          final c = widget.controller;
          final db = JustDatabase.findOpen(widget.database);
          final gone =
              db == null || createSqlOf(db, widget.kind, widget.object) == null;
          return Scaffold(
            appBar: AppBar(
              title: Text(widget.object, overflow: TextOverflow.ellipsis),
              actions: [
                if (!gone)
                  PopupMenuButton<ObjectAction>(
                    tooltip: '${widget.kind.label} actions',
                    onSelected: (a) async {
                      final tabs = DefaultTabController.of(context);
                      if (a == ObjectAction.browse) {
                        tabs.animateTo(0);
                        return;
                      }
                      if (a == ObjectAction.structure) {
                        tabs.animateTo(_panes.length - 1);
                        return;
                      }
                      await runObjectAction(
                        context,
                        c,
                        db,
                        widget.kind,
                        widget.object,
                        a,
                      );
                      if (!context.mounted) return;
                      // The console lives on the database page.
                      if (a == ObjectAction.query ||
                          a == ObjectAction.editSql) {
                        Navigator.of(context).maybePop();
                      }
                    },
                    itemBuilder: (context) =>
                        objectMenuItems(context, c, widget.kind, widget.object),
                  ),
              ],
              bottom: _panes.length < 2
                  ? null
                  : TabBar(
                      tabs: [
                        for (final p in _panes)
                          Tab(
                            key: ValueKey('jdb-tab-${p.name}'),
                            text: p.labelFor(widget.kind),
                          ),
                      ],
                    ),
            ),
            body: SafeArea(
              child: gone
                  ? EmptyState(
                      icon: Icons.table_chart_outlined,
                      title: '"${widget.object}" no longer exists',
                    )
                  : TabBarView(
                      physics: const NeverScrollableScrollPhysics(),
                      children: [
                        for (final p in _panes)
                          p == AdminPane.data
                              ? DataPane(
                                  controller: c,
                                  database: db,
                                  object: widget.object,
                                  isView: widget.kind == AdminObjectKind.view,
                                )
                              : StructurePane(
                                  controller: c,
                                  database: db,
                                  kind: widget.kind,
                                  object: widget.object,
                                ),
                      ],
                    ),
            ),
          );
        },
      ),
    );
  }
}

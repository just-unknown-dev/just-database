/// The sidebar of the wide layout: databases, and the objects of the
/// selected one.
@internal
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../../core/database_manager.dart';
import '../admin_selection.dart';
import '../admin_style.dart';
import '../admin_utils.dart';
import '../dialogs/backup_dialogs.dart';
import '../dialogs/database_dialogs.dart';
import '../dialogs/schema_dialogs.dart';
import '../just_database_admin_controller.dart';
import '../widgets/admin_widgets.dart';
import '../backend/admin_backend.dart';

/// Shows [items] as a menu at [position] and runs the chosen one.
Future<void> _menuAt<T>(
  BuildContext context,
  Offset position,
  List<PopupMenuEntry<T>> items,
  void Function(T value) onSelected,
) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final value = await showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(
      position & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: items,
  );
  if (value != null) onSelected(value);
}

/// The databases, and the tree of the selected one.
@internal
class DatabaseSidebar extends StatefulWidget {
  const DatabaseSidebar({super.key, required this.controller, this.onSeed});

  final JustDatabaseAdminController controller;
  final SeedDatabaseCallback? onSeed;

  @override
  State<DatabaseSidebar> createState() => _DatabaseSidebarState();
}

class _DatabaseSidebarState extends State<DatabaseSidebar> {
  final _filter = TextEditingController();

  JustDatabaseAdminController get _c => widget.controller;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = _c;
    final Widget list;
    if (!c.hasLoaded) {
      list = c.lastError == null
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(12),
              child: MessageBanner(
                message: c.lastError!,
                tone: BannerTone.error,
                actions: [
                  TextButton(onPressed: c.refresh, child: const Text('Retry')),
                ],
              ),
            );
    } else if (c.databases.isEmpty) {
      list = Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          c.readOnly ? 'No databases.' : 'No databases yet. Create one with +.',
          style: AdminStyle.caption(context),
        ),
      );
    } else {
      list = ListView(
        key: const ValueKey('jdb-sidebar'),
        padding: const EdgeInsets.only(bottom: 24),
        children: [for (final info in c.databases) ..._database(context, info)],
      );
    }
    return Material(
      color: cs.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'DATABASES',
                    style: AdminStyle.caption(
                      context,
                    ).copyWith(fontWeight: FontWeight.w600, letterSpacing: 0.8),
                  ),
                ),
                if (!c.readOnly) ...[
                  IconButton(
                    key: const ValueKey('jdb-sidebar-import'),
                    tooltip: 'Import a database…',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.download_outlined, size: 20),
                    onPressed: () => showImportDialog(context, c),
                  ),
                  IconButton(
                    key: const ValueKey('jdb-new-database'),
                    tooltip: 'New database…',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.add, size: 22),
                    onPressed: () => showCreateDatabaseDialog(context, c),
                  ),
                ],
              ],
            ),
          ),
          if (c.isBusy && c.hasLoaded)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(child: list),
        ],
      ),
    );
  }

  List<Widget> _database(BuildContext context, DatabaseInfo info) {
    final c = _c;
    final cs = Theme.of(context).colorScheme;
    final sel = c.selection;
    final isSelected = sel?.database.toLowerCase() == info.name.toLowerCase();
    final db = c.findOpen(info.name);
    final subtitle = [
      if (db != null) modeShortLabel(db.mode) else 'closed',
      if (!info.isPersisted) 'in memory',
      formatBytes(info.sizeBytes),
    ].join(' · ');
    final tile = _SidebarTile(
      key: ValueKey('jdb-db-${info.name}'),
      selected:
          isSelected && sel?.kind == null && sel?.pane == AdminPane.overview,
      highlighted: isSelected,
      leading: Icon(
        info.isEncrypted
            ? Icons.lock_outline
            : (info.isPersisted ? Icons.storage : Icons.memory),
        size: 20,
        color: db != null ? cs.primary : cs.onSurfaceVariant,
      ),
      title: info.name,
      bold: true,
      subtitle: subtitle,
      trailing: db?.saveError != null
          ? Tooltip(
              message: 'The last save failed',
              child: Icon(
                Icons.warning_amber_rounded,
                size: 18,
                color: cs.error,
              ),
            )
          : null,
      onTap: () => selectWithPrompt(context, c, AdminSelection(info.name)),
      menuButton: true,
      onMenu: (position) => _menuAt<DatabaseAction>(
        context,
        position,
        databaseMenuItems(
          context,
          c,
          info.name,
          canSeed: widget.onSeed != null,
        ),
        (a) =>
            runDatabaseAction(context, c, info.name, a, onSeed: widget.onSeed),
      ),
    );
    if (!isSelected || db == null) return [tile];
    return [tile, ..._tree(context, db)];
  }

  List<Widget> _tree(BuildContext context, AdminDatabase db) {
    final c = _c;
    final sel = c.selection!;
    final filter = _filter.text.trim().toLowerCase();
    bool shown(String name) =>
        filter.isEmpty || name.toLowerCase().contains(filter);
    final tables = db.tableNames.where(shown).toList();
    final views = db.viewNames.where(shown).toList();
    final triggers = db.triggerNames.where(shown).toList();
    final objectCount =
        db.tableNames.length + db.viewNames.length + db.triggerNames.length;

    Widget object(
      AdminObjectKind kind,
      String name,
      IconData icon, {
      String? count,
    }) {
      final selected = sel.isObject(db.name, kind, name);
      return _SidebarTile(
        key: ValueKey('jdb-object-${kind.name}-$name'),
        indent: 1,
        selected: selected,
        leading: Icon(icon, size: 18),
        title: name,
        count: count,
        onTap: () {
          final pane =
              sel.kind == kind &&
                  AdminPane.panesFor(kind).contains(sel.pane) &&
                  sel.pane != AdminPane.sql
              ? sel.pane
              : null;
          unawaited(
            c.select(
              AdminSelection(db.name, kind: kind, object: name, pane: pane),
            ),
          );
        },
        onMenu: (position) => _menuAt<ObjectAction>(
          context,
          position,
          objectMenuItems(context, c, kind, name),
          (a) => runObjectAction(context, c, db, kind, name, a),
        ),
      );
    }

    return [
      _SidebarTile(
        key: const ValueKey('jdb-tree-overview'),
        indent: 1,
        selected: sel.kind == null && sel.pane == AdminPane.overview,
        leading: const Icon(Icons.dashboard_outlined, size: 18),
        title: 'Overview',
        onTap: () => c.select(AdminSelection(db.name)),
      ),
      _SidebarTile(
        key: const ValueKey('jdb-tree-sql'),
        indent: 1,
        selected: sel.kind == null && sel.pane == AdminPane.sql,
        leading: const Icon(Icons.code, size: 18),
        title: 'SQL console',
        onTap: () => c.select(AdminSelection(db.name, pane: AdminPane.sql)),
      ),
      if (objectCount > 8)
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 6, 12, 2),
          child: TextField(
            key: const ValueKey('jdb-tree-filter'),
            controller: _filter,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              isDense: true,
              hintText: 'Filter',
              prefixIcon: const Icon(Icons.filter_list, size: 18),
              border: const OutlineInputBorder(),
              suffixIcon: _filter.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () => setState(_filter.clear),
                    ),
            ),
          ),
        ),
      _SectionHeader(
        label: 'Tables',
        count: db.tableNames.length,
        onAdd: c.readOnly
            ? null
            : () => runDatabaseAction(
                context,
                c,
                db.name,
                DatabaseAction.newTable,
              ),
      ),
      for (final t in tables)
        object(
          AdminObjectKind.table,
          t,
          Icons.table_chart_outlined,
          count: '${db.rowCount(t)}',
        ),
      if (db.viewNames.isNotEmpty) ...[
        _SectionHeader(label: 'Views', count: db.viewNames.length),
        for (final v in views)
          object(AdminObjectKind.view, v, Icons.view_agenda_outlined),
      ],
      if (db.triggerNames.isNotEmpty) ...[
        _SectionHeader(label: 'Triggers', count: db.triggerNames.length),
        for (final t in triggers)
          object(AdminObjectKind.trigger, t, Icons.bolt),
      ],
    ];
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count, this.onAdd});

  final String label;
  final int count;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${label.toUpperCase()} · $count',
              style: AdminStyle.caption(
                context,
              ).copyWith(fontSize: 11, letterSpacing: 0.6),
            ),
          ),
          if (onAdd != null)
            IconButton(
              key: ValueKey('jdb-tree-add-${label.toLowerCase()}'),
              tooltip: 'New table…',
              visualDensity: VisualDensity.compact,
              iconSize: 18,
              icon: const Icon(Icons.add),
              onPressed: onAdd,
            ),
        ],
      ),
    );
  }
}

class _SidebarTile extends StatelessWidget {
  const _SidebarTile({
    super.key,
    required this.title,
    required this.onTap,
    this.leading,
    this.subtitle,
    this.count,
    this.trailing,
    this.selected = false,
    this.highlighted = false,
    this.bold = false,
    this.indent = 0,
    this.onMenu,
    this.menuButton = false,
  });

  final String title;
  final VoidCallback onTap;
  final Widget? leading;
  final String? subtitle;
  final String? count;
  final Widget? trailing;
  final bool selected;
  final bool highlighted;
  final bool bold;
  final int indent;
  final void Function(Offset position)? onMenu;

  /// Whether a ⋮ button opens [onMenu] too (right click and long press
  /// always do).
  final bool menuButton;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = selected ? cs.onSecondaryContainer : cs.onSurface;
    return Padding(
      padding: EdgeInsets.fromLTRB(8.0 + indent * 16, 1, 8, 1),
      child: Material(
        color: selected
            ? cs.secondaryContainer
            : (highlighted
                  ? cs.surfaceContainerHigh
                  : cs.surfaceContainerHigh.withAlpha(0)),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          onSecondaryTapUp: onMenu == null
              ? null
              : (d) => onMenu!(d.globalPosition),
          child: GestureDetector(
            onLongPressStart: onMenu == null
                ? null
                : (d) => onMenu!(d.globalPosition),
            child: Padding(
              padding: EdgeInsets.fromLTRB(8, subtitle == null ? 6 : 6, 4, 6),
              child: Row(
                children: [
                  if (leading != null) ...[
                    IconTheme.merge(
                      data: IconThemeData(color: selected ? cs.primary : null),
                      child: leading!,
                    ),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            color: fg,
                            fontWeight: bold ? FontWeight.w600 : null,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AdminStyle.caption(
                              context,
                            ).copyWith(fontSize: 11),
                          ),
                      ],
                    ),
                  ),
                  if (count != null)
                    Text(
                      count!,
                      style: AdminStyle.caption(context).copyWith(fontSize: 11),
                    ),
                  ?trailing,
                  if (onMenu != null && menuButton)
                    Builder(
                      builder: (context) => IconButton(
                        tooltip: 'Actions for $title',
                        visualDensity: VisualDensity.compact,
                        iconSize: 18,
                        icon: const Icon(Icons.more_vert),
                        onPressed: () {
                          final box = context.findRenderObject() as RenderBox;
                          onMenu!(
                            box.localToGlobal(box.size.bottomLeft(Offset.zero)),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

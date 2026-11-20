import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'admin_style.dart';
import 'admin_theme.dart';
import 'dialogs/backup_dialogs.dart';
import 'dialogs/database_dialogs.dart';
import 'just_database_admin_controller.dart';
import 'pages/settings_page.dart';
import 'shell/compact_pages.dart';
import 'shell/sidebar.dart';
import 'shell/workspace.dart';
import 'widgets/admin_widgets.dart';

/// The database workbench: every database of the app, their tables, views
/// and triggers, a data browser and editor, a SQL console, schema editing,
/// backups, encryption and benchmarks.
///
/// On a wide screen (840 logical pixels or more) it shows a sidebar of
/// databases and objects beside the selected one's panes; on a phone the
/// same pieces are pages you drill into. It shows the databases the app
/// has open (sharing those instances) as well as the saved ones, and stays
/// current while the app works.
///
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => const JustDatabaseAdminScreen(),
/// ));
/// ```
///
/// Pass `readOnly: true` (or a read-only [controller]) for a screen that
/// cannot change anything, such as a debug menu in a shipped game.
///
/// It has its own look, black and grey with coral accents, and is dark
/// until the user picks light or the device's setting (the app bar's toggle, or Settings; see
/// [JustDatabaseAdminController.themeMode]). Give it a [theme] for other
/// colours.
class JustDatabaseAdminScreen extends StatefulWidget {
  /// Creates the screen.
  const JustDatabaseAdminScreen({
    super.key,
    this.controller,
    this.readOnly = false,
    this.theme,
    this.title = 'Just Database',
    this.onSeedDatabase,
  });

  /// The state to show. When null the screen makes its own (with
  /// [readOnly]) and disposes it, closing the databases it opened, when it
  /// goes away.
  final JustDatabaseAdminController? controller;

  /// Whether the screen's own controller is read-only (a given
  /// [controller] has its own setting).
  final bool readOnly;

  /// A theme for the screen and the pages and dialogs it opens; when null,
  /// the workbench's own colours (greys with coral accents) in the app's
  /// font. When the user
  /// picks the other brightness, a theme with that brightness is made from
  /// its colours.
  final ThemeData? theme;

  /// The app bar title.
  final String title;

  /// Adds a "Seed sample data" action to each database when given.
  final SeedDatabaseCallback? onSeedDatabase;

  @override
  State<JustDatabaseAdminScreen> createState() =>
      _JustDatabaseAdminScreenState();
}

class _JustDatabaseAdminScreenState extends State<JustDatabaseAdminScreen> {
  late JustDatabaseAdminController _controller;
  late bool _ownsController;
  double _sidebarWidth = 290;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    final given = widget.controller;
    _ownsController = given == null;
    _controller =
        given ?? JustDatabaseAdminController(readOnly: widget.readOnly);
  }

  @override
  void didUpdateWidget(JustDatabaseAdminScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        (widget.controller == null && oldWidget.readOnly != widget.readOnly)) {
      if (_ownsController) _controller.dispose();
      _attach();
    }
  }

  @override
  void dispose() {
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  Future<void> _refresh(BuildContext context) async {
    final ok = await _controller.refresh();
    if (!ok && context.mounted) {
      showAdminError(context, _controller.lastError ?? 'Refresh failed.');
    }
  }

  List<Widget> _actions(BuildContext context) => [
    if (_controller.isBusy)
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      )
    else
      IconButton(
        key: const ValueKey('jdb-refresh'),
        icon: const Icon(Icons.refresh),
        tooltip: 'Refresh (F5)',
        onPressed: () => _refresh(context),
      ),
    _themeToggle(context),
    IconButton(
      key: const ValueKey('jdb-settings'),
      icon: const Icon(Icons.settings_outlined),
      tooltip: 'Settings',
      onPressed: () =>
          pushAdminPage<void>(context, SettingsPage(controller: _controller)),
    ),
  ];

  Widget _themeToggle(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IconButton(
      key: const ValueKey('jdb-theme-toggle'),
      icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
      tooltip: dark ? 'Light mode' : 'Dark mode',
      onPressed: () =>
          _controller.setThemeMode(dark ? ThemeMode.light : ThemeMode.dark),
    );
  }

  Widget _title(BuildContext context) => Row(
    children: [
      Flexible(child: Text(widget.title, overflow: TextOverflow.ellipsis)),
      if (_controller.readOnly) ...[
        const SizedBox(width: 10),
        AdminTag.readOnly(context),
      ],
    ],
  );

  @override
  Widget build(BuildContext context) {
    final screen = LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= AdminStyle.wideBreakpoint;
        return AdminLayoutScope(
          wide: wide,
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.f5): () =>
                    unawaited(_refresh(context)),
              },
              child: wide
                  ? _wide(context, constraints.maxWidth)
                  : _compact(context),
            ),
          ),
        );
      },
    );
    return AdminTheme(
      controller: _controller,
      theme: widget.theme,
      child: screen,
    );
  }

  Widget _wide(BuildContext context, double width) {
    final sidebar = _sidebarWidth.clamp(220.0, width * 0.45);
    return Scaffold(
      appBar: AppBar(title: _title(context), actions: _actions(context)),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: sidebar,
            child: DatabaseSidebar(
              controller: _controller,
              onSeed: widget.onSeedDatabase,
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.resizeColumn,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (d) => setState(() {
                _sidebarWidth = (sidebar + d.delta.dx).clamp(
                  220.0,
                  width * 0.45,
                );
              }),
              child: const VerticalDivider(width: 6, thickness: 1),
            ),
          ),
          Expanded(
            child: AdminWorkspace(
              controller: _controller,
              onSeed: widget.onSeedDatabase,
            ),
          ),
        ],
      ),
    );
  }

  Widget _compact(BuildContext context) {
    final c = _controller;
    return Scaffold(
      appBar: AppBar(
        title: _title(context),
        actions: [
          if (!c.readOnly)
            IconButton(
              key: const ValueKey('jdb-import-database'),
              tooltip: 'Import a database',
              icon: const Icon(Icons.download_outlined),
              onPressed: () => showImportDialog(context, c),
            ),
          ..._actions(context),
        ],
      ),
      body: SafeArea(
        child: CompactDatabaseList(
          controller: c,
          onSeed: widget.onSeedDatabase,
        ),
      ),
      floatingActionButton: c.readOnly
          ? null
          : FloatingActionButton.extended(
              key: const ValueKey('jdb-new-database'),
              onPressed: () async {
                final name = await showCreateDatabaseDialog(context, c);
                if (name != null && context.mounted) {
                  await openCompactDatabase(
                    context,
                    c,
                    name,
                    onSeed: widget.onSeedDatabase,
                  );
                }
              },
              icon: const Icon(Icons.add),
              label: const Text('New database'),
            ),
    );
  }
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_signals/just_signals.dart';

import '../core/just_database.dart';
import 'admin_utils.dart';
import 'database_provider.dart';
import 'tabs/databases_tab.dart';
import 'tabs/query_editor_tab.dart';
import 'tabs/schema_tab.dart';
import 'tabs/settings_tab.dart';
import 'widgets/admin_widgets.dart';

/// Fills a database with sample data (the Databases tab's "Seed sample
/// data" action).
typedef SeedDatabaseCallback = Future<void> Function(JustDatabase db);

/// The admin screen: lists every database of the app and lets you browse,
/// edit, query, benchmark, create and delete them.
///
/// It shows the databases the app has open (and uses those instances) as
/// well as the saved ones. Use it as a page of its own:
///
/// ```dart
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => const JustDatabaseAdminScreen(),
/// ));
/// ```
///
/// or as `home`. The back button only appears when there is a page to go
/// back to.
class JustDatabaseAdminScreen extends StatefulWidget {
  /// Creates the admin screen.
  const JustDatabaseAdminScreen({
    super.key,
    this.theme,
    this.onSeedDatabase,
    this.provider,
    this.title = 'Just Database',
  });

  /// A theme for the screen and every page it opens; the app's theme when
  /// null.
  final ThemeData? theme;

  /// Adds a "Seed sample data" action to each database when given.
  final SeedDatabaseCallback? onSeedDatabase;

  /// The state to show. When null the screen makes its own and disposes it
  /// (closing the databases it opened) when it goes away.
  final DatabaseProvider? provider;

  /// The app bar title.
  final String title;

  @override
  State<JustDatabaseAdminScreen> createState() =>
      _JustDatabaseAdminScreenState();
}

class _JustDatabaseAdminScreenState extends State<JustDatabaseAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController = TabController(
    length: 4,
    vsync: this,
  );
  late DatabaseProvider _provider;
  late bool _ownsProvider;

  static const _tabs = [
    Tab(icon: Icon(Icons.storage), text: 'Databases'),
    Tab(icon: Icon(Icons.schema), text: 'Schema'),
    Tab(icon: Icon(Icons.code), text: 'Query'),
    Tab(icon: Icon(Icons.settings), text: 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    _attach(widget.provider);
  }

  void _attach(DatabaseProvider? provider) {
    _ownsProvider = provider == null;
    _provider = provider ?? DatabaseProvider();
    unawaited(_provider.refreshDatabases());
  }

  @override
  void didUpdateWidget(JustDatabaseAdminScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider) {
      if (_ownsProvider) unawaited(_provider.dispose());
      _attach(widget.provider);
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    if (_ownsProvider) unawaited(_provider.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = SignalBuilder<int>(
      signal: _provider.revision,
      builder: (context, _, _) {
        final db = _provider.currentDatabase;
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                Flexible(
                  child: Text(widget.title, overflow: TextOverflow.ellipsis),
                ),
                if (db != null) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: _CurrentDatabaseChip(
                      db: db,
                      encrypted: _provider.isEncrypted(db.name),
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              if (_provider.isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
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
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: () => _refresh(context),
                ),
            ],
            bottom: TabBar(
              controller: _tabController,
              tabs: _tabs,
              indicatorSize: TabBarIndicatorSize.tab,
            ),
          ),
          body: TabBarView(
            controller: _tabController,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              DatabasesTab(
                provider: _provider,
                seedCallback: widget.onSeedDatabase,
              ),
              SchemaTab(provider: _provider),
              QueryEditorTab(provider: _provider),
              SettingsTab(provider: _provider),
            ],
          ),
        );
      },
    );
    final theme = widget.theme;
    return theme == null ? screen : Theme(data: theme, child: screen);
  }

  Future<void> _refresh(BuildContext context) async {
    final ok = await _provider.refreshDatabases();
    if (!ok && context.mounted) {
      showAdminError(context, _provider.lastError ?? 'Refresh failed.');
    }
  }
}

class _CurrentDatabaseChip extends StatelessWidget {
  const _CurrentDatabaseChip({required this.db, required this.encrypted});

  final JustDatabase db;
  final bool encrypted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Tooltip(
      message:
          '${db.name}: ${modeLabel(db.mode)} mode, '
          '${db.persist ? 'saved' : 'in memory'}'
          '${encrypted ? ', encrypted' : ''}',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              encrypted ? Icons.lock_outline : Icons.storage,
              size: 14,
              color: cs.onSecondaryContainer,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                db.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: cs.onSecondaryContainer),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              modeShortLabel(db.mode),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: cs.onSecondaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

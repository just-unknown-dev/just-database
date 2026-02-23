import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_database/just_database.dart';

/// Callback type for seeding a database with initial sample data.
typedef SeedDatabaseCallback = Future<void> Function(JustDatabase db);

class JUDatabaseAdminScreen extends StatefulWidget {
  final ThemeData? theme;

  /// Optional callback to seed a database with sample data.
  /// When provided, a "Seed Sample Data" option appears in each database card's
  /// popup menu. When null, the option is hidden.
  final SeedDatabaseCallback? onSeedDatabase;

  const JUDatabaseAdminScreen({super.key, this.theme, this.onSeedDatabase});

  @override
  State<JUDatabaseAdminScreen> createState() => _JUDatabaseAdminScreenState();
}

class _JUDatabaseAdminScreenState extends State<JUDatabaseAdminScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  static const _tabs = [
    Tab(icon: Icon(Icons.storage), text: 'Databases'),
    Tab(icon: Icon(Icons.schema), text: 'Schema'),
    Tab(icon: Icon(Icons.code), text: 'Query'),
    Tab(icon: Icon(Icons.settings), text: 'Settings'),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    // Refresh on startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<DatabaseProvider>().refreshDatabases();
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DatabaseProvider>();
    final scaffold = Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          icon: Icon(Icons.arrow_back_ios_outlined, size: 18),
        ),
        title: Row(
          children: [
            const Text('Just Database'),
            if (provider.currentDatabase != null) ...[
              const SizedBox(width: 8),
              _DatabaseBadge(db: provider.currentDatabase!),
            ],
          ],
        ),
        bottom: TabBar(
          controller: _tabController,
          tabs: _tabs,
          indicatorSize: TabBarIndicatorSize.tab,
        ),
        actions: [
          if (provider.isLoading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
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
              onPressed: provider.refreshDatabases,
            ),
        ],
      ),
      body: TabBarView(
        controller: _tabController,
        physics:
            const NeverScrollableScrollPhysics(), // prevent accidental swipes
        children: [
          DatabasesTab(seedCallback: widget.onSeedDatabase),
          const SchemaTab(),
          const QueryEditorTab(),
          const SettingsTab(),
        ],
      ),
    );

    // Apply custom theme if provided
    return widget.theme != null
        ? Theme(data: widget.theme!, child: scaffold)
        : scaffold;
  }
}

class _DatabaseBadge extends StatelessWidget {
  final JustDatabase db;
  const _DatabaseBadge({required this.db});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final modeAbbr = switch (db.mode) {
      DatabaseMode.standard => 'STD',
      DatabaseMode.readFast => 'R+',
      DatabaseMode.writeFast => 'W+',
      DatabaseMode.secure => 'SEC',
    };
    return Chip(
      avatar: CircleAvatar(
        backgroundColor: colorScheme.primary,
        radius: 8,
        child: Text(
          modeAbbr,
          style: const TextStyle(
            fontSize: 7,
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
      label: Text(
        db.name.length > 12 ? '${db.name.substring(0, 12)}…' : db.name,
        style: const TextStyle(fontSize: 12),
      ),
      backgroundColor: colorScheme.primaryContainer,
      labelStyle: TextStyle(color: colorScheme.onPrimaryContainer),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}

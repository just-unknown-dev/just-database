import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_database/just_database.dart';
import '../pages/benchmark_page.dart';
import '../pages/insert_page.dart';

class DatabasesTab extends StatelessWidget {
  /// Optional seed callback passed down from [JUDatabaseAdminScreen].
  final Future<void> Function(JustDatabase db)? seedCallback;

  const DatabasesTab({super.key, this.seedCallback});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DatabaseProvider>();
    return Scaffold(
      body: provider.isLoading
          ? const Center(child: CircularProgressIndicator())
          : provider.databases.isEmpty
          ? _EmptyView(
              onCreatePressed: () => _showCreateDialog(context, provider),
            )
          : RefreshIndicator(
              onRefresh: provider.refreshDatabases,
              child: ListView.builder(
                itemCount: provider.databases.length,
                itemBuilder: (_, i) {
                  final info = provider.databases[i];
                  return _DatabaseCard(
                    info: info,
                    isSelected: provider.currentDatabase?.name == info.name,
                    onOpen: () => provider.selectDatabase(info.name),
                    onDelete: () =>
                        _confirmDelete(context, provider, info.name),
                    onSeed: seedCallback != null
                        ? () => _seedDatabase(
                            context,
                            provider,
                            info,
                            seedCallback!,
                          )
                        : null,
                    onInsert: () => _openInsertPage(context, provider, info),
                    onBenchmark: () =>
                        _openBenchmarkPage(context, provider, info),
                  );
                },
              ),
            ),
      floatingActionButton: provider.databases.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _showCreateDialog(context, provider),
              icon: const Icon(Icons.add),
              label: const Text('New Database'),
            ),
    );
  }

  void _showCreateDialog(BuildContext context, DatabaseProvider provider) {
    final nameController = TextEditingController();
    DatabaseMode selectedMode = provider.defaultMode;
    bool selectedPersist = provider.persistEnabled;

    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('New Database'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Database name',
                    hintText: 'e.g. myapp',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Mode:',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                RadioGroup<DatabaseMode>(
                  groupValue: selectedMode,
                  onChanged: (v) => setState(() => selectedMode = v!),
                  child: Column(
                    children: DatabaseMode.values
                        .map(
                          (mode) => RadioListTile<DatabaseMode>(
                            dense: true,
                            title: Text(_modeName(mode)),
                            subtitle: Text(_modeDescription(mode)),
                            value: mode,
                          ),
                        )
                        .toList(),
                  ),
                ),
                if (selectedMode == DatabaseMode.secure) ...[
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green.shade200),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.lock, size: 16, color: Colors.green),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'A unique AES-256 encryption key is automatically generated for this database.',
                            style: TextStyle(fontSize: 12, color: Colors.green),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const Divider(height: 20),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Persist to disk'),
                  subtitle: const Text('Save this database to local storage'),
                  value: selectedPersist,
                  onChanged: (v) => setState(() => selectedPersist = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(ctx);
                provider.createDatabase(
                  name,
                  mode: selectedMode,
                  persist: selectedPersist,
                );
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDelete(
    BuildContext context,
    DatabaseProvider provider,
    String name,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Database'),
        content: Text('Delete "$name"? All data will be permanently removed.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () {
              Navigator.pop(ctx);
              provider.deleteDatabase(name);
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Future<void> _openBenchmarkPage(
    BuildContext context,
    DatabaseProvider provider,
    DatabaseInfo info,
  ) async {
    await provider.selectDatabase(info.name);
    if (!context.mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (_) => BenchmarkPage(info: info)),
    );
  }

  Future<void> _openInsertPage(
    BuildContext context,
    DatabaseProvider provider,
    DatabaseInfo info,
  ) async {
    await provider.selectDatabase(info.name);
    if (!context.mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (_) => const InsertPage()),
    );
  }

  Future<void> _seedDatabase(
    BuildContext context,
    DatabaseProvider provider,
    DatabaseInfo info,
    Future<void> Function(JustDatabase db) callback,
  ) async {
    await provider.selectDatabase(info.name);
    final db = provider.currentDatabase;
    if (db == null) return;
    try {
      await callback(db);
      await provider.refreshDatabases();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Seeded "${info.name}" with sample data'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Seed failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
}

class _DatabaseCard extends StatelessWidget {
  final DatabaseInfo info;
  final bool isSelected;
  final VoidCallback onOpen;
  final VoidCallback onDelete;
  final VoidCallback? onSeed;
  final VoidCallback onInsert;
  final VoidCallback onBenchmark;

  const _DatabaseCard({
    required this.info,
    required this.isSelected,
    required this.onOpen,
    required this.onDelete,
    this.onSeed,
    required this.onInsert,
    required this.onBenchmark,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      color: isSelected ? colorScheme.primaryContainer : null,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: info.isOpen
              ? colorScheme.primary
              : Colors.grey.shade400,
          child: Icon(
            info.isOpen ? Icons.lock_open : Icons.lock_outline,
            color: Colors.white,
            size: 18,
          ),
        ),
        title: Text(
          info.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Row(
          children: [
            _ModeBadge(mode: info.mode),
            const SizedBox(width: 8),
            Text(info.formattedSize),
            if (info.tableCount > 0) ...[
              const SizedBox(width: 8),
              Text(
                '${info.tableCount} table${info.tableCount != 1 ? 's' : ''}',
              ),
            ],
            if (isSelected) ...[
              const SizedBox(width: 8),
              const Icon(Icons.check_circle, color: Colors.green, size: 14),
            ],
          ],
        ),
        trailing: PopupMenuButton<String>(
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'open', child: Text('Open')),
            const PopupMenuItem(value: 'insert', child: Text('Insert Row')),
            const PopupMenuItem(value: 'benchmark', child: Text('Benchmark')),
            if (onSeed != null)
              const PopupMenuItem(
                value: 'seed',
                child: Text('Seed Sample Data'),
              ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'delete',
              child: Text(
                'Delete',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
          onSelected: (action) {
            switch (action) {
              case 'open':
                onOpen();
              case 'insert':
                onInsert();
              case 'benchmark':
                onBenchmark();
              case 'seed':
                onSeed?.call();
              case 'delete':
                onDelete();
            }
          },
        ),
        onTap: onOpen,
      ),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  final DatabaseMode mode;
  const _ModeBadge({required this.mode});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (mode) {
      DatabaseMode.standard => ('Standard', Colors.blue),
      DatabaseMode.readFast => ('Read+', Colors.green),
      DatabaseMode.writeFast => ('Write+', Colors.orange),
      DatabaseMode.secure => ('Secure', Colors.purple),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(30),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  final VoidCallback onCreatePressed;
  const _EmptyView({required this.onCreatePressed});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.storage, size: 72, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'No databases yet',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Create a database to get started.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onCreatePressed,
            icon: const Icon(Icons.add),
            label: const Text('Create Database'),
          ),
        ],
      ),
    );
  }
}

String _modeName(DatabaseMode mode) {
  switch (mode) {
    case DatabaseMode.standard:
      return 'Standard';
    case DatabaseMode.readFast:
      return 'Read Fast';
    case DatabaseMode.writeFast:
      return 'Write Fast';
    case DatabaseMode.secure:
      return 'Secure';
  }
}

String _modeDescription(DatabaseMode mode) {
  switch (mode) {
    case DatabaseMode.standard:
      return 'Balanced read/write mutex locks';
    case DatabaseMode.readFast:
      return 'Many concurrent readers, exclusive writers';
    case DatabaseMode.writeFast:
      return 'Buffered writes, batch commits';
    case DatabaseMode.secure:
      return 'AES-256-GCM encrypted at rest';
  }
}

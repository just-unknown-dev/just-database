import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_signals/just_signals.dart';

import '../../core/database_manager.dart';
import '../../core/database_mode.dart';
import '../../core/just_database.dart';
import '../admin_utils.dart';
import '../database_provider.dart';
import '../pages/benchmark_page.dart';
import '../pages/database_detail_page.dart';
import '../pages/insert_page.dart';
import '../widgets/admin_widgets.dart';

/// The list of databases, with actions to open, browse, insert into,
/// benchmark, seed, create and delete them.
class DatabasesTab extends StatelessWidget {
  /// Creates the tab.
  const DatabasesTab({super.key, required this.provider, this.seedCallback});

  /// The admin state.
  final DatabaseProvider provider;

  /// Fills a database with sample data; adds a "Seed sample data" action
  /// when given.
  final Future<void> Function(JustDatabase db)? seedCallback;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder<int>(
      signal: provider.revision,
      builder: (context, _, _) {
        final databases = provider.databases;
        final Widget body;
        if (!provider.hasLoaded) {
          body = provider.isLoading || provider.lastError == null
              ? const Center(child: CircularProgressIndicator())
              : EmptyState(
                  icon: Icons.error_outline,
                  title: 'Could not list the databases',
                  message: provider.lastError,
                  action: FilledButton.icon(
                    onPressed: () => _refresh(context),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                );
        } else if (databases.isEmpty) {
          body = EmptyState(
            icon: Icons.storage,
            title: 'No databases yet',
            message: 'Create a database to get started.',
            action: FilledButton.icon(
              onPressed: () => _create(context),
              icon: const Icon(Icons.add),
              label: const Text('Create database'),
            ),
          );
        } else {
          final current = provider.currentDatabase?.name.toLowerCase();
          body = RefreshIndicator(
            onRefresh: () => _refresh(context),
            child: ListView.builder(
              padding: const EdgeInsets.only(top: 6, bottom: 96),
              itemCount: databases.length,
              itemBuilder: (context, i) {
                final info = databases[i];
                return _DatabaseCard(
                  info: info,
                  isSelected: current == info.name.toLowerCase(),
                  onSelect: () => _select(context, info),
                  onAction: (action) => _onAction(context, info, action),
                  canSeed: seedCallback != null,
                );
              },
            ),
          );
        }
        return Scaffold(
          body: Stack(
            children: [
              Positioned.fill(child: body),
              if (provider.isLoading && provider.hasLoaded)
                const Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: LinearProgressIndicator(minHeight: 2),
                ),
            ],
          ),
          floatingActionButton: databases.isEmpty
              ? null
              : FloatingActionButton.extended(
                  onPressed: () => _create(context),
                  icon: const Icon(Icons.add),
                  label: const Text('New database'),
                ),
        );
      },
    );
  }

  Future<void> _refresh(BuildContext context) async {
    final ok = await provider.refreshDatabases();
    if (!ok && context.mounted) {
      showAdminError(context, provider.lastError ?? 'Refresh failed.');
    }
  }

  Future<void> _select(BuildContext context, DatabaseInfo info) async {
    final ok = await provider.selectDatabase(info.name);
    if (!context.mounted) return;
    if (!ok) {
      showAdminError(
        context,
        provider.lastError ?? 'Could not open "${info.name}".',
      );
    }
  }

  /// Selects [info] and returns its instance, or null (after showing why)
  /// when the selected database is not [info].
  Future<JustDatabase?> _selected(
    BuildContext context,
    DatabaseInfo info,
  ) async {
    final ok = await provider.selectDatabase(info.name);
    if (!context.mounted) return null;
    final db = provider.currentDatabase;
    if (!ok || db == null || db.name.toLowerCase() != info.name.toLowerCase()) {
      showAdminError(
        context,
        provider.lastError ?? 'Could not open "${info.name}".',
      );
      return null;
    }
    return db;
  }

  Future<void> _onAction(
    BuildContext context,
    DatabaseInfo info,
    _CardAction action,
  ) async {
    switch (action) {
      case _CardAction.browse:
        final db = await _selected(context, info);
        if (db == null || !context.mounted) return;
        await pushAdminPage<void>(
          context,
          DatabaseDetailPage(database: db, provider: provider),
        );
      case _CardAction.insert:
        final db = await _selected(context, info);
        if (db == null || !context.mounted) return;
        await pushAdminPage<void>(
          context,
          InsertPage(database: db, provider: provider),
        );
      case _CardAction.benchmark:
        final db = await _selected(context, info);
        if (db == null || !context.mounted) return;
        await pushAdminPage<void>(context, BenchmarkPage(database: db));
      case _CardAction.seed:
        await _seed(context, info);
      case _CardAction.delete:
        await _confirmDelete(context, info);
    }
  }

  Future<void> _seed(BuildContext context, DatabaseInfo info) async {
    final seed = seedCallback;
    if (seed == null) return;
    final db = await _selected(context, info);
    if (db == null || !context.mounted) return;
    try {
      await seed(db);
      await provider.refreshDatabases();
      if (context.mounted) {
        showAdminMessage(context, 'Added sample data to "${info.name}".');
      }
    } catch (e) {
      if (context.mounted) {
        showAdminError(
          context,
          'Seeding "${info.name}" failed: ${describeError(e)}',
        );
      }
    }
  }

  Future<void> _create(BuildContext context) async {
    final request = await showDialog<_CreateRequest>(
      context: context,
      builder: (_) => _CreateDatabaseDialog(provider: provider),
    );
    if (request == null || !context.mounted) return;
    final ok = await provider.createDatabase(
      request.name,
      mode: request.mode,
      persist: request.persist,
      encrypted: request.encrypted,
    );
    if (!context.mounted) return;
    if (ok) {
      showAdminMessage(context, 'Created "${request.name}".');
    } else {
      showAdminError(
        context,
        provider.lastError ?? 'Could not create "${request.name}".',
      );
    }
  }

  Future<void> _confirmDelete(BuildContext context, DatabaseInfo info) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('Delete database?'),
          content: Text(
            'Delete "${info.name}"? All of its data is removed for good.'
            '${info.isOpen ? '\n\nIt is open: it will be closed for everyone using it, the app included.' : ''}'
            '${provider.isEncrypted(info.name) ? '\n\nIts stored encryption key is deleted too.' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: cs.error,
                foregroundColor: cs.onError,
              ),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) return;
    final ok = await provider.deleteDatabase(info.name);
    if (!context.mounted) return;
    if (ok) {
      showAdminMessage(context, 'Deleted "${info.name}".');
    } else {
      showAdminError(
        context,
        provider.lastError ?? 'Could not delete "${info.name}".',
      );
    }
  }
}

enum _CardAction { browse, insert, benchmark, seed, delete }

class _DatabaseCard extends StatelessWidget {
  const _DatabaseCard({
    required this.info,
    required this.isSelected,
    required this.onSelect,
    required this.onAction,
    required this.canSeed,
  });

  final DatabaseInfo info;
  final bool isSelected;
  final VoidCallback onSelect;
  final ValueChanged<_CardAction> onAction;
  final bool canSeed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = isSelected ? cs.onSecondaryContainer : cs.onSurface;
    final sub = isSelected ? cs.onSecondaryContainer : cs.onSurfaceVariant;
    final mode = info.mode;
    final details = [
      formatBytes(info.sizeBytes),
      if (info.tableCount != null) plural(info.tableCount!, 'table'),
      if (info.totalRows != null) plural(info.totalRows!, 'row'),
    ].join(' · ');
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      color: isSelected ? cs.secondaryContainer : null,
      child: ListTile(
        key: ValueKey('jdb-db-${info.name}'),
        onTap: onSelect,
        selected: isSelected,
        textColor: fg,
        iconColor: fg,
        selectedColor: fg,
        leading: CircleAvatar(
          backgroundColor: info.isOpen
              ? cs.primary
              : cs.surfaceContainerHighest,
          foregroundColor: info.isOpen ? cs.onPrimary : cs.onSurfaceVariant,
          child: Icon(
            info.isEncrypted ? Icons.lock_outline : Icons.storage,
            size: 20,
          ),
        ),
        title: Text(
          info.name,
          style: const TextStyle(fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AdminTag.neutral(
                context,
                info.isOpen ? 'Open' : 'Closed',
                icon: info.isOpen ? Icons.circle : Icons.circle_outlined,
              ),
              if (mode != null) AdminTag.mode(context, mode),
              if (info.isEncrypted) AdminTag.encrypted(context),
              if (!info.isPersisted)
                AdminTag.neutral(context, 'In memory', icon: Icons.memory),
              Text(details, style: TextStyle(fontSize: 12, color: sub)),
            ],
          ),
        ),
        trailing: PopupMenuButton<_CardAction>(
          tooltip: 'Actions for ${info.name}',
          onSelected: onAction,
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: _CardAction.browse,
              child: ListTile(
                leading: Icon(Icons.table_view_outlined),
                title: Text('Browse data'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: _CardAction.insert,
              child: ListTile(
                leading: Icon(Icons.add_box_outlined),
                title: Text('Insert row'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            const PopupMenuItem(
              value: _CardAction.benchmark,
              child: ListTile(
                leading: Icon(Icons.speed),
                title: Text('Benchmark'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            if (canSeed)
              const PopupMenuItem(
                value: _CardAction.seed,
                child: ListTile(
                  leading: Icon(Icons.auto_awesome_outlined),
                  title: Text('Seed sample data'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: _CardAction.delete,
              child: ListTile(
                leading: Icon(Icons.delete_outline, color: cs.error),
                title: Text('Delete', style: TextStyle(color: cs.error)),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CreateRequest {
  const _CreateRequest(this.name, this.mode, this.persist, this.encrypted);
  final String name;
  final DatabaseMode mode;
  final bool persist;
  final bool encrypted;
}

class _CreateDatabaseDialog extends StatefulWidget {
  const _CreateDatabaseDialog({required this.provider});

  final DatabaseProvider provider;

  @override
  State<_CreateDatabaseDialog> createState() => _CreateDatabaseDialogState();
}

class _CreateDatabaseDialogState extends State<_CreateDatabaseDialog> {
  final TextEditingController _name = TextEditingController();
  late DatabaseMode _mode = widget.provider.defaultMode;
  late bool _persist = widget.provider.persistEnabled;
  bool _encrypted = false;
  bool _showErrors = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String? get _nameError => widget.provider.checkNewDatabaseName(_name.text);

  void _submit() {
    final error = _nameError;
    if (error != null) {
      setState(() => _showErrors = true);
      return;
    }
    Navigator.pop(
      context,
      _CreateRequest(_name.text, _mode, _encrypted || _persist, _encrypted),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('New database'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const ValueKey('jdb-new-name'),
                controller: _name,
                autofocus: true,
                onChanged: (_) {
                  if (_showErrors) setState(() {});
                },
                onSubmitted: (_) => _submit(),
                decoration: InputDecoration(
                  labelText: 'Database name',
                  hintText: 'e.g. my_app',
                  helperText: 'Letters, digits, "_", "." and "-"',
                  errorText: _showErrors ? _nameError : null,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Mode',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
              ),
              RadioGroup<DatabaseMode>(
                groupValue: _mode,
                onChanged: (v) => setState(() => _mode = v ?? _mode),
                child: Column(
                  children: [
                    for (final mode in DatabaseMode.values)
                      RadioListTile<DatabaseMode>(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        value: mode,
                        title: Text(modeLabel(mode)),
                        subtitle: Text(modeDescription(mode)),
                      ),
                  ],
                ),
              ),
              const Divider(height: 20),
              SwitchListTile(
                key: const ValueKey('jdb-new-encrypted'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Encrypt'),
                subtitle: const Text(
                  'AES-256-GCM with a random key kept in this app\'s private '
                  'storage. Protects a copied file, not a device with full '
                  'access to the app\'s data.',
                ),
                value: _encrypted,
                onChanged: (v) => setState(() => _encrypted = v),
              ),
              SwitchListTile(
                key: const ValueKey('jdb-new-persist'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: const Text('Save to storage'),
                subtitle: Text(
                  _encrypted
                      ? 'Encrypted databases are always saved.'
                      : 'Off: kept in memory only; it is gone once this screen closes.',
                ),
                value: _encrypted || _persist,
                onChanged: _encrypted
                    ? null
                    : (v) => setState(() => _persist = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

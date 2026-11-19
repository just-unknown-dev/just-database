import 'package:flutter/material.dart';
import 'package:just_signals/just_signals.dart';

import '../../core/database_mode.dart';
import '../../core/just_database.dart';
import '../../core/version.dart';
import '../admin_utils.dart';
import '../database_provider.dart';
import '../widgets/admin_widgets.dart';

/// The repository of just_database.
const String _repository = 'https://github.com/just-unknown-dev/just-database';

/// Defaults for new databases, details of the selected one, "delete
/// everything", and what the engine can do.
class SettingsTab extends StatelessWidget {
  /// Creates the tab.
  const SettingsTab({super.key, required this.provider});

  /// The admin state.
  final DatabaseProvider provider;

  @override
  Widget build(BuildContext context) {
    return SignalBuilder<int>(
      signal: provider.revision,
      builder: (context, _, _) {
        final cs = Theme.of(context).colorScheme;
        final db = provider.currentDatabase;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            SectionCard(
              title: 'New databases',
              children: [
                SwitchListTile(
                  key: const ValueKey('jdb-setting-persist'),
                  title: const Text('Save new databases to storage'),
                  subtitle: const Text(
                    'The default when you create a database here (you can '
                    'change it per database). Databases that are already '
                    'saved always open from storage.',
                  ),
                  value: provider.persistEnabled,
                  onChanged: provider.setPersistEnabled,
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    'Default mode',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                RadioGroup<DatabaseMode>(
                  groupValue: provider.defaultMode,
                  onChanged: (v) {
                    if (v != null) provider.setDefaultMode(v);
                  },
                  child: Column(
                    children: [
                      for (final mode in DatabaseMode.values)
                        RadioListTile<DatabaseMode>(
                          value: mode,
                          title: Text(modeLabel(mode)),
                          subtitle: Text(modeDescription(mode)),
                          secondary: Icon(modeIcon(mode), color: cs.primary),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Saved databases that are not open yet are opened in the '
                    'default mode too.',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (db != null) ...[
              SectionCard(
                title: 'Selected database',
                children: [
                  ListTile(
                    leading: Icon(
                      provider.isEncrypted(db.name)
                          ? Icons.lock_outline
                          : Icons.storage,
                      color: cs.primary,
                    ),
                    title: Text(db.name),
                    subtitle: Text(
                      '${modeLabel(db.mode)} mode · '
                      '${db.persist ? 'saved' : 'in memory'}'
                      '${provider.isEncrypted(db.name) ? ' · encrypted' : ''}',
                    ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: _StatsGrid(db: db),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            SectionCard(
              title: 'Danger zone',
              titleColor: cs.error,
              children: [
                ListTile(
                  key: const ValueKey('jdb-clear-all'),
                  leading: Icon(Icons.delete_forever, color: cs.error),
                  title: Text(
                    'Delete all databases',
                    style: TextStyle(color: cs.error),
                  ),
                  subtitle: const Text(
                    'Closes and deletes every database of this app, open or '
                    'saved, and the stored keys of encrypted ones.',
                  ),
                  onTap: () => _confirmClearAll(context),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const SectionCard(
              title: 'Engine',
              children: [
                _InfoTile(
                  icon: Icons.table_rows_outlined,
                  title: 'SQL',
                  body:
                      'SQLite-style SQL: joins of every kind, subqueries, '
                      'UNION / INTERSECT / EXCEPT, aggregates, CASE and CAST, '
                      'upserts, views, triggers (INSTEAD OF on views), foreign '
                      'keys with actions and CHECK constraints. Bound '
                      'parameters: ?, ?NNN and :name.',
                ),
                _InfoTile(
                  icon: Icons.data_object,
                  title: 'Values',
                  body:
                      'NULL, INTEGER, REAL, TEXT and BLOB with SQLite type '
                      'affinity. BOOLEAN columns hold 1 or 0; DATETIME columns '
                      'hold ISO-8601 text (a Dart DateTime is stored as UTC). '
                      'Every table has a rowid; INTEGER PRIMARY KEY is an alias '
                      'of it.',
                ),
                _InfoTile(
                  icon: Icons.swap_horiz,
                  title: 'Transactions',
                  body:
                      'BEGIN / COMMIT / ROLLBACK and savepoints; '
                      'transaction() holds the database and rolls back when '
                      'its function throws. A failed statement changes '
                      'nothing.',
                ),
                _InfoTile(
                  icon: Icons.manage_search,
                  title: 'Indexes and spatial data',
                  body:
                      'CREATE [UNIQUE] INDEX, used for equality and IN '
                      'lookups and joins; index hints. CREATE SPATIAL INDEX '
                      'builds an R-tree for the ST_* functions.',
                ),
                _InfoTile(
                  icon: Icons.save_outlined,
                  title: 'Storage',
                  body:
                      'Saved after every committed change: a file in the '
                      'app\'s support directory, or IndexedDB on the web. '
                      'Export and import as SQL or JSON; versioned '
                      'migrations; a typed ORM; benchmarks.',
                ),
                _InfoTile(
                  icon: Icons.lock_outline,
                  title: 'Encryption',
                  body:
                      'AES-256-GCM with a 12-byte random nonce per save. The '
                      'key is derived from the passphrase with '
                      'PBKDF2-HMAC-SHA256 (600 000 iterations, a random salt '
                      'per file); a wrong key fails to open. Encrypted '
                      'databases created here use a random key from '
                      'SecureKeyManager.resolveAutoKey, kept by just_storage '
                      'in the app\'s private storage: it protects a copied '
                      'database file, not a device where someone can read '
                      'all of the app\'s data.',
                ),
              ],
            ),
            const SizedBox(height: 12),
            const SectionCard(
              title: 'About',
              children: [
                ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('just_database'),
                  subtitle: Text(
                    'Version $kJustDatabaseVersion · pure Dart SQL database for Flutter',
                  ),
                ),
                ListTile(
                  leading: Icon(Icons.gavel_outlined),
                  title: Text('License'),
                  subtitle: Text('BSD 3-Clause'),
                ),
                ListTile(
                  leading: Icon(Icons.hub_outlined),
                  title: Text('Repository'),
                  subtitle: SelectableText(_repository),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmClearAll(BuildContext context) async {
    final count = provider.databases.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: const Text('Delete all databases?'),
          content: Text(
            'This closes and deletes ${plural(count, 'database')} (open ones '
            'too, for everyone using them) and the stored keys of encrypted '
            'ones. It cannot be undone.',
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
              child: const Text('Delete all'),
            ),
          ],
        );
      },
    );
    if (confirmed != true || !context.mounted) return;
    final ok = await provider.clearAllDatabases();
    if (!context.mounted) return;
    if (ok) {
      showAdminMessage(context, 'Deleted every database.');
    } else {
      showAdminError(
        context,
        provider.lastError ?? 'Some databases could not be deleted.',
      );
    }
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.db});

  final JustDatabase db;

  @override
  Widget build(BuildContext context) {
    final tables = db.tableNames;
    final indexCount = tables.fold<int>(
      0,
      (n, t) => n + db.indexesForTable(t).length,
    );
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _StatTile(
          icon: Icons.table_chart_outlined,
          label: 'Tables',
          value: '${tables.length}',
        ),
        _StatTile(
          icon: Icons.view_agenda_outlined,
          label: 'Views',
          value: '${db.viewNames.length}',
        ),
        _StatTile(
          icon: Icons.format_list_numbered,
          label: 'Rows',
          value: '${db.totalRows}',
        ),
        _StatTile(
          icon: Icons.bolt,
          label: 'Triggers',
          value: '${db.triggerNames.length}',
        ),
        _StatTile(
          icon: Icons.manage_search,
          label: 'Indexes',
          value: '$indexCount',
        ),
        _StatTile(
          icon: Icons.memory,
          label: 'In memory',
          value: formatBytes(db.estimatedSizeBytes),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 96,
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: cs.primary),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: cs.onSurface,
            ),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: cs.primaryContainer,
        foregroundColor: cs.onPrimaryContainer,
        child: Icon(icon, size: 18),
      ),
      title: Text(
        title,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        body,
        style: TextStyle(
          fontSize: 12,
          height: 1.45,
          color: cs.onSurfaceVariant,
        ),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    );
  }
}

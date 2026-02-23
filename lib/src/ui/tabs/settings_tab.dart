import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_database/just_database.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DatabaseProvider>();
    final db = provider.currentDatabase;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // --- Storage section ---
        _SectionCard(
          title: 'Storage',
          children: [
            SwitchListTile(
              title: const Text('File Persistence (default)'),
              subtitle: const Text(
                'Default for new databases. Can be overridden per database when creating.',
              ),
              value: provider.persistEnabled,
              onChanged: provider.setPersistEnabled,
            ),
          ],
        ),
        const SizedBox(height: 12),

        // --- Default Mode section ---
        _SectionCard(
          title: 'Default Database Mode',
          children: [
            RadioGroup<DatabaseMode>(
              groupValue: provider.defaultMode,
              onChanged: (DatabaseMode? v) {
                if (v != null) provider.setDefaultMode(v);
              },
              child: Column(
                children: DatabaseMode.values
                    .map(
                      (mode) => RadioListTile<DatabaseMode>(
                        title: Text(_modeName(mode)),
                        subtitle: Text(_modeDescription(mode)),
                        secondary: Icon(
                          _modeIcon(mode),
                          color: _modeColor(mode),
                        ),
                        value: mode,
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // --- Current database info ---
        if (db != null) ...[
          _SectionCard(
            title: 'Current Database',
            children: [
              // Identity row
              ListTile(
                leading: const Icon(Icons.storage),
                title: Text(db.name),
                subtitle: Text(
                  '${_modeName(db.mode)} mode · '
                  '${db.persist ? "persisted" : "in-memory"}',
                ),
                trailing: _ModeBadge(mode: db.mode),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              // Stats grid
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: _DbStatsGrid(db: db),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],

        // --- Danger Zone section ---
        _SectionCard(
          title: 'Danger Zone',
          titleColor: Theme.of(context).colorScheme.error,
          children: [
            ListTile(
              leading: Icon(
                Icons.delete_forever,
                color: Theme.of(context).colorScheme.error,
              ),
              title: Text(
                'Clear All Databases',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              subtitle: const Text(
                'Permanently removes ALL databases from memory and disk',
              ),
              onTap: () => _confirmClearAll(context, provider),
            ),
          ],
        ),
        const SizedBox(height: 12),

        // --- Engine features overview ---
        _SectionCard(
          title: 'Engine Features',
          children: const [
            _FeatureTile(
              icon: Icons.table_rows_outlined,
              label: 'Core SQL',
              detail:
                  'SELECT · INSERT · UPDATE · DELETE\n'
                  'CREATE / DROP / ALTER TABLE · CREATE / DROP VIEW\n'
                  'INNER / LEFT / RIGHT JOIN · Subqueries\n'
                  'GROUP BY · HAVING · ORDER BY · LIMIT / OFFSET',
            ),
            _FeatureTile(
              icon: Icons.functions,
              label: 'Functions',
              detail:
                  'Aggregates: COUNT · SUM · AVG · MIN · MAX\n'
                  'String: UPPER · LOWER · LENGTH · SUBSTR · TRIM\n'
                  '         REPLACE · CONCAT\n'
                  'Math: ABS · ROUND\n'
                  'Null: COALESCE · IFNULL',
            ),
            _FeatureTile(
              icon: Icons.bolt,
              label: 'Triggers',
              detail:
                  'BEFORE / AFTER INSERT, UPDATE, DELETE\n'
                  'INSTEAD OF (on views)\n'
                  'NEW / OLD row references · WHEN clause\n'
                  'Multi-statement trigger bodies (BEGIN … END)',
            ),
            _FeatureTile(
              icon: Icons.pin_drop_outlined,
              label: 'Spatial (R-tree)',
              detail:
                  'Point · BoundingBox · Polygon geometry types\n'
                  'ST_MAKEPOINT · ST_X · ST_Y · ST_DISTANCE\n'
                  'ST_WITHIN · ST_INTERSECTS · ST_CONTAINS · ST_BBOX\n'
                  'CREATE SPATIAL INDEX · Quadratic-split R-tree',
            ),
            _FeatureTile(
              icon: Icons.manage_search,
              label: 'Indexes',
              detail:
                  'AUTO-INDEX on frequently queried columns\n'
                  'CREATE [UNIQUE] INDEX · CREATE SPATIAL INDEX\n'
                  'Composite indexes · DROP INDEX',
            ),
            _FeatureTile(
              icon: Icons.tips_and_updates_outlined,
              label: 'Query Hints',
              detail:
                  '/*+ INDEX(table idx) */  — force index use\n'
                  '/*+ NO_INDEX */          — skip all indexes\n'
                  '/*+ FULL_SCAN */         — table scan\n'
                  '/*+ FORCE_INDEX(…) */    — alias for INDEX\n'
                  'Inline and leading hint comment styles',
            ),
            _FeatureTile(
              icon: Icons.swap_horiz,
              label: 'Transactions',
              detail:
                  'BEGIN / COMMIT / ROLLBACK (WAL)\n'
                  'BEGIN DEFERRED / IMMEDIATE modes\n'
                  'SAVEPOINT · RELEASE SAVEPOINT\n'
                  'ROLLBACK TO SAVEPOINT\n'
                  'transaction() helper with auto-rollback',
            ),
            _FeatureTile(
              icon: Icons.backup_outlined,
              label: 'Backup & Restore',
              detail:
                  'exportSql() — full SQL dump (CREATE + INSERT)\n'
                  'importSql() — restore from SQL dump\n'
                  'exportJson() / importJson() — JSON snapshot\n'
                  'backupToFile / restoreFromFile helpers',
            ),
            _FeatureTile(
              icon: Icons.lock_outline,
              label: 'Secure Mode',
              detail:
                  'DatabaseMode.secure — AES-256-GCM encryption at rest\n'
                  'Passphrase → SHA-256 → 32-byte AES key (never stored)\n'
                  'Random 16-byte IV per save · GCM auth tag validates key\n'
                  'Wrong key on load raises StateError',
            ),
            _FeatureTile(
              icon: Icons.upgrade,
              label: 'Schema Migrations',
              detail:
                  'SqlMigration — up/down raw SQL scripts\n'
                  'CallbackMigration — Dart function callbacks\n'
                  'MigrationRunner — versioned apply / rollback\n'
                  'SHA-256 checksum validation · status() report\n'
                  'Persistent _migrations tracking table',
            ),
            _FeatureTile(
              icon: Icons.speed,
              label: 'Benchmarking',
              detail:
                  'DatabaseBenchmark — 8-operation standard suite\n'
                  'BenchmarkSuite — configurable custom suites\n'
                  'QueryStats — avg · min · max · p95 · p99 · ops/s\n'
                  'Warm-up iterations · seed-row control\n'
                  'runStandardBenchmark() / benchmarkQuery() on JustDatabase',
            ),
          ],
        ),
        const SizedBox(height: 12),

        // --- About section ---
        _SectionCard(
          title: 'About',
          children: const [
            ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('just_database'),
              subtitle: Text(
                'Pure Dart / Flutter SQL engine · v$kJustDatabaseVersion',
              ),
            ),
            ListTile(
              leading: Icon(Icons.code),
              title: Text('License'),
              subtitle: Text('BSD 3-Clause License'),
            ),
            ListTile(
              leading: Icon(Icons.hub_outlined),
              title: Text('Repository'),
              subtitle: Text('github.com/psbskb22/just-database'),
            ),
          ],
        ),
      ],
    );
  }

  void _confirmClearAll(BuildContext context, DatabaseProvider provider) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear All Databases?'),
        content: const Text(
          'This will permanently delete ALL databases from memory and disk. '
          'This action cannot be undone.',
        ),
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
              provider.clearAllDatabases();
            },
            child: const Text('Delete All'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Database stats grid
// ─────────────────────────────────────────────────────────────────────────────

class _DbStatsGrid extends StatelessWidget {
  final JustDatabase db;
  const _DbStatsGrid({required this.db});

  static String _fmt(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  @override
  Widget build(BuildContext context) {
    final triggerCount = db.triggerNames.length;
    final viewCount = db.viewNames.length;
    final tableCount = db.tableNames.length;
    final indexCount = db.tableNames.fold<int>(
      0,
      (sum, t) => sum + db.indexNamesForTable(t).length,
    );

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _StatTile(
          icon: Icons.table_chart_outlined,
          label: 'Tables',
          value: '$tableCount',
        ),
        _StatTile(
          icon: Icons.view_agenda_outlined,
          label: 'Views',
          value: '$viewCount',
        ),
        _StatTile(
          icon: Icons.format_list_numbered,
          label: 'Rows',
          value: '${db.totalRows}',
        ),
        _StatTile(icon: Icons.bolt, label: 'Triggers', value: '$triggerCount'),
        _StatTile(
          icon: Icons.manage_search,
          label: 'Indexes',
          value: '$indexCount',
        ),
        _StatTile(
          icon: Icons.sd_storage_outlined,
          label: 'Size',
          value: _fmt(db.estimatedSizeBytes),
        ),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: 90,
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
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              height: 1.2,
            ),
          ),
          Text(label, style: TextStyle(fontSize: 11, color: cs.outline)),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Mode badge
// ─────────────────────────────────────────────────────────────────────────────

class _ModeBadge extends StatelessWidget {
  final DatabaseMode mode;
  const _ModeBadge({required this.mode});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(_modeIcon(mode), size: 14, color: _modeColor(mode)),
      label: Text(_modeName(mode), style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      side: BorderSide(color: _modeColor(mode).withValues(alpha: 0.4)),
      backgroundColor: _modeColor(mode).withValues(alpha: 0.08),
      labelStyle: TextStyle(color: _modeColor(mode)),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Feature tile
// ─────────────────────────────────────────────────────────────────────────────

class _FeatureTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String detail;
  const _FeatureTile({
    required this.icon,
    required this.label,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListTile(
      leading: CircleAvatar(
        radius: 18,
        backgroundColor: cs.primaryContainer,
        child: Icon(icon, size: 18, color: cs.onPrimaryContainer),
      ),
      title: Text(
        label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        detail,
        style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant, height: 1.5),
      ),
      isThreeLine: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section card
// ─────────────────────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  final Color? titleColor;

  const _SectionCard({
    required this.title,
    required this.children,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 14,
                color: titleColor ?? Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
          const Divider(height: 1),
          ...children,
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

String _modeName(DatabaseMode mode) => switch (mode) {
  DatabaseMode.standard => 'Standard',
  DatabaseMode.readFast => 'Read Fast',
  DatabaseMode.writeFast => 'Write Fast',
  DatabaseMode.secure => 'Secure',
};

String _modeDescription(DatabaseMode mode) => switch (mode) {
  DatabaseMode.standard =>
    'Balanced: simple exclusive mutex for reads and writes',
  DatabaseMode.readFast =>
    'Read-optimized: many concurrent readers, exclusive writers',
  DatabaseMode.writeFast =>
    'Write-optimized: buffered writes with 100ms batch commits',
  DatabaseMode.secure =>
    'Encrypted at rest: AES-256-GCM encryption of the persisted file',
};

IconData _modeIcon(DatabaseMode mode) => switch (mode) {
  DatabaseMode.standard => Icons.balance,
  DatabaseMode.readFast => Icons.read_more,
  DatabaseMode.writeFast => Icons.edit_note,
  DatabaseMode.secure => Icons.lock_outline,
};

Color _modeColor(DatabaseMode mode) => switch (mode) {
  DatabaseMode.standard => Colors.blue,
  DatabaseMode.readFast => Colors.green,
  DatabaseMode.writeFast => Colors.orange,
  DatabaseMode.secure => Colors.purple,
};

import 'package:flutter/material.dart';
import 'package:just_signals/just_signals.dart';
import 'package:just_database/just_database.dart';

class DatabaseDetailPage extends StatelessWidget {
  final DatabaseProvider provider;
  final DatabaseInfo info;

  const DatabaseDetailPage({
    super.key,
    required this.provider,
    required this.info,
  });

  @override
  Widget build(BuildContext context) {
    return SignalBuilder<int>(
      signal: provider.revision,
      builder: (context, _, _) {
        final db = provider.currentDatabase;
        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.arrow_back_ios_outlined, size: 18),
            ),
            title: Row(
              children: [
                Text(info.name),
                const SizedBox(width: 8),
                _ModeBadge(mode: info.mode),
              ],
            ),
          ),
          body: db == null
              ? const _NoDatabaseView()
              : db.tableNames.isEmpty
              ? const _NoTablesView()
              : Column(
                  children: [
                    _SummaryBar(db: db),
                    Expanded(
                      child: ListView.builder(
                        itemCount: db.tableNames.length,
                        itemBuilder: (_, i) => _TableDataCard(
                          db: db,
                          tableName: db.tableNames[i],
                        ),
                      ),
                    ),
                  ],
                ),
        );
      },
    );
  }
}

class _SummaryBar extends StatelessWidget {
  final JustDatabase db;
  const _SummaryBar({required this.db});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tableCount = db.tableNames.length;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: cs.surfaceContainerLow,
      child: Wrap(
        spacing: 16,
        children: [
          _InfoChip(
            icon: Icons.table_chart_outlined,
            label: '$tableCount table${tableCount != 1 ? 's' : ''}',
          ),
          _InfoChip(icon: Icons.grid_on_outlined, label: '${db.totalRows} rows'),
          _InfoChip(
            icon: Icons.data_usage_outlined,
            label: _formatSize(db.estimatedSizeBytes),
          ),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class _InfoChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _InfoChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: cs.primary),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      ],
    );
  }
}

class _TableDataCard extends StatefulWidget {
  final JustDatabase db;
  final String tableName;

  const _TableDataCard({required this.db, required this.tableName});

  @override
  State<_TableDataCard> createState() => _TableDataCardState();
}

class _TableDataCardState extends State<_TableDataCard> {
  List<Map<String, dynamic>>? _rows;
  List<String>? _columns;
  bool _loading = false;
  String? _error;

  Future<void> _loadData() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.db.query(
        'SELECT * FROM ${widget.tableName} LIMIT 500',
      );
      if (!mounted) return;
      if (result.success) {
        setState(() {
          _columns = result.columns;
          _rows = result.rows;
          _loading = false;
        });
      } else {
        setState(() {
          _error = result.errorMessage ?? 'Query failed';
          _loading = false;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final schema = widget.db.getTableSchema(widget.tableName);
    final colCount = schema?.columns.length ?? 0;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ExpansionTile(
        leading: const Icon(Icons.table_chart_outlined),
        title: Text(
          widget.tableName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: colCount > 0
            ? Text('$colCount column${colCount != 1 ? 's' : ''}')
            : null,
        onExpansionChanged: (expanded) {
          if (expanded && _rows == null && !_loading) _loadData();
        },
        children: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            _ErrorBanner(error: _error!)
          else if (_rows != null)
            _TableDataView(
              tableName: widget.tableName,
              columns: _columns!,
              rows: _rows!,
            ),
        ],
      ),
    );
  }
}

class _TableDataView extends StatelessWidget {
  final String tableName;
  final List<String> columns;
  final List<Map<String, dynamic>> rows;

  const _TableDataView({
    required this.tableName,
    required this.columns,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (columns.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('No columns defined', style: TextStyle(color: cs.outline)),
      );
    }

    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Row(
          children: [
            Icon(Icons.inbox_outlined, size: 16, color: cs.outline),
            const SizedBox(width: 8),
            Text(
              'No rows in $tableName',
              style: TextStyle(color: cs.outline, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 1, color: cs.outlineVariant),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(cs.surfaceContainerLow),
            columnSpacing: 20,
            horizontalMargin: 16,
            columns: columns
                .map(
                  (col) => DataColumn(
                    label: Text(
                      col,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                )
                .toList(),
            rows: rows
                .map(
                  (row) => DataRow(
                    cells: columns
                        .map(
                          (col) => DataCell(
                            Text(
                              _formatValue(row[col]),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                        )
                        .toList(),
                  ),
                )
                .toList(),
          ),
        ),
        if (rows.length >= 500)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              'Showing first 500 rows',
              style: TextStyle(fontSize: 11, color: cs.outline),
            ),
          )
        else
          const SizedBox(height: 8),
      ],
    );
  }

  String _formatValue(dynamic value) {
    if (value == null) return 'NULL';
    final str = value.toString();
    if (str.length > 80) return '${str.substring(0, 77)}…';
    return str;
  }
}

class _ErrorBanner extends StatelessWidget {
  final String error;
  const _ErrorBanner({required this.error});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: cs.error, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: TextStyle(color: cs.error, fontSize: 13),
            ),
          ),
        ],
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

class _NoDatabaseView extends StatelessWidget {
  const _NoDatabaseView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.storage_outlined, size: 56, color: Colors.grey),
          SizedBox(height: 12),
          Text(
            'Database not available',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 4),
          Text(
            'The database could not be opened.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class _NoTablesView extends StatelessWidget {
  const _NoTablesView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.table_chart_outlined, size: 56, color: Colors.grey),
          SizedBox(height: 12),
          Text(
            'No tables yet',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 4),
          Text(
            'Use the Query tab to CREATE TABLE first.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

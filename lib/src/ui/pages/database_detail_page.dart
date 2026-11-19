import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/just_database.dart';
import '../../core/query_result.dart';
import '../../storage/schema.dart';
import '../../storage/values.dart';
import '../admin_utils.dart';
import '../database_provider.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/column_input.dart';
import '../widgets/result_grid.dart';
import 'insert_page.dart';

/// Browses the rows of a database's tables a page at a time, and edits and
/// deletes them.
///
/// Rows are addressed by their `rowid`, so tables without a primary key
/// (even with identical rows) are edited and deleted one row at a time.
class DatabaseDetailPage extends StatefulWidget {
  /// Creates the page for [database].
  const DatabaseDetailPage({
    super.key,
    required this.database,
    this.provider,
    this.initialTable,
    this.pageSize = 50,
  });

  /// The database to browse.
  final JustDatabase database;

  /// Told about changes, so lists elsewhere stay current.
  final DatabaseProvider? provider;

  /// The table shown first; the first table when null.
  final String? initialTable;

  /// Rows per page at first.
  final int pageSize;

  @override
  State<DatabaseDetailPage> createState() => _DatabaseDetailPageState();
}

class _DatabaseDetailPageState extends State<DatabaseDetailPage> {
  String? _table;
  late int _pageSize = widget.pageSize;
  int _offset = 0;
  int _total = 0;
  QueryResult? _page;
  String? _pageTable;
  bool _loading = false;
  String? _error;
  int _loadToken = 0;
  final Set<int> _selected = {};

  JustDatabase get _db => widget.database;

  @override
  void initState() {
    super.initState();
    final tables = _tablesOrEmpty();
    final initial = widget.initialTable;
    _table = initial != null && tables.contains(initial)
        ? initial
        : (tables.isEmpty ? null : tables.first);
    if (_table != null) unawaited(_load());
  }

  List<String> _tablesOrEmpty() => _db.isOpen ? _db.tableNames : const [];

  TableSchema? get _schema =>
      _table == null || !_db.isOpen ? null : _db.getTableSchema(_table!);

  /// The visible columns of the current table, in `SELECT *` order.
  List<ColumnDefinition> get _visibleColumns => [
    for (final c in _schema?.columns ?? const <ColumnDefinition>[])
      if (!c.hidden) c,
  ];

  Future<void> _load() async {
    final table = _table;
    if (table == null || !_db.isOpen) return;
    final token = ++_loadToken;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final total = _db.rowCount(table);
      var offset = _offset;
      if (offset >= total) {
        offset = total == 0 ? 0 : ((total - 1) ~/ _pageSize) * _pageSize;
      }
      // A table scan returns rows in rowid order, so pages are stable.
      final result = await _db.query(
        'SELECT rowid AS __rowid, * FROM ${quoteIdentifier(table)} LIMIT ? OFFSET ?',
        [_pageSize, offset],
      );
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        if (result.success) {
          _page = result;
          _pageTable = table;
          _total = total;
          _offset = offset;
          final onPage = {for (final r in result.values) r.first as int};
          _selected.retainAll(onPage);
        } else {
          _error = result.errorMessage ?? 'The rows could not be read.';
        }
      });
    } catch (e) {
      if (!mounted || token != _loadToken) return;
      setState(() {
        _loading = false;
        _error = describeError(e);
      });
    }
  }

  void _showTable(String table) {
    if (table == _table) return;
    setState(() {
      _table = table;
      _offset = 0;
      _page = null;
      _selected.clear();
    });
    unawaited(_load());
  }

  void _changed() {
    unawaited(widget.provider?.refreshDatabases());
    unawaited(_load());
  }

  // ---------------------------------------------------------------------------
  // Actions
  // ---------------------------------------------------------------------------

  Future<void> _edit(int rowid, List<Object?> values) async {
    final schema = _schema;
    final table = _table;
    if (schema == null || table == null) return;
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _EditRowDialog(
        db: _db,
        table: table,
        schema: schema,
        columns: _visibleColumns,
        rowid: rowid,
        values: values,
      ),
    );
    if (!mounted) return;
    if (changed == true) {
      showAdminMessage(context, 'Row saved.');
      _changed();
    }
  }

  Future<bool> _confirm(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          title: Text(title),
          content: Text(message),
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
    return result == true;
  }

  Future<void> _deleteRow(int rowid) async {
    final table = _table;
    if (table == null) return;
    if (!await _confirm(
      'Delete row?',
      'Row $rowid of "$table" is removed for good.',
    )) {
      return;
    }
    try {
      final r = await _db.execute(
        'DELETE FROM ${quoteIdentifier(table)} WHERE rowid = ?',
        [rowid],
      );
      if (!mounted) return;
      if (!r.success) {
        showAdminError(context, 'Delete failed: ${r.errorMessage}');
      } else if (r.affectedRows != 1) {
        showAdminError(
          context,
          'Expected to delete 1 row but ${r.affectedRows} were deleted. '
          'The row may have been changed elsewhere; the page was reloaded.',
        );
      } else {
        _selected.remove(rowid);
        showAdminMessage(context, 'Row deleted.');
      }
    } catch (e) {
      if (mounted) {
        showAdminError(context, 'Delete failed: ${describeError(e)}');
      }
    }
    if (mounted) _changed();
  }

  Future<void> _deleteSelected() async {
    final table = _table;
    if (table == null || _selected.isEmpty) return;
    final rowids = List.of(_selected);
    if (!await _confirm(
      'Delete ${plural(rowids.length, 'row')}?',
      'The selected ${plural(rowids.length, 'row')} of "$table" are removed for good.',
    )) {
      return;
    }
    try {
      await _db.transaction((tx) async {
        for (final rowid in rowids) {
          final r = await tx.execute(
            'DELETE FROM ${quoteIdentifier(table)} WHERE rowid = ?',
            [rowid],
          );
          if (r.affectedRows != 1) {
            throw StateError(
              'row $rowid no longer exists; nothing was deleted',
            );
          }
        }
      });
      if (!mounted) return;
      _selected.clear();
      showAdminMessage(context, 'Deleted ${plural(rowids.length, 'row')}.');
    } catch (e) {
      if (mounted) {
        showAdminError(context, 'Delete failed: ${describeError(e)}');
      }
    }
    if (mounted) _changed();
  }

  Future<void> _insert() async {
    await pushAdminPage<void>(
      context,
      InsertPage(
        database: _db,
        initialTable: _table,
        provider: widget.provider,
      ),
    );
    if (mounted) _changed();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final tables = _tablesOrEmpty();
    final table = _table != null && tables.contains(_table) ? _table : null;
    final Widget body;
    if (!_db.isOpen) {
      body = const EmptyState(
        icon: Icons.storage_outlined,
        title: 'Database closed',
        message: 'This database was closed (or deleted) by its owner.',
      );
    } else if (tables.isEmpty) {
      body = const EmptyState(
        icon: Icons.table_chart_outlined,
        title: 'No tables yet',
        message:
            'Create one on the Query tab, e.g. CREATE TABLE notes (body TEXT).',
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SummaryBar(db: _db),
          _TablePicker(tables: tables, selected: table, onSelected: _showTable),
          const Divider(height: 1),
          if (_selected.isNotEmpty)
            _SelectionBar(
              count: _selected.length,
              onDelete: _deleteSelected,
              onClear: () => setState(_selected.clear),
            ),
          if (_error != null)
            MessageBanner(
              message: _error!,
              tone: BannerTone.error,
              margin: const EdgeInsets.all(8),
            ),
          Expanded(child: _content(table)),
          if (table != null)
            PageBar(
              offset: _offset,
              pageSize: _pageSize,
              total: _total,
              busy: _loading,
              onOffsetChanged: (o) {
                setState(() => _offset = o);
                unawaited(_load());
              },
              onPageSizeChanged: (s) {
                setState(() {
                  _pageSize = s;
                  _offset = (_offset ~/ s) * s;
                });
                unawaited(_load());
              },
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(_db.name, overflow: TextOverflow.ellipsis),
        actions: [
          if (_db.isOpen && tables.isNotEmpty) ...[
            IconButton(
              tooltip: 'Insert row',
              icon: const Icon(Icons.add_box_outlined),
              onPressed: _insert,
            ),
            IconButton(
              tooltip: 'Reload',
              icon: const Icon(Icons.refresh),
              onPressed: _loading ? null : _load,
            ),
          ],
        ],
      ),
      body: body,
    );
  }

  Widget _content(String? table) {
    final page = _page;
    if (table == null) return const SizedBox.shrink();
    if (page == null || _pageTable != table) {
      return _loading
          ? const Center(child: CircularProgressIndicator())
          : const SizedBox.shrink();
    }
    if (page.isEmpty) {
      return EmptyState(
        icon: Icons.inbox_outlined,
        title: 'No rows in "$table"',
        action: OutlinedButton.icon(
          onPressed: _insert,
          icon: const Icon(Icons.add),
          label: const Text('Insert row'),
        ),
      );
    }
    final schema = _schema;
    final showRowid = schema?.rowidAlias == null;
    final dataColumns = page.columns.sublist(1);
    final rows = [for (final r in page.values) showRowid ? r : r.sublist(1)];
    final cs = Theme.of(context).colorScheme;
    return Stack(
      children: [
        ResultGrid(
          columns: [if (showRowid) 'rowid', ...dataColumns],
          rows: rows,
          leadingWidth: 132,
          leadingHeader: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Actions',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              ),
            ),
          ),
          isSelected: (i) => _selected.contains(page.values[i].first),
          leadingBuilder: (context, i) {
            final values = page.values[i];
            final rowid = values.first as int;
            return Row(
              children: [
                Checkbox(
                  value: _selected.contains(rowid),
                  semanticLabel: 'Select row $rowid',
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(rowid);
                    } else {
                      _selected.remove(rowid);
                    }
                  }),
                ),
                IconButton(
                  tooltip: 'Edit row',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.edit_outlined, size: 18, color: cs.primary),
                  onPressed: () => _edit(rowid, values.sublist(1)),
                ),
                IconButton(
                  tooltip: 'Delete row',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(Icons.delete_outline, size: 18, color: cs.error),
                  onPressed: () => _deleteRow(rowid),
                ),
              ],
            );
          },
        ),
        if (_loading)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 2),
          ),
      ],
    );
  }
}

class _SummaryBar extends StatelessWidget {
  const _SummaryBar({required this.db});

  final JustDatabase db;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget item(IconData icon, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: cs.primary),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant)),
      ],
    );
    return Container(
      color: cs.surfaceContainerLow,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 16,
        runSpacing: 4,
        children: [
          item(
            Icons.table_chart_outlined,
            plural(db.tableNames.length, 'table'),
          ),
          item(Icons.grid_on_outlined, plural(db.totalRows, 'row')),
          item(
            Icons.data_usage_outlined,
            '~${formatBytes(db.estimatedSizeBytes)} in memory',
          ),
          item(modeIcon(db.mode), '${modeLabel(db.mode)} mode'),
          item(
            db.persist ? Icons.save_outlined : Icons.memory,
            db.persist ? 'Saved' : 'In memory only',
          ),
        ],
      ),
    );
  }
}

class _TablePicker extends StatelessWidget {
  const _TablePicker({
    required this.tables,
    required this.selected,
    required this.onSelected,
  });

  final List<String> tables;
  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: tables.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => ChoiceChip(
          avatar: const Icon(Icons.table_chart_outlined, size: 16),
          label: Text(tables[i]),
          selected: tables[i] == selected,
          onSelected: (_) => onSelected(tables[i]),
        ),
      ),
    );
  }
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onDelete,
    required this.onClear,
  });

  final int count;
  final VoidCallback onDelete;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$count selected',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: cs.onSecondaryContainer,
              ),
            ),
          ),
          TextButton(onPressed: onClear, child: const Text('Clear')),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 16),
            label: const Text('Delete selected'),
            style: FilledButton.styleFrom(
              backgroundColor: cs.error,
              foregroundColor: cs.onError,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Edit dialog
// ---------------------------------------------------------------------------

class _EditRowDialog extends StatefulWidget {
  const _EditRowDialog({
    required this.db,
    required this.table,
    required this.schema,
    required this.columns,
    required this.rowid,
    required this.values,
  });

  final JustDatabase db;
  final String table;
  final TableSchema schema;
  final List<ColumnDefinition> columns;
  final int rowid;
  final List<Object?> values;

  @override
  State<_EditRowDialog> createState() => _EditRowDialogState();
}

class _EditRowDialogState extends State<_EditRowDialog> {
  final _formKey = GlobalKey<FormState>();
  late final List<ColumnInput> _inputs;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final aliasIndex = widget.schema.rowidAlias;
    final alias = aliasIndex == null
        ? null
        : widget.schema.columns[aliasIndex].name;
    _inputs = [
      for (var i = 0; i < widget.columns.length; i++)
        ColumnInput.forEdit(
          widget.columns[i],
          i < widget.values.length ? widget.values[i] : null,
          isRowidAlias: widget.columns[i].name == alias,
        ),
    ];
  }

  @override
  void dispose() {
    for (final input in _inputs) {
      input.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final changed = [
      for (final i in _inputs)
        if (i.isChanged) i,
    ];
    if (changed.isEmpty) {
      Navigator.pop(context, false);
      return;
    }
    final assignments = <String>[];
    final params = <Object?>[];
    for (final input in changed) {
      final parsed = input.parse();
      if (parsed.error != null) return; // the validator showed it
      assignments.add('${quoteIdentifier(input.column.name)} = ?');
      params.add(parsed.value);
    }
    params.add(widget.rowid);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final r = await widget.db.execute(
        'UPDATE ${quoteIdentifier(widget.table)} SET ${assignments.join(', ')} WHERE rowid = ?',
        params,
      );
      if (!mounted) return;
      if (!r.success) {
        setState(() {
          _saving = false;
          _error = r.errorMessage ?? 'The update failed.';
        });
      } else if (r.affectedRows != 1) {
        setState(() {
          _saving = false;
          _error =
              'Expected to update 1 row but ${r.affectedRows} changed. '
              'The row may have been deleted elsewhere; close this and reload.';
        });
      } else {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = describeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit row ${widget.rowid} of ${widget.table}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error != null)
                  MessageBanner(
                    message: _error!,
                    tone: BannerTone.error,
                    margin: const EdgeInsets.only(bottom: 12),
                  ),
                for (final input in _inputs) ColumnInputField(input: input),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_outlined, size: 16),
          label: const Text('Save'),
        ),
      ],
    );
  }
}

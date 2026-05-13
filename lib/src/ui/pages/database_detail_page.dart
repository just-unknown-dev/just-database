import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
              db: widget.db,
              onMutated: _loadData,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Row data view with edit / delete support
// ---------------------------------------------------------------------------

class _TableDataView extends StatefulWidget {
  final String tableName;
  final List<String> columns;
  final List<Map<String, dynamic>> rows;
  final JustDatabase db;
  final VoidCallback onMutated;

  const _TableDataView({
    required this.tableName,
    required this.columns,
    required this.rows,
    required this.db,
    required this.onMutated,
  });

  @override
  State<_TableDataView> createState() => _TableDataViewState();
}

class _TableDataViewState extends State<_TableDataView> {
  final Set<int> _selected = {};

  // Build a WHERE clause for the given row. Uses the PK if one exists,
  // otherwise falls back to matching every column value.
  String _whereFor(Map<String, dynamic> row) {
    final schema = widget.db.getTableSchema(widget.tableName);
    if (schema != null) {
      for (final col in schema.columns) {
        if (col.constraints.primaryKey && row.containsKey(col.name)) {
          return '${col.name} = ${_sqlLiteral(row[col.name])}';
        }
      }
    }
    return widget.columns.map((col) {
      final v = row[col];
      return v == null ? '$col IS NULL' : '$col = ${_sqlLiteral(v)}';
    }).join(' AND ');
  }

  String _sqlLiteral(dynamic v) {
    if (v == null) return 'NULL';
    if (v is int || v is double) return v.toString();
    if (v is bool) return v ? '1' : '0';
    return "'${v.toString().replaceAll("'", "''")}'";
  }

  Future<void> _deleteRow(Map<String, dynamic> row) async {
    final result = await widget.db.execute(
      'DELETE FROM ${widget.tableName} WHERE ${_whereFor(row)}',
    );
    if (!mounted) return;
    if (result.success) {
      widget.onMutated();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result.errorMessage ?? 'Delete failed'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> _deleteSelected() async {
    final toDelete = _selected.map((i) => widget.rows[i]).toList();
    String? firstError;
    for (final row in toDelete) {
      final result = await widget.db.execute(
        'DELETE FROM ${widget.tableName} WHERE ${_whereFor(row)}',
      );
      firstError ??= result.success ? null : (result.errorMessage ?? 'Delete failed');
    }
    if (!mounted) return;
    setState(() => _selected.clear());
    if (firstError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(firstError),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
    widget.onMutated();
  }

  Future<void> _confirmDeleteRow(Map<String, dynamic> row) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete row?'),
        content: const Text('This will permanently remove the row.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _deleteRow(row);
  }

  Future<void> _confirmDeleteSelected() async {
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete $count row${count != 1 ? 's' : ''}?'),
        content: Text(
          'Permanently remove $count selected row${count != 1 ? 's' : ''}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _deleteSelected();
  }

  Future<void> _openEditDialog(Map<String, dynamic> row) async {
    final schema = widget.db.getTableSchema(widget.tableName);
    if (schema == null) return;
    final updated = await showDialog<bool>(
      context: context,
      builder: (_) => _EditRowDialog(
        db: widget.db,
        tableName: widget.tableName,
        schema: schema,
        row: row,
        whereClause: _whereFor(row),
      ),
    );
    if (updated == true) widget.onMutated();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    if (widget.columns.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('No columns defined', style: TextStyle(color: cs.outline)),
      );
    }

    if (widget.rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Row(
          children: [
            Icon(Icons.inbox_outlined, size: 16, color: cs.outline),
            const SizedBox(width: 8),
            Text(
              'No rows in ${widget.tableName}',
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
        if (_selected.isNotEmpty)
          _SelectionBar(
            count: _selected.length,
            onDelete: _confirmDeleteSelected,
            onClear: () => setState(() => _selected.clear()),
          ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStatePropertyAll(cs.surfaceContainerLow),
            columnSpacing: 20,
            horizontalMargin: 16,
            columns: [
              const DataColumn(label: SizedBox(width: 72, child: Text(''))),
              ...widget.columns.map(
                (col) => DataColumn(
                  label: Text(
                    col,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
            rows: List.generate(widget.rows.length, (i) {
              final row = widget.rows[i];
              return DataRow(
                selected: _selected.contains(i),
                onSelectChanged: (v) => setState(() {
                  if (v == true) {
                    _selected.add(i);
                  } else {
                    _selected.remove(i);
                  }
                }),
                cells: [
                  DataCell(
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: 16,
                            icon: Icon(Icons.edit_outlined, color: cs.primary),
                            tooltip: 'Edit row',
                            onPressed: () => _openEditDialog(row),
                          ),
                        ),
                        SizedBox(
                          width: 32,
                          height: 32,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: 16,
                            icon: Icon(Icons.delete_outline, color: cs.error),
                            tooltip: 'Delete row',
                            onPressed: () => _confirmDeleteRow(row),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ...widget.columns.map(
                    (col) => DataCell(
                      Text(
                        _formatValue(row[col]),
                        style: TextStyle(
                          fontSize: 13,
                          color: row[col] == null ? cs.outline : null,
                          fontStyle:
                              row[col] == null ? FontStyle.italic : null,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
        if (widget.rows.length >= 500)
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

// ---------------------------------------------------------------------------
// Selection action bar
// ---------------------------------------------------------------------------

class _SelectionBar extends StatelessWidget {
  final int count;
  final VoidCallback onDelete;
  final VoidCallback onClear;

  const _SelectionBar({
    required this.count,
    required this.onDelete,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.primaryContainer.withValues(alpha: 0.4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Text(
            '$count selected',
            style: TextStyle(fontWeight: FontWeight.w600, color: cs.primary),
          ),
          const Spacer(),
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
// Edit row dialog
// ---------------------------------------------------------------------------

class _EditRowDialog extends StatefulWidget {
  final JustDatabase db;
  final String tableName;
  final TableSchema schema;
  final Map<String, dynamic> row;
  final String whereClause;

  const _EditRowDialog({
    required this.db,
    required this.tableName,
    required this.schema,
    required this.row,
    required this.whereClause,
  });

  @override
  State<_EditRowDialog> createState() => _EditRowDialogState();
}

class _EditRowDialogState extends State<_EditRowDialog> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _textControllers = {};
  final Map<String, bool> _boolValues = {};
  bool _submitting = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    for (final col in widget.schema.columns) {
      final val = widget.row[col.name];
      if (col.type == DataType.boolean) {
        _boolValues[col.name] = val == true || val == 1;
      } else {
        _textControllers[col.name] = TextEditingController(
          text: val?.toString() ?? '',
        );
      }
    }
  }

  @override
  void dispose() {
    for (final c in _textControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _submitting = true;
      _error = null;
    });

    final setParts = <String>[];
    for (final col in widget.schema.columns) {
      // Never modify auto-increment primary keys
      if (col.constraints.primaryKey && col.constraints.autoIncrement) continue;

      if (col.type == DataType.boolean) {
        final v = _boolValues[col.name] ?? false;
        setParts.add('${col.name} = ${v ? 1 : 0}');
      } else {
        final ctrl = _textControllers[col.name];
        final raw = ctrl?.text.trim() ?? '';
        if (raw.isEmpty) {
          if (col.constraints.notNull && !col.constraints.hasDefault) {
            setState(() {
              _error = '${col.name} is required';
              _submitting = false;
            });
            return;
          }
          setParts.add('${col.name} = NULL');
        } else if (col.type == DataType.integer || col.type == DataType.real) {
          setParts.add('${col.name} = $raw');
        } else {
          setParts.add("${col.name} = '${raw.replaceAll("'", "''")}'");
        }
      }
    }

    if (setParts.isEmpty) {
      setState(() {
        _error = 'No editable columns.';
        _submitting = false;
      });
      return;
    }

    final sql =
        'UPDATE ${widget.tableName} SET ${setParts.join(', ')} '
        'WHERE ${widget.whereClause}';
    final result = await widget.db.execute(sql);
    if (!mounted) return;

    if (result.success) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _error = result.errorMessage ?? 'Update failed';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit row — ${widget.tableName}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_error != null) _InlineError(error: _error!),
                ...widget.schema.columns.map(
                  (col) => _EditField(
                    col: col,
                    controller: _textControllers[col.name],
                    boolValue: _boolValues[col.name],
                    onBoolChanged: (v) =>
                        setState(() => _boolValues[col.name] = v),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _submitting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
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

// ---------------------------------------------------------------------------
// Edit field — one column in the edit dialog
// ---------------------------------------------------------------------------

class _EditField extends StatelessWidget {
  final ColumnDefinition col;
  final TextEditingController? controller;
  final bool? boolValue;
  final ValueChanged<bool> onBoolChanged;

  const _EditField({
    required this.col,
    required this.controller,
    required this.boolValue,
    required this.onBoolChanged,
  });

  bool get _isAutoInc =>
      col.constraints.primaryKey && col.constraints.autoIncrement;

  String get _typeLabel => switch (col.type) {
    DataType.integer => 'INTEGER',
    DataType.real => 'REAL',
    DataType.text => 'TEXT',
    DataType.boolean => 'BOOLEAN',
    DataType.datetime => 'DATETIME',
    DataType.blob => 'BLOB',
  };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isRequired =
        col.constraints.notNull &&
        !col.constraints.hasDefault &&
        !_isAutoInc;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (col.constraints.primaryKey) ...[
                Icon(Icons.key, size: 12, color: cs.primary),
                const SizedBox(width: 4),
              ],
              Text(
                col.name,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: cs.secondaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  _typeLabel,
                  style: TextStyle(
                    fontSize: 10,
                    color: cs.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_isAutoInc) ...[
                const SizedBox(width: 4),
                Text('auto', style: TextStyle(fontSize: 10, color: cs.outline)),
              ],
              if (isRequired) ...[
                const SizedBox(width: 4),
                Text(
                  'required',
                  style: TextStyle(fontSize: 10, color: cs.error),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          if (col.type == DataType.boolean)
            AbsorbPointer(
              absorbing: _isAutoInc,
              child: Opacity(
                opacity: _isAutoInc ? 0.5 : 1.0,
                child: _BoolToggle(
                  value: boolValue ?? false,
                  onChanged: onBoolChanged,
                ),
              ),
            )
          else
            _EditTextField(
              col: col,
              controller: controller!,
              readOnly: _isAutoInc,
            ),
        ],
      ),
    );
  }
}

class _BoolToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _BoolToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Switch(value: value, onChanged: onChanged),
        const SizedBox(width: 8),
        Text(
          value ? 'true' : 'false',
          style: TextStyle(
            color: value
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
          ),
        ),
      ],
    );
  }
}

class _EditTextField extends StatelessWidget {
  final ColumnDefinition col;
  final TextEditingController controller;
  final bool readOnly;

  const _EditTextField({
    required this.col,
    required this.controller,
    required this.readOnly,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isRequired =
        col.constraints.notNull && !col.constraints.hasDefault && !readOnly;

    TextInputType keyboardType = TextInputType.text;
    List<TextInputFormatter> formatters = [];
    String? hint;

    switch (col.type) {
      case DataType.integer:
        keyboardType = TextInputType.number;
        formatters = [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*'))];
      case DataType.real:
        keyboardType = const TextInputType.numberWithOptions(decimal: true);
        formatters = [
          FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*')),
        ];
      case DataType.datetime:
        hint = 'e.g. 2026-02-20T10:00:00';
      case DataType.blob:
        hint = 'hex bytes';
      default:
        break;
    }

    return TextFormField(
      controller: controller,
      readOnly: readOnly,
      keyboardType: keyboardType,
      inputFormatters: formatters,
      decoration: InputDecoration(
        hintText: hint,
        border: const OutlineInputBorder(),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        filled: readOnly,
        fillColor: readOnly ? cs.surfaceContainerHighest : null,
        suffixIcon: col.type == DataType.datetime && !readOnly
            ? IconButton(
                icon: const Icon(Icons.calendar_today, size: 18),
                tooltip: 'Pick date',
                onPressed: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: now,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) {
                    controller.text =
                        picked.toIso8601String().split('T').first;
                  }
                },
              )
            : null,
      ),
      validator: isRequired
          ? (v) =>
                (v == null || v.trim().isEmpty) ? '${col.name} is required' : null
          : null,
    );
  }
}

// ---------------------------------------------------------------------------
// Small shared widgets
// ---------------------------------------------------------------------------

class _InlineError extends StatelessWidget {
  final String error;
  const _InlineError({required this.error});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 16, color: cs.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              error,
              style: TextStyle(fontSize: 12, color: cs.onErrorContainer),
            ),
          ),
        ],
      ),
    );
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

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/just_database.dart';
import '../../storage/schema.dart';
import '../../storage/values.dart';
import '../admin_utils.dart';
import '../database_provider.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/column_input.dart';

/// A form that inserts a row into a table of [database].
///
/// Values are bound as parameters, so any text (quotes included) is stored
/// as typed. Each column can also be set to NULL, or left to its DEFAULT.
///
/// ```dart
/// Navigator.push(
///   context,
///   MaterialPageRoute(
///     builder: (_) => InsertPage(database: db, initialTable: 'users'),
///   ),
/// );
/// ```
class InsertPage extends StatefulWidget {
  /// Creates the page.
  const InsertPage({
    super.key,
    required this.database,
    this.initialTable,
    this.provider,
  });

  /// The database to insert into.
  final JustDatabase database;

  /// The table selected at first; none when null (or unknown).
  final String? initialTable;

  /// Told about inserts, so lists elsewhere stay current.
  final DatabaseProvider? provider;

  @override
  State<InsertPage> createState() => _InsertPageState();
}

class _InsertPageState extends State<InsertPage> {
  late String? _table = widget.initialTable;

  @override
  Widget build(BuildContext context) {
    final db = widget.database;
    final tables = db.isOpen ? db.tableNames : const <String>[];
    // A table dropped meanwhile simply stops being selected.
    final table = _table != null && tables.contains(_table) ? _table : null;
    final schema = table == null ? null : db.getTableSchema(table);
    final Widget body;
    if (!db.isOpen) {
      body = const EmptyState(
        icon: Icons.storage_outlined,
        title: 'Database closed',
        message: 'This database was closed (or deleted) by its owner.',
      );
    } else if (tables.isEmpty) {
      body = const EmptyState(
        icon: Icons.table_chart_outlined,
        title: 'No tables yet',
        message: 'Create one on the Query tab first.',
      );
    } else {
      body = ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _TableSelector(
            tables: tables,
            selected: table,
            onChanged: (t) => setState(() => _table = t),
          ),
          const SizedBox(height: 16),
          if (schema != null)
            _InsertForm(
              // A new form (and new controllers) per table; the old form's
              // controllers are disposed with it.
              key: ValueKey('insert-form-${schema.name}'),
              db: db,
              schema: schema,
              onInserted: () => unawaited(widget.provider?.refreshDatabases()),
            ),
        ],
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          table == null ? 'Insert row' : 'Insert into $table',
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: body,
    );
  }
}

class _TableSelector extends StatelessWidget {
  const _TableSelector({
    required this.tables,
    required this.selected,
    required this.onChanged,
  });

  final List<String> tables;
  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      key: ValueKey('jdb-insert-table-$selected'),
      initialValue: selected,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Table',
        border: OutlineInputBorder(),
        prefixIcon: Icon(Icons.table_chart_outlined),
      ),
      hint: const Text('Select a table'),
      items: [
        for (final t in tables)
          DropdownMenuItem(
            value: t,
            child: Text(t, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

class _InsertForm extends StatefulWidget {
  const _InsertForm({
    super.key,
    required this.db,
    required this.schema,
    required this.onInserted,
  });

  final JustDatabase db;
  final TableSchema schema;
  final VoidCallback onInserted;

  @override
  State<_InsertForm> createState() => _InsertFormState();
}

class _InsertFormState extends State<_InsertForm> {
  final _formKey = GlobalKey<FormState>();
  late final List<ColumnInput> _inputs;
  bool _submitting = false;
  String? _success;
  String? _error;

  @override
  void initState() {
    super.initState();
    final aliasIndex = widget.schema.rowidAlias;
    _inputs = [
      for (var i = 0; i < widget.schema.columns.length; i++)
        if (!widget.schema.columns[i].hidden)
          ColumnInput.forInsert(
            widget.schema.columns[i],
            isRowidAlias: i == aliasIndex,
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

  Future<void> _submit() async {
    setState(() {
      _success = null;
      _error = null;
    });
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final names = <String>[];
    final params = <Object?>[];
    for (final input in _inputs) {
      final parsed = input.parse();
      if (parsed.error != null) return; // the validator showed it
      if (parsed.omit) continue;
      names.add(quoteIdentifier(input.column.name));
      params.add(parsed.value);
    }
    final table = quoteIdentifier(widget.schema.name);
    final sql = names.isEmpty
        ? 'INSERT INTO $table DEFAULT VALUES'
        : 'INSERT INTO $table (${names.join(', ')}) '
              'VALUES (${List.filled(names.length, '?').join(', ')})';
    setState(() => _submitting = true);
    try {
      final r = await widget.db.execute(sql, params);
      if (!mounted) return;
      setState(() {
        _submitting = false;
        if (r.success) {
          final id = r.lastInsertRowId;
          _success =
              'Inserted a row into ${widget.schema.name}'
              '${id == null ? '' : ' (rowid $id)'}.';
          for (final input in _inputs) {
            input.reset();
          }
        } else {
          _error = r.errorMessage ?? 'The insert failed.';
        }
      });
      if (r.success) widget.onInserted();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = describeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Row values',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: cs.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Use the ⋮ menu of a column for NULL or its DEFAULT.',
                    style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  ),
                  const Divider(height: 20),
                  for (final input in _inputs) ColumnInputField(input: input),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (_success != null)
            MessageBanner(
              message: _success!,
              tone: BannerTone.success,
              margin: const EdgeInsets.only(bottom: 8),
            ),
          if (_error != null)
            MessageBanner(
              message: _error!,
              tone: BannerTone.error,
              margin: const EdgeInsets.only(bottom: 8),
            ),
          FilledButton.icon(
            key: const ValueKey('jdb-insert-submit'),
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.add_rounded),
            label: Text(_submitting ? 'Inserting…' : 'Insert row'),
          ),
        ],
      ),
    );
  }
}

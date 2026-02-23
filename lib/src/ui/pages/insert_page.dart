import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:just_database/just_database.dart';

/// A full-screen page that lets the user pick any table from the current
/// database and submit a new row via a dynamically-generated form.
///
/// Navigate to it with:
/// ```dart
/// Navigator.push(
///   context,
///   MaterialPageRoute(
///     builder: (_) => InsertPage(initialTable: 'users'),
///   ),
/// );
/// ```
class InsertPage extends StatefulWidget {
  /// Table to pre-select when the page opens. `null` shows the dropdown blank.
  final String? initialTable;

  const InsertPage({super.key, this.initialTable});

  @override
  State<InsertPage> createState() => _InsertPageState();
}

class _InsertPageState extends State<InsertPage> {
  String? _selectedTable;
  final _formKey = GlobalKey<FormState>();
  // fieldKey -> controller / value
  final Map<String, TextEditingController> _textControllers = {};
  final Map<String, bool> _boolValues = {};
  bool _submitting = false;
  String? _successMessage;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    if (widget.initialTable != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final db = context.read<DatabaseProvider>().currentDatabase;
        if (db != null) _selectTable(widget.initialTable, db);
      });
    }
  }

  @override
  void dispose() {
    for (final c in _textControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // -- table selection ------------------------------------------------------

  void _selectTable(String? name, JustDatabase db) {
    if (name == null) return;
    setState(() {
      _selectedTable = name;
      _successMessage = null;
      _errorMessage = null;
    });
    _rebuildControllers(db);
  }

  void _rebuildControllers(JustDatabase db) {
    for (final c in _textControllers.values) {
      c.dispose();
    }
    _textControllers.clear();
    _boolValues.clear();

    final schema = db.getTableSchema(_selectedTable!);
    if (schema == null) return;

    for (final col in schema.columns) {
      if (col.constraints.primaryKey && col.constraints.autoIncrement) {
        continue; // skip auto-inc PK
      }
      final colName = col.name;
      if (col.type == DataType.boolean) {
        _boolValues[colName] =
            (col.constraints.hasDefault && col.constraints.defaultValue != null)
            ? (col.constraints.defaultValue.toString().toLowerCase() ==
                      'true' ||
                  col.constraints.defaultValue.toString() == '1')
            : false;
      } else {
        final defaultText =
            col.constraints.hasDefault && col.constraints.defaultValue != null
            ? col.constraints.defaultValue.toString()
            : '';
        _textControllers[colName] = TextEditingController(text: defaultText);
      }
    }
    setState(() {});
  }

  //  submit

  Future<void> _submit(JustDatabase db) async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final schema = db.getTableSchema(_selectedTable!);
    if (schema == null) return;

    setState(() {
      _submitting = true;
      _successMessage = null;
      _errorMessage = null;
    });

    final colNames = <String>[];
    final colValues = <String>[];

    for (final col in schema.columns) {
      if (col.constraints.primaryKey && col.constraints.autoIncrement) continue;
      final name = col.name;

      if (col.type == DataType.boolean) {
        colNames.add(name);
        colValues.add(_boolValues[name] == true ? '1' : '0');
      } else {
        final ctrl = _textControllers[name];
        final raw = ctrl?.text.trim() ?? '';
        if (raw.isEmpty) {
          if (col.constraints.notNull && !col.constraints.hasDefault) {
            setState(() {
              _errorMessage = 'Column "$name" is required.';
              _submitting = false;
            });
            return;
          }
          continue; // let the DB use DEFAULT / NULL
        }
        colNames.add(name);
        if (col.type == DataType.integer || col.type == DataType.real) {
          colValues.add(raw);
        } else if (col.type == DataType.datetime) {
          colValues.add("'$raw'");
        } else {
          // TEXT / BLOB � escape single quotes
          colValues.add("'${raw.replaceAll("'", "''")}'");
        }
      }
    }

    final sql =
        'INSERT INTO $_selectedTable (${colNames.join(', ')}) '
        'VALUES (${colValues.join(', ')})';

    final result = await db.execute(sql);
    if (!mounted) return;

    setState(() {
      _submitting = false;
      if (result.success) {
        _successMessage =
            ' Row inserted into $_selectedTable '
            '(${result.affectedRows} affected)';
        // Clear text fields (booleans keep their last value)
        for (final c in _textControllers.values) {
          c.clear();
        }
      } else {
        _errorMessage = result.errorMessage ?? 'Unknown error';
      }
    });
  }

  //  build

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DatabaseProvider>();
    final db = provider.currentDatabase;

    // Ensure the selected table still exists after DDL changes
    if (db != null &&
        _selectedTable != null &&
        !db.tableNames.contains(_selectedTable)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() => _selectedTable = null);
      });
    }

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          icon: Icon(Icons.arrow_back_ios_outlined, size: 18),
        ),
        title: Text(
          _selectedTable != null ? 'Insert into $_selectedTable' : 'Insert Row',
        ),
      ),
      body: db == null
          ? const _NoDatabaseView()
          : db.tableNames.isEmpty
          ? const _NoTablesView()
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // -- Table selector ----------------------------------------
                  _TableSelector(
                    tables: db.tableNames,
                    selected: _selectedTable,
                    onChanged: (t) => _selectTable(t, db),
                  ),

                  if (_selectedTable != null) ...[
                    const SizedBox(height: 16),

                    // -- Dynamic form --------------------------------------
                    _RowForm(
                      formKey: _formKey,
                      schema: db.getTableSchema(_selectedTable!),
                      textControllers: _textControllers,
                      boolValues: _boolValues,
                      onBoolChanged: (col, val) =>
                          setState(() => _boolValues[col] = val),
                    ),

                    const SizedBox(height: 16),

                    // -- Feedback banners ----------------------------------
                    if (_successMessage != null)
                      _Banner(
                        message: _successMessage!,
                        color: Colors.green,
                        icon: Icons.check_circle_outline,
                      ),
                    if (_errorMessage != null)
                      _Banner(
                        message: _errorMessage!,
                        color: Colors.red,
                        icon: Icons.error_outline,
                      ),

                    const SizedBox(height: 8),

                    // -- Submit button -------------------------------------
                    FilledButton.icon(
                      onPressed: _submitting ? null : () => _submit(db),
                      icon: _submitting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.add_rounded),
                      label: Text(_submitting ? 'Inserting�' : 'Insert Row'),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

//
// Table selector card
//

class _TableSelector extends StatelessWidget {
  final List<String> tables;
  final String? selected;
  final ValueChanged<String?> onChanged;

  const _TableSelector({
    required this.tables,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Target Table',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: ValueKey(selected),
              initialValue: selected,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                hintText: 'Select a table',
              ),
              items: tables
                  .map(
                    (t) => DropdownMenuItem(
                      value: t,
                      child: Row(
                        children: [
                          const Icon(Icons.table_chart_outlined, size: 16),
                          const SizedBox(width: 8),
                          Text(t),
                        ],
                      ),
                    ),
                  )
                  .toList(),
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

//
// Dynamic row form
//

class _RowForm extends StatelessWidget {
  final GlobalKey<FormState> formKey;
  final TableSchema? schema;
  final Map<String, TextEditingController> textControllers;
  final Map<String, bool> boolValues;
  final void Function(String col, bool val) onBoolChanged;

  const _RowForm({
    required this.formKey,
    required this.schema,
    required this.textControllers,
    required this.boolValues,
    required this.onBoolChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (schema == null) return const SizedBox.shrink();

    final editableCols = schema!.columns
        .where(
          (c) => !(c.constraints.primaryKey && c.constraints.autoIncrement),
        )
        .toList();

    if (editableCols.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('This table has no editable columns (id is auto-set).'),
        ),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Row Data',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const Divider(height: 20),
              ...editableCols.map(
                (col) => _ColumnField(
                  col: col,
                  controller: textControllers[col.name],
                  boolValue: boolValues[col.name],
                  onBoolChanged: (v) => onBoolChanged(col.name, v),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

//
// Single column field
//

class _ColumnField extends StatelessWidget {
  final ColumnDefinition col;
  final TextEditingController? controller;
  final bool? boolValue;
  final ValueChanged<bool> onBoolChanged;

  const _ColumnField({
    required this.col,
    required this.controller,
    required this.boolValue,
    required this.onBoolChanged,
  });

  String get _typeLabel {
    return switch (col.type) {
      DataType.integer => 'INTEGER',
      DataType.real => 'REAL',
      DataType.text => 'TEXT',
      DataType.boolean => 'BOOLEAN',
      DataType.datetime => 'DATETIME',
      DataType.blob => 'BLOB',
    };
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isRequired = col.constraints.notNull && !col.constraints.hasDefault;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Label row
          Row(
            children: [
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
              if (isRequired) ...[
                const SizedBox(width: 4),
                Text(
                  'required',
                  style: TextStyle(fontSize: 10, color: cs.error),
                ),
              ],
              if (col.constraints.unique) ...[
                const SizedBox(width: 4),
                Text(
                  'unique',
                  style: TextStyle(fontSize: 10, color: cs.tertiary),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),

          // Input widget per type
          if (col.type == DataType.boolean)
            _BoolField(value: boolValue ?? false, onChanged: onBoolChanged)
          else
            _TextTypeField(col: col, controller: controller!),
        ],
      ),
    );
  }
}

class _BoolField extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _BoolField({required this.value, required this.onChanged});

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

class _TextTypeField extends StatelessWidget {
  final ColumnDefinition col;
  final TextEditingController controller;
  const _TextTypeField({required this.col, required this.controller});

  @override
  Widget build(BuildContext context) {
    final isRequired = col.constraints.notNull && !col.constraints.hasDefault;

    TextInputType keyboardType = TextInputType.text;
    List<TextInputFormatter> formatters = [];
    String? hint;

    switch (col.type) {
      case DataType.integer:
        keyboardType = TextInputType.number;
        formatters = [FilteringTextInputFormatter.allow(RegExp(r'^-?\d*'))];
        hint = 'e.g. 42';
      case DataType.real:
        keyboardType = const TextInputType.numberWithOptions(decimal: true);
        formatters = [
          FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*')),
        ];
        hint = 'e.g. 3.14';
      case DataType.datetime:
        hint = 'e.g. 2026-02-20T10:00:00';
      case DataType.blob:
        hint = 'hex bytes, e.g. 48656c6c6f';
      default:
        hint = col.constraints.hasDefault
            ? 'default: ${col.constraints.defaultValue}'
            : null;
    }

    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: formatters,
      decoration: InputDecoration(
        hintText: hint,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        suffixIcon: col.type == DataType.datetime
            ? IconButton(
                icon: const Icon(Icons.calendar_today, size: 18),
                tooltip: 'Pick date/time',
                onPressed: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: now,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) {
                    controller.text = picked.toIso8601String().split('T').first;
                  }
                },
              )
            : null,
      ),
      validator: isRequired
          ? (v) => (v == null || v.trim().isEmpty)
                ? '${col.name} is required'
                : null
          : null,
    );
  }
}

//
// Feedback banner
//

class _Banner extends StatelessWidget {
  final String message;
  final Color color;
  final IconData icon;

  const _Banner({
    required this.message,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message, style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}

//
// Empty states
//

class _NoDatabaseView extends StatelessWidget {
  const _NoDatabaseView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.add_box_outlined, size: 56, color: Colors.grey),
          SizedBox(height: 12),
          Text(
            'No database selected',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 4),
          Text(
            'Open a database from the Databases tab.',
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

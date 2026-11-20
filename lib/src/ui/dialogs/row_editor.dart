/// The form that inserts or edits one row: a side panel, a dialog, or a
/// full-screen page on phones.
@internal
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../../storage/schema.dart';
import '../admin_style.dart';
import '../admin_utils.dart';
import '../sql_text.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/column_input.dart';
import '../backend/admin_backend.dart';

/// Shows the row editor for [table] in a dialog (full screen on phones):
/// an insert when [rowid] is null, else an edit of the row whose visible
/// column values are [values]. Returns whether a row was saved.
@internal
Future<bool> showRowEditorDialog(
  BuildContext context,
  AdminDatabase db,
  String table, {
  int? rowid,
  List<Object?>? values,
}) async {
  final wide = AdminStyle.isWide(context);
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      final editor = RowEditor(
        db: db,
        table: table,
        rowid: rowid,
        values: values,
        onDone: (changed) => Navigator.pop(context, changed),
      );
      if (wide) {
        return Dialog(
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: MediaQuery.sizeOf(context).height * 0.85,
            ),
            child: editor,
          ),
        );
      }
      return Dialog.fullscreen(child: SafeArea(child: editor));
    },
  );
  return result == true;
}

/// Inserts a row into [table] (when [rowid] is null) or edits the row
/// [rowid], whose visible column values are [values].
@internal
class RowEditor extends StatefulWidget {
  const RowEditor({
    super.key,
    required this.db,
    required this.table,
    this.rowid,
    this.values,
    required this.onDone,
  });

  final AdminDatabase db;
  final String table;
  final int? rowid;
  final List<Object?>? values;

  /// Called when the editor closes: whether something was saved.
  final void Function(bool changed) onDone;

  @override
  State<RowEditor> createState() => _RowEditorState();
}

class _RowEditorState extends State<RowEditor> {
  final _formKey = GlobalKey<FormState>();
  late final TableSchema? _schema = widget.db.getTableSchema(widget.table);
  late final List<ColumnInput> _inputs;
  bool _working = false;
  bool _savedAny = false;
  String? _error;
  String? _success;

  bool get _isInsert => widget.rowid == null;

  @override
  void initState() {
    super.initState();
    final schema = _schema;
    if (schema == null) {
      _inputs = const [];
      return;
    }
    final alias = schema.rowidAlias;
    final visible = [
      for (var i = 0; i < schema.columns.length; i++)
        if (!schema.columns[i].hidden) i,
    ];
    _inputs = [
      for (var k = 0; k < visible.length; k++)
        _isInsert
            ? ColumnInput.forInsert(
                schema.columns[visible[k]],
                isRowidAlias: visible[k] == alias,
              )
            : ColumnInput.forEdit(
                schema.columns[visible[k]],
                k < (widget.values?.length ?? 0) ? widget.values![k] : null,
                isRowidAlias: visible[k] == alias,
              ),
    ];
  }

  @override
  void dispose() {
    for (final i in _inputs) {
      i.dispose();
    }
    super.dispose();
  }

  Future<void> _save({bool another = false}) async {
    setState(() {
      _error = null;
      _success = null;
    });
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final table = sqlName(widget.table);
    final String sql;
    final params = <Object?>[];
    if (_isInsert) {
      final names = <String>[];
      for (final input in _inputs) {
        final parsed = input.parse();
        if (parsed.error != null) return;
        if (parsed.omit) continue;
        names.add(sqlName(input.column.name));
        params.add(parsed.value);
      }
      sql = names.isEmpty
          ? 'INSERT INTO $table DEFAULT VALUES'
          : 'INSERT INTO $table (${names.join(', ')}) '
                'VALUES (${List.filled(names.length, '?').join(', ')})';
    } else {
      final sets = <String>[];
      for (final input in _inputs) {
        if (!input.isChanged) continue;
        final parsed = input.parse();
        if (parsed.error != null) return;
        sets.add('${sqlName(input.column.name)} = ?');
        params.add(parsed.value);
      }
      if (sets.isEmpty) {
        widget.onDone(false);
        return;
      }
      sql = 'UPDATE $table SET ${sets.join(', ')} WHERE rowid = ?';
      params.add(widget.rowid);
    }
    setState(() => _working = true);
    try {
      final r = await widget.db.execute(sql, params);
      if (!mounted) return;
      if (!r.success) {
        setState(() {
          _working = false;
          _error = r.errorMessage ?? 'The statement failed.';
        });
        return;
      }
      if (!_isInsert && r.affectedRows != 1) {
        setState(() {
          _working = false;
          _error =
              'The row was not found: it may have been deleted elsewhere. '
              'Close this and reload.';
        });
        return;
      }
      _savedAny = true;
      if (another) {
        final id = r.lastInsertRowId;
        setState(() {
          _working = false;
          _success = 'Inserted a row${id == null ? '' : ' (rowid $id)'}.';
          for (final i in _inputs) {
            i.reset();
          }
        });
      } else {
        widget.onDone(true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = describeError(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final title = _isInsert
        ? 'New row in ${widget.table}'
        : 'Row ${widget.rowid} of ${widget.table}';
    return Material(
      color: cs.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => widget.onDone(_savedAny),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _schema == null
                ? const EmptyState(
                    icon: Icons.table_chart_outlined,
                    title: 'The table no longer exists',
                  )
                : Form(
                    key: _formKey,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                      children: [
                        if (_isInsert)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              "Each field's menu sets NULL or the column's "
                              'DEFAULT.',
                              style: AdminStyle.caption(context),
                            ),
                          ),
                        if (_error != null)
                          MessageBanner(
                            message: _error!,
                            tone: BannerTone.error,
                            margin: const EdgeInsets.only(bottom: 12),
                          ),
                        if (_success != null)
                          MessageBanner(
                            message: _success!,
                            tone: BannerTone.success,
                            margin: const EdgeInsets.only(bottom: 12),
                          ),
                        for (final input in _inputs)
                          ColumnInputField(input: input),
                      ],
                    ),
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton(
                  onPressed: _working ? null : () => widget.onDone(_savedAny),
                  child: Text(_savedAny ? 'Done' : 'Cancel'),
                ),
                if (_isInsert)
                  OutlinedButton(
                    key: const ValueKey('jdb-row-insert-another'),
                    onPressed: _working || _schema == null
                        ? null
                        : () => _save(another: true),
                    child: const Text('Insert and add another'),
                  ),
                FilledButton(
                  key: const ValueKey('jdb-row-save'),
                  onPressed: _working || _schema == null ? null : _save,
                  child: Text(
                    _working
                        ? 'Saving…'
                        : (_isInsert ? 'Insert row' : 'Save changes'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

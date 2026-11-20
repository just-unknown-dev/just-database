/// Browses and edits the rows of a table (or browses a view).
@internal
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/database_change.dart';
import '../../core/query_result.dart';
import '../../storage/schema.dart';
import '../admin_preferences.dart';
import '../admin_style.dart';
import '../admin_utils.dart';
import '../dialogs/backup_dialogs.dart';
import '../dialogs/row_editor.dart';
import '../dialogs/value_inspector.dart';
import '../just_database_admin_controller.dart';
import '../sql_text.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/column_input.dart';
import '../widgets/result_grid.dart';
import '../backend/admin_backend.dart';

/// What the data pane of one table keeps between visits.
@internal
final class DataViewState {
  String filter = '';
  bool whereMode = false;
  String? sortColumn;
  bool sortAscending = true;
  int offset = 0;
  final Map<String, double> widths = {};
}

/// `%`, `_` and `\` escaped for `LIKE … ESCAPE '\'`.
@internal
String escapeLike(String text) =>
    text.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

/// The rows of a table or view, a page at a time: filter, sort, resize,
/// select, edit in place, inspect, insert, delete and export.
@internal
class DataPane extends StatefulWidget {
  const DataPane({
    super.key,
    required this.controller,
    required this.database,
    required this.object,
    required this.isView,
  });

  final JustDatabaseAdminController controller;
  final AdminDatabase database;
  final String object;
  final bool isView;

  @override
  State<DataPane> createState() => _DataPaneState();
}

class _DataPaneState extends State<DataPane> {
  late DataViewState _view;
  final _filter = TextEditingController();
  final _filterFocus = FocusNode();
  late final FocusNode _gridFocus = FocusNode(onKeyEvent: _onGridKey);
  final _editText = TextEditingController();
  late final FocusNode _editFocus = FocusNode(onKeyEvent: _onEditKey);

  QueryResult? _page;
  int _total = 0;
  bool _loading = false;
  String? _error;
  int _token = 0;
  List<String>? _viewColumns;
  final Set<int> _selected = {};
  GridCell? _cell;
  GridCell? _editing;
  bool _reloadPending = false;
  bool _panelOpen = false;
  int? _panelRowid;
  List<Object?>? _panelValues;
  int _panelKey = 0;
  StreamSubscription<DatabaseChange>? _sub;
  Timer? _reloadTimer;

  AdminDatabase get _db => widget.database;
  String get _table => widget.object;
  bool get _isView => widget.isView;
  bool get _writable => !widget.controller.readOnly && !_isView;
  int get _pageSize => widget.controller.pageSize;
  TableSchema? get _schema => _isView ? null : _db.getTableSchema(_table);

  @override
  void initState() {
    super.initState();
    _view = widget.controller.paneState(
      '${_db.name.toLowerCase()}/${_table.toLowerCase()}/data',
      DataViewState.new,
    );
    _filter.text = _view.filter;
    _editFocus.addListener(() {
      if (!_editFocus.hasFocus && _editing != null) unawaited(_commitEdit());
    });
    _sub = _db.changes.listen((c) {
      if (_isView || c.schemaChanged || c.touches(_table)) _scheduleReload();
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    _reloadTimer?.cancel();
    _filter.dispose();
    _filterFocus.dispose();
    _gridFocus.dispose();
    _editText.dispose();
    _editFocus.dispose();
    super.dispose();
  }

  void _scheduleReload() {
    if (_editing != null) {
      _reloadPending = true;
      return;
    }
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 150), () {
      _reloadTimer = null;
      unawaited(_load());
    });
  }

  // ---------------------------------------------------------------------------
  // Loading
  // ---------------------------------------------------------------------------

  List<String> get _dataColumns =>
      _isView ? (_viewColumns ?? const []) : (_schema?.columnNames ?? const []);

  String _fromWhere(Map<String, Object?> params) {
    var sql = ' FROM ${sqlName(_table)}';
    final f = _view.filter.trim();
    if (f.isEmpty) return sql;
    if (_view.whereMode) return '$sql WHERE ($f)';
    final cols = _dataColumns;
    if (cols.isEmpty) return sql;
    params['q'] = '%${escapeLike(f)}%';
    final tests = [
      for (final c in cols) "CAST(${sqlName(c)} AS TEXT) LIKE :q ESCAPE '\\'",
    ];
    return '$sql WHERE (${tests.join(' OR ')})';
  }

  String _orderBy() {
    final col = _view.sortColumn;
    if (col == null) return '';
    final dir = _view.sortAscending ? 'ASC' : 'DESC';
    if (!_isView && col == 'rowid') return ' ORDER BY rowid $dir';
    return ' ORDER BY ${sqlName(col)} $dir${_isView ? '' : ', rowid'}';
  }

  Future<void> _load() async {
    if (!_db.isOpen || (!_isView && _schema == null)) return;
    final token = ++_token;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (_isView && _viewColumns == null) {
        final shape = await _db.query(
          'SELECT * FROM ${sqlName(_table)} LIMIT 0',
        );
        if (shape.success) _viewColumns = shape.columns;
      }
      final params = <String, Object?>{};
      final fw = _fromWhere(params);
      final count = await _db.query(
        'SELECT COUNT(*)$fw',
        params.isEmpty ? null : params,
      );
      if (!mounted || token != _token) return;
      if (!count.success) {
        setState(() {
          _loading = false;
          _error = count.errorMessage;
          _page = null;
          _total = 0;
        });
        return;
      }
      final total = count.scalar as int? ?? 0;
      var offset = _view.offset;
      if (offset >= total) {
        offset = total == 0 ? 0 : ((total - 1) ~/ _pageSize) * _pageSize;
      }
      final select = _isView ? 'SELECT *' : 'SELECT rowid AS __rowid, *';
      final page = await _db.query(
        '$select$fw${_orderBy()} LIMIT :limit OFFSET :offset',
        {...params, 'limit': _pageSize, 'offset': offset},
      );
      if (!mounted || token != _token) return;
      setState(() {
        _loading = false;
        if (page.success) {
          _page = page;
          _total = total;
          _view.offset = offset;
          if (!_isView) {
            final onPage = {for (final r in page.values) r.first as int};
            _selected.retainAll(onPage);
          }
          final cell = _cell;
          if (cell != null && cell.row >= page.values.length) _cell = null;
        } else {
          _error = page.errorMessage;
        }
      });
    } catch (e) {
      if (!mounted || token != _token) return;
      setState(() {
        _loading = false;
        _error = describeError(e);
      });
    }
  }

  void _applyFilter() {
    _view
      ..filter = _filter.text
      ..offset = 0;
    unawaited(_load());
  }

  // ---------------------------------------------------------------------------
  // Columns of the grid
  // ---------------------------------------------------------------------------

  bool get _showRowid => !_isView && _schema?.rowidAlias == null;

  List<String> _gridColumns(QueryResult page) => _isView
      ? page.columns
      : [if (_showRowid) 'rowid', ...page.columns.sublist(1)];

  List<List<Object?>> _gridRows(QueryResult page) => _isView || _showRowid
      ? page.values
      : [for (final r in page.values) r.sublist(1)];

  /// The index in the stored (visible) columns of grid column [c], or null
  /// for the rowid column.
  int? _dataIndex(int c) {
    if (_isView) return c;
    if (_showRowid) return c == 0 ? null : c - 1;
    return c;
  }

  int _rowidAt(int row) => _page!.values[row].first as int;

  /// The visible values of [row] (no rowid).
  List<Object?> _rowValues(int row) {
    final r = _page!.values[row];
    return _isView ? r : r.sublist(1);
  }

  ColumnDefinition? _columnAt(int c) {
    final i = _dataIndex(c);
    final schema = _schema;
    if (i == null || schema == null) return null;
    final visible = [
      for (final col in schema.columns)
        if (!col.hidden) col,
    ];
    return i < visible.length ? visible[i] : null;
  }

  Object? _valueAt(GridCell cell) {
    final rows = _gridRows(_page!);
    final r = rows[cell.row];
    return cell.column < r.length ? r[cell.column] : null;
  }

  // ---------------------------------------------------------------------------
  // Editing
  // ---------------------------------------------------------------------------

  bool _isAlias(ColumnDefinition column) {
    final schema = _schema;
    final alias = schema?.rowidAlias;
    return alias != null && identical(schema!.columns[alias], column);
  }

  Future<void> _editOrInspect(GridCell cell) async {
    final value = _valueAt(cell);
    final column = _columnAt(cell.column);
    final name = _gridColumns(_page!)[cell.column];
    if (!_writable || column == null) {
      await showValueInspector(context, title: name, value: value);
      return;
    }
    final kind = ColumnInput.kindOf(column, value);
    if (kind == ColumnInputKind.boolean) {
      await _update(cell.row, column, value == 1 ? 0 : 1);
      return;
    }
    final long =
        value is String && (value.length > 120 || value.contains('\n'));
    if (kind == ColumnInputKind.blob || long) {
      await _inspect(cell);
      return;
    }
    setState(() {
      _editing = cell;
      _cell = cell;
      _editText.text = editableText(value);
      _editText.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _editText.text.length,
      );
    });
  }

  Future<void> _inspect(GridCell cell) async {
    final value = _valueAt(cell);
    final column = _columnAt(cell.column);
    final row = cell.row;
    await showValueInspector(
      context,
      title: _gridColumns(_page!)[cell.column],
      value: value,
      onSaveText:
          _writable && column != null && (value == null || value is String)
          ? (text) async {
              final input = ColumnInput.forEdit(
                column,
                value,
                isRowidAlias: _isAlias(column),
              )..setText(text);
              final parsed = input.parse();
              input.dispose();
              if (parsed.error != null) return parsed.error;
              return _update(row, column, parsed.value, report: false);
            }
          : null,
    );
  }

  /// Sets [column] of the row at [row]; returns the error, or null.
  Future<String?> _update(
    int row,
    ColumnDefinition column,
    Object? value, {
    bool report = true,
  }) async {
    final rowid = _rowidAt(row);
    final r = await _db.execute(
      'UPDATE ${sqlName(_table)} SET ${sqlName(column.name)} = ? WHERE rowid = ?',
      [value, rowid],
    );
    final error = !r.success
        ? r.errorMessage ?? 'The update failed.'
        : (r.affectedRows != 1
              ? 'The row was not found; it may have been deleted elsewhere.'
              : null);
    if (report && error != null && mounted) showAdminError(context, error);
    if (mounted) unawaited(_load());
    return error;
  }

  Future<void> _commitEdit() async {
    final cell = _editing;
    if (cell == null || _page == null) return;
    final column = _columnAt(cell.column);
    final original = _valueAt(cell);
    final text = _editText.text;
    setState(() => _editing = null);
    if (column == null || text == editableText(original)) {
      _afterEdit();
      return;
    }
    final input = ColumnInput.forEdit(
      column,
      original,
      isRowidAlias: _isAlias(column),
    )..setText(text);
    final parsed = input.parse();
    input.dispose();
    if (parsed.error != null) {
      showAdminError(context, '${column.name}: ${parsed.error}');
      _afterEdit();
      return;
    }
    await _update(cell.row, column, parsed.value);
    _afterEdit();
  }

  void _cancelEdit() {
    setState(() => _editing = null);
    _afterEdit();
  }

  void _afterEdit() {
    _gridFocus.requestFocus();
    if (_reloadPending) {
      _reloadPending = false;
      _scheduleReload();
    }
  }

  KeyEventResult _onEditKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _cancelEdit();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      unawaited(_commitEdit());
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onGridKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final page = _page;
    if (page == null || _editing != null) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final mod = keys.isControlPressed || keys.isMetaPressed;
    final key = event.logicalKey;
    final rows = page.values.length;
    final cols = _gridColumns(page).length;
    final cell = _cell;
    if (mod && key == LogicalKeyboardKey.keyF) {
      _filterFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (mod && key == LogicalKeyboardKey.keyC && cell != null) {
      unawaited(
        copyText(context, clipboardText(_valueAt(cell)), what: 'Value'),
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      setState(() {
        _cell = null;
        _selected.clear();
      });
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.delete ||
            key == LogicalKeyboardKey.backspace) &&
        _writable) {
      if (_selected.isNotEmpty) {
        unawaited(_deleteSelected());
      } else if (cell != null) {
        unawaited(_deleteRow(cell.row));
      }
      return KeyEventResult.handled;
    }
    if (cell == null) {
      if (rows > 0 &&
          {
            LogicalKeyboardKey.arrowDown,
            LogicalKeyboardKey.arrowUp,
            LogicalKeyboardKey.arrowLeft,
            LogicalKeyboardKey.arrowRight,
          }.contains(key)) {
        setState(() => _cell = (row: 0, column: 0));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    GridCell? next;
    if (key == LogicalKeyboardKey.arrowDown) {
      next = (row: math.min(cell.row + 1, rows - 1), column: cell.column);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      next = (row: math.max(cell.row - 1, 0), column: cell.column);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      next = (row: cell.row, column: math.min(cell.column + 1, cols - 1));
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      next = (row: cell.row, column: math.max(cell.column - 1, 0));
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.f2) {
      unawaited(_editOrInspect(cell));
      return KeyEventResult.handled;
    } else if (key == LogicalKeyboardKey.space && _writable) {
      _toggleSelected(_rowidAt(cell.row));
      return KeyEventResult.handled;
    }
    if (next != null) {
      setState(() => _cell = next);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _toggleSelected(int rowid) => setState(() {
    if (!_selected.remove(rowid)) _selected.add(rowid);
  });

  // ---------------------------------------------------------------------------
  // Rows
  // ---------------------------------------------------------------------------

  Future<void> _openEditor({int? row}) async {
    final rowid = row == null ? null : _rowidAt(row);
    final values = row == null ? null : _rowValues(row);
    if (MediaQuery.sizeOf(context).width >= AdminStyle.sidePanelBreakpoint) {
      setState(() {
        _panelOpen = true;
        _panelRowid = rowid;
        _panelValues = values;
        _panelKey++;
      });
      return;
    }
    final changed = await showRowEditorDialog(
      context,
      _db,
      _table,
      rowid: rowid,
      values: values,
    );
    if (changed && mounted) {
      showAdminMessage(context, rowid == null ? 'Row inserted.' : 'Row saved.');
      unawaited(_load());
    }
  }

  Future<void> _deleteRow(int row) async {
    final rowid = _rowidAt(row);
    if (!await confirmAction(
          context,
          title: 'Delete row $rowid?',
          message: 'Row $rowid of "$_table" is removed for good.',
        ) ||
        !mounted) {
      return;
    }
    final r = await _db.execute(
      'DELETE FROM ${sqlName(_table)} WHERE rowid = ?',
      [rowid],
    );
    if (!mounted) return;
    if (!r.success) {
      showAdminError(context, 'Delete failed: ${r.errorMessage}');
    } else {
      _selected.remove(rowid);
      showAdminMessage(context, 'Row deleted.');
    }
    unawaited(_load());
  }

  Future<void> _deleteSelected() async {
    final rowids = List.of(_selected);
    if (rowids.isEmpty) return;
    if (!await confirmAction(
          context,
          title: 'Delete ${plural(rowids.length, 'row')}?',
          message:
              'The selected ${plural(rowids.length, 'row')} of "$_table" are '
              'removed for good.',
        ) ||
        !mounted) {
      return;
    }
    try {
      await _db.deleteRows(_table, rowids);
      if (!mounted) return;
      setState(_selected.clear);
      showAdminMessage(context, 'Deleted ${plural(rowids.length, 'row')}.');
    } catch (e) {
      if (mounted) {
        showAdminError(context, 'Delete failed: ${describeError(e)}');
      }
    }
    if (mounted) unawaited(_load());
  }

  Future<void> _export() async {
    final page = _page;
    Future<String> all({required bool json}) async {
      final params = <String, Object?>{};
      final fw = _fromWhere(params);
      final r = await _db.query(
        'SELECT *$fw${_orderBy()}',
        params.isEmpty ? null : params,
      );
      if (!r.success) throw StateError(r.errorMessage ?? 'the query failed');
      return json
          ? rowsToJson(r.columns, r.values)
          : rowsToCsv(r.columns, r.values);
    }

    final cols = page == null
        ? const <String>[]
        : (_isView ? page.columns : page.columns.sublist(1));
    final rows = page == null
        ? const <List<Object?>>[]
        : [for (var i = 0; i < page.values.length; i++) _rowValues(i)];
    final filtered = _view.filter.trim().isNotEmpty;
    await showTextExportDialog(
      context,
      title: 'Export the rows of "$_table"',
      baseName: '${_db.name}-$_table',
      options: [
        TextExportOption(
          'CSV: every ${filtered ? 'matching ' : ''}row ($_total)',
          'csv',
          () => all(json: false),
        ),
        TextExportOption(
          'CSV: this page (${rows.length})',
          'csv',
          () async => rowsToCsv(cols, rows),
        ),
        TextExportOption(
          'JSON: every ${filtered ? 'matching ' : ''}row ($_total)',
          'json',
          () => all(json: true),
        ),
        TextExportOption(
          'JSON: this page (${rows.length})',
          'json',
          () async => rowsToJson(cols, rows),
        ),
      ],
    );
  }

  Future<void> _cellMenu(GridCell cell, Offset position) async {
    final value = _valueAt(cell);
    final column = _columnAt(cell.column);
    final name = _gridColumns(_page!)[cell.column];
    final canNull =
        _writable && column != null && !column.notNull && value != null;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        position & const Size(1, 1),
        Offset.zero & overlay.size,
      ),
      items: [
        menuItem(context, 'copy', Icons.copy, 'Copy value'),
        menuItem(context, 'copyRow', Icons.data_object, 'Copy row as JSON'),
        menuItem(context, 'view', Icons.open_in_full, 'View value'),
        if (_writable && column != null) ...[
          const PopupMenuDivider(),
          menuItem(context, 'edit', Icons.edit_outlined, 'Edit cell'),
          menuItem(context, 'editRow', Icons.edit_note, 'Edit row…'),
          if (canNull) menuItem(context, 'null', Icons.block, 'Set to NULL'),
          menuItem(
            context,
            'delete',
            Icons.delete_outline,
            'Delete row…',
            destructive: true,
          ),
        ],
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'copy':
        await copyText(context, clipboardText(value), what: '"$name"');
      case 'copyRow':
        final page = _page!;
        final cols = _isView ? page.columns : page.columns.sublist(1);
        final json = rowsToJson(cols, [_rowValues(cell.row)]);
        await copyText(
          context,
          json.substring(json.indexOf('{'), json.lastIndexOf('}') + 1),
          what: 'Row',
        );
      case 'view':
        await _inspect(cell);
      case 'edit':
        await _editOrInspect(cell);
      case 'editRow':
        await _openEditor(row: cell.row);
      case 'null':
        await _update(cell.row, column!, null);
      case 'delete':
        await _deleteRow(cell.row);
    }
  }

  Future<void> _rowSheet(int row) async {
    final page = _page!;
    final cols = _gridColumns(page);
    final values = _gridRows(page)[row];
    final rowid = _isView ? null : _rowidAt(row);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) {
        final cs = Theme.of(sheet).colorScheme;
        return SizedBox(
          height: MediaQuery.sizeOf(sheet).height * 0.7,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        rowid == null ? 'Row ${row + 1}' : 'Row $rowid',
                        style: Theme.of(sheet).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Copy as JSON',
                      icon: const Icon(Icons.data_object),
                      onPressed: () {
                        final dataCols = _isView
                            ? page.columns
                            : page.columns.sublist(1);
                        final json = rowsToJson(dataCols, [_rowValues(row)]);
                        unawaited(
                          copyText(
                            sheet,
                            json.substring(
                              json.indexOf('{'),
                              json.lastIndexOf('}') + 1,
                            ),
                            what: 'Row',
                          ),
                        );
                      },
                    ),
                    if (_writable) ...[
                      IconButton(
                        key: const ValueKey('jdb-sheet-edit'),
                        tooltip: 'Edit row',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () {
                          Navigator.pop(sheet);
                          unawaited(_openEditor(row: row));
                        },
                      ),
                      IconButton(
                        key: const ValueKey('jdb-sheet-delete'),
                        tooltip: 'Delete row',
                        icon: Icon(Icons.delete_outline, color: cs.error),
                        onPressed: () {
                          Navigator.pop(sheet);
                          unawaited(_deleteRow(row));
                        },
                      ),
                    ],
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  itemCount: cols.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, c) {
                    final v = c < values.length ? values[c] : null;
                    return ListTile(
                      title: Text(cols[c], style: AdminStyle.caption(context)),
                      subtitle: Text(
                        formatCellValue(v, maxLength: 400),
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          color: v == null ? cs.onSurfaceVariant : cs.onSurface,
                          fontStyle: v == null ? FontStyle.italic : null,
                        ),
                      ),
                      onTap: () {
                        Navigator.pop(sheet);
                        unawaited(_inspect((row: row, column: c)));
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!_db.isOpen) {
      return const EmptyState(
        icon: Icons.storage,
        title: 'The database is closed',
      );
    }
    if (!_isView && _schema == null) {
      return EmptyState(
        icon: Icons.table_chart_outlined,
        title: '"$_table" no longer exists',
      );
    }
    final wide = AdminStyle.isWide(context);
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(context, wide),
        if (_selected.isNotEmpty) _selectionBar(context),
        if (_error != null)
          MessageBanner(
            key: const ValueKey('jdb-data-error'),
            message: _error!,
            tone: BannerTone.error,
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          ),
        Expanded(child: _grid(context, wide)),
        PageBar(
          offset: _view.offset,
          pageSize: _pageSize,
          total: _total,
          busy: _loading,
          pageSizes: AdminPreferences.pageSizes,
          leading: Text(
            _status,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AdminStyle.caption(context),
          ),
          onOffsetChanged: (o) {
            _view.offset = o;
            unawaited(_load());
          },
          onPageSizeChanged: (s) {
            widget.controller.setPageSize(s);
            _view.offset = (_view.offset ~/ s) * s;
            unawaited(_load());
          },
        ),
      ],
    );
    if (!_panelOpen ||
        MediaQuery.sizeOf(context).width < AdminStyle.sidePanelBreakpoint) {
      return content;
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: content),
        const VerticalDivider(width: 1),
        SizedBox(
          width: 400,
          child: RowEditor(
            key: ValueKey('jdb-row-panel-$_panelKey'),
            db: _db,
            table: _table,
            rowid: _panelRowid,
            values: _panelValues,
            onDone: (changed) {
              setState(() => _panelOpen = false);
              if (changed) unawaited(_load());
            },
          ),
        ),
      ],
    );
  }

  String get _status {
    final parts = [
      plural(_total, _view.filter.trim().isEmpty ? 'row' : 'matching row'),
      if (_view.sortColumn != null)
        'sorted by ${_view.sortColumn}, '
            '${_view.sortAscending ? 'ascending' : 'descending'}',
    ];
    return parts.join(' · ');
  }

  Widget _toolbar(BuildContext context, bool wide) {
    final where = _view.whereMode;
    final field = TextField(
      key: const ValueKey('jdb-filter'),
      controller: _filter,
      focusNode: _filterFocus,
      style: where ? AdminStyle.mono(context, fontSize: 13) : null,
      onSubmitted: (_) => _applyFilter(),
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        isDense: true,
        border: const OutlineInputBorder(),
        hintText: where
            ? "WHERE …  e.g. age > 30 AND name LIKE 'A%'"
            : 'Search every column',
        prefixIcon: PopupMenuButton<bool>(
          key: const ValueKey('jdb-filter-mode'),
          tooltip: 'Search text, or a WHERE expression',
          initialValue: where,
          icon: Icon(where ? Icons.code : Icons.search, size: 20),
          onSelected: (v) {
            setState(() => _view.whereMode = v);
            if (_view.filter.trim().isNotEmpty ||
                _filter.text.trim().isNotEmpty) {
              _applyFilter();
            }
          },
          itemBuilder: (context) => [
            CheckedPopupMenuItem(
              value: false,
              checked: !where,
              child: const Text('Search text'),
            ),
            CheckedPopupMenuItem(
              value: true,
              checked: where,
              child: const Text('WHERE expression'),
            ),
          ],
        ),
        suffixIcon: _filter.text.isEmpty && _view.filter.isEmpty
            ? null
            : IconButton(
                tooltip: 'Clear the filter',
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () {
                  _filter.clear();
                  _applyFilter();
                },
              ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Row(
        children: [
          Expanded(child: field),
          const SizedBox(width: 8),
          if (wide) ...[
            if (_writable)
              FilledButton.tonalIcon(
                key: const ValueKey('jdb-new-row'),
                onPressed: () => _openEditor(),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New row'),
              ),
            IconButton(
              tooltip: 'Export rows…',
              onPressed: _export,
              icon: const Icon(Icons.upload_outlined),
            ),
            IconButton(
              key: const ValueKey('jdb-reload'),
              tooltip: 'Reload',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh),
            ),
          ] else ...[
            if (_writable)
              IconButton.filledTonal(
                key: const ValueKey('jdb-new-row'),
                tooltip: 'New row',
                onPressed: () => _openEditor(),
                icon: const Icon(Icons.add),
              ),
            PopupMenuButton<String>(
              tooltip: 'More',
              onSelected: (v) {
                if (v == 'export') unawaited(_export());
                if (v == 'reload') unawaited(_load());
              },
              itemBuilder: (context) => [
                menuItem(
                  context,
                  'export',
                  Icons.upload_outlined,
                  'Export rows…',
                ),
                menuItem(context, 'reload', Icons.refresh, 'Reload'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _selectionBar(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      color: cs.secondaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${_selected.length} selected',
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: cs.onSecondaryContainer,
              ),
            ),
          ),
          TextButton(
            onPressed: () => setState(_selected.clear),
            child: const Text('Clear'),
          ),
          if (_writable)
            FilledButton.icon(
              key: const ValueKey('jdb-delete-selected'),
              onPressed: _deleteSelected,
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Delete'),
              style: FilledButton.styleFrom(
                backgroundColor: cs.error,
                foregroundColor: cs.onError,
              ),
            ),
        ],
      ),
    );
  }

  Widget _grid(BuildContext context, bool wide) {
    final page = _page;
    if (page == null) {
      return _loading
          ? const Center(child: CircularProgressIndicator())
          : const SizedBox.shrink();
    }
    if (page.isEmpty) {
      final filtered = _view.filter.trim().isNotEmpty;
      return EmptyState(
        icon: filtered ? Icons.filter_alt_off_outlined : Icons.inbox_outlined,
        title: filtered ? 'No rows match' : 'No rows in "$_table"',
        action: filtered
            ? OutlinedButton(
                onPressed: () {
                  _filter.clear();
                  _applyFilter();
                },
                child: const Text('Clear the filter'),
              )
            : (_writable
                  ? OutlinedButton.icon(
                      onPressed: () => _openEditor(),
                      icon: const Icon(Icons.add),
                      label: const Text('New row'),
                    )
                  : null),
      );
    }
    final cs = Theme.of(context).colorScheme;
    final columns = _gridColumns(page);
    final rows = _gridRows(page);
    final rowids = _isView
        ? const <int>[]
        : [for (final r in page.values) r.first as int];
    final allSelected = rowids.isNotEmpty && rowids.every(_selected.contains);
    final someSelected = rowids.any(_selected.contains);
    final grid = ResultGrid(
      key: ValueKey('jdb-data-grid-$_table'),
      columns: columns,
      rows: rows,
      dense: wide,
      widths: _view.widths,
      onResize: (c, w) => setState(() => _view.widths[c] = w),
      sortColumn: _view.sortColumn,
      sortAscending: _view.sortAscending,
      onSort: (c) {
        if (_view.sortColumn != c) {
          _view
            ..sortColumn = c
            ..sortAscending = true;
        } else if (_view.sortAscending) {
          _view.sortAscending = false;
        } else {
          _view.sortColumn = null;
        }
        _view.offset = 0;
        unawaited(_load());
      },
      leadingWidth: _writable ? 44 : 0,
      leadingHeader: _writable
          ? Checkbox(
              tristate: true,
              value: allSelected ? true : (someSelected ? null : false),
              semanticLabel: 'Select the rows of this page',
              onChanged: (_) => setState(() {
                if (allSelected) {
                  _selected.removeAll(rowids);
                } else {
                  _selected.addAll(rowids);
                }
              }),
            )
          : null,
      leadingBuilder: _writable
          ? (context, i) => Checkbox(
              value: _selected.contains(rowids[i]),
              semanticLabel: 'Select row ${rowids[i]}',
              onChanged: (_) => _toggleSelected(rowids[i]),
            )
          : null,
      isSelected: _isView ? null : (i) => _selected.contains(rowids[i]),
      selectedCell: wide ? _cell : null,
      onCellTap: (cell) {
        if (!wide) {
          if (_selected.isNotEmpty && !_isView) {
            _toggleSelected(rowids[cell.row]);
          } else {
            unawaited(_rowSheet(cell.row));
          }
          return;
        }
        setState(() => _cell = cell);
        _gridFocus.requestFocus();
      },
      onCellDoubleTap: (cell) {
        if (!wide) {
          unawaited(_rowSheet(cell.row));
          return;
        }
        unawaited(_editOrInspect(cell));
      },
      onCellMenu: (cell, position) {
        if (!wide && !_isView && _writable) {
          _toggleSelected(rowids[cell.row]);
          return;
        }
        setState(() => _cell = cell);
        unawaited(_cellMenu(cell, position));
      },
      cellOverride: (context, cell) => _editing == cell
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: TextField(
                key: const ValueKey('jdb-cell-editor'),
                controller: _editText,
                focusNode: _editFocus,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                onSubmitted: (_) => _commitEdit(),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: cs.surface,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderSide: BorderSide(color: cs.primary),
                  ),
                ),
              ),
            )
          : null,
    );
    return Stack(
      children: [
        Focus(focusNode: _gridFocus, child: grid),
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

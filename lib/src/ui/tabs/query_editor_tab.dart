import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_signals/just_signals.dart';

import '../../core/query_result.dart';
import '../admin_utils.dart';
import '../database_provider.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/result_grid.dart';

const List<String> _exampleQueries = [
  'SELECT * FROM users LIMIT 100',
  'SELECT * FROM users WHERE age > 25 ORDER BY name',
  'SELECT category, COUNT(*) AS count, AVG(price) AS avg_price FROM products GROUP BY category',
  'SELECT u.name, COUNT(o.id) AS orders FROM users u LEFT JOIN orders o ON o.user_id = u.id GROUP BY u.id ORDER BY orders DESC',
  "SELECT * FROM products WHERE name LIKE '%Pro%'",
  'CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)',
  "INSERT INTO notes (body) VALUES ('Hello'), ('World')",
  "UPDATE notes SET body = body || '!' WHERE id = 1",
  'DELETE FROM notes WHERE id = 2',
  "BEGIN; INSERT INTO notes (body) VALUES ('a'); INSERT INTO notes (body) VALUES ('b'); COMMIT;",
];

/// Runs SQL on the selected database and shows the result a page at a
/// time.
class QueryEditorTab extends StatefulWidget {
  /// Creates the tab.
  const QueryEditorTab({super.key, required this.provider});

  /// The admin state.
  final DatabaseProvider provider;

  @override
  State<QueryEditorTab> createState() => _QueryEditorTabState();
}

enum _Panel { results, history, examples }

class _QueryEditorTabState extends State<QueryEditorTab> {
  final TextEditingController _sql = TextEditingController();
  _Panel _panel = _Panel.results;
  QueryResult? _shown;
  int _offset = 0;
  int _pageSize = 100;

  @override
  void dispose() {
    _sql.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final provider = widget.provider;
    if (provider.isLoading) return;
    setState(() => _panel = _Panel.results);
    await provider.runQuery(_sql.text);
  }

  void _pick(String sql) {
    _sql.text = sql;
    setState(() => _panel = _Panel.results);
  }

  @override
  Widget build(BuildContext context) {
    return SignalBuilder<int>(
      signal: widget.provider.revision,
      builder: (context, _, _) {
        final provider = widget.provider;
        final result = provider.lastQueryResult;
        if (!identical(result, _shown)) {
          _shown = result;
          _offset = 0;
        }
        final db = provider.currentDatabase;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (db == null)
              const MessageBanner(
                message: 'No database selected. Open one on the Databases tab.',
                margin: EdgeInsets.fromLTRB(8, 8, 8, 0),
              ),
            _SqlInput(controller: _sql, onRun: _run),
            _ActionBar(
              running: provider.isLoading,
              canRun: db != null,
              panel: _panel,
              onRun: _run,
              onClear: () {
                _sql.clear();
                provider.clearQueryResult();
              },
              onPanel: (p) =>
                  setState(() => _panel = _panel == p ? _Panel.results : p),
            ),
            if (provider.lastQueryError != null)
              MessageBanner(
                key: const ValueKey('jdb-query-error'),
                message: provider.lastQueryError!,
                tone: BannerTone.error,
                margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              ),
            if (db != null && db.inTransaction)
              const MessageBanner(
                message:
                    'A transaction is open: its changes are saved after '
                    'COMMIT (or undone by ROLLBACK).',
                margin: EdgeInsets.fromLTRB(8, 0, 8, 8),
              ),
            Expanded(
              child: switch (_panel) {
                _Panel.history => _SqlList(
                  items: provider.queryHistory,
                  icon: Icons.history,
                  empty: 'No statements run yet.',
                  onSelect: _pick,
                ),
                _Panel.examples => _SqlList(
                  items: _exampleQueries,
                  icon: Icons.lightbulb_outline,
                  empty: '',
                  onSelect: _pick,
                ),
                _Panel.results => _results(context, provider),
              },
            ),
          ],
        );
      },
    );
  }

  Widget _results(BuildContext context, DatabaseProvider provider) {
    final cs = Theme.of(context).colorScheme;
    final qr = provider.lastQueryResult;
    if (qr == null) {
      return const EmptyState(
        icon: Icons.table_view,
        title: 'Run a statement to see its result',
        message:
            'Ctrl+Enter (Shift+Enter on Android) runs it. Several '
            'statements separated by ";" run as a script.',
      );
    }
    if (!qr.success) return const SizedBox.shrink();
    final scriptNote = provider.lastStatementCount > 1
        ? 'Ran ${provider.lastStatementCount} statements; the last one returned this.'
        : null;
    if (qr.columns.isEmpty) {
      return EmptyState(
        icon: Icons.check_circle_outline,
        title: '${qr.affectedRows} row(s) affected.',
        message: [
          if (qr.lastInsertRowId != null)
            'Last inserted rowid: ${qr.lastInsertRowId}.',
          ?scriptNote,
        ].join('\n'),
      );
    }
    final total = qr.values.length;
    final start = math.min(_offset, total);
    final end = math.min(start + _pageSize, total);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Text(
            [plural(total, 'row'), ?scriptNote].join(' · '),
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ResultGrid(
            columns: qr.columns,
            rows: qr.values.sublist(start, end),
          ),
        ),
        PageBar(
          offset: start,
          pageSize: _pageSize,
          total: total,
          pageSizes: const [50, 100, 250, 1000],
          onOffsetChanged: (o) => setState(() => _offset = o),
          onPageSizeChanged: (s) => setState(() {
            _pageSize = s;
            _offset = (_offset ~/ s) * s;
          }),
        ),
      ],
    );
  }
}

class _SqlInput extends StatefulWidget {
  const _SqlInput({required this.controller, required this.onRun});

  final TextEditingController controller;
  final VoidCallback onRun;

  @override
  State<_SqlInput> createState() => _SqlInputState();
}

class _SqlInputState extends State<_SqlInput> {
  late final FocusNode _focusNode = FocusNode(
    onKeyEvent: (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      final isAndroid = defaultTargetPlatform == TargetPlatform.android;
      final modifier = isAndroid
          ? HardwareKeyboard.instance.isShiftPressed
          : (HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed);
      if (modifier && event.logicalKey == LogicalKeyboardKey.enter) {
        widget.onRun();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    },
  );

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      constraints: const BoxConstraints(minHeight: 96, maxHeight: 180),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: TextField(
        key: const ValueKey('jdb-sql'),
        controller: widget.controller,
        focusNode: _focusNode,
        maxLines: null,
        expands: true,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          height: 1.5,
          color: cs.onSurface,
        ),
        decoration: InputDecoration(
          hintText: 'Enter SQL here…',
          hintStyle: TextStyle(color: cs.onSurfaceVariant),
          border: InputBorder.none,
          isDense: true,
        ),
        textInputAction: TextInputAction.newline,
        keyboardType: TextInputType.multiline,
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.running,
    required this.canRun,
    required this.panel,
    required this.onRun,
    required this.onClear,
    required this.onPanel,
  });

  final bool running;
  final bool canRun;
  final _Panel panel;
  final VoidCallback onRun;
  final VoidCallback onClear;
  final ValueChanged<_Panel> onPanel;

  @override
  Widget build(BuildContext context) {
    final shortcut = defaultTargetPlatform == TargetPlatform.android
        ? 'Shift+Enter'
        : 'Ctrl+Enter';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Tooltip(
            message: shortcut,
            child: FilledButton.icon(
              key: const ValueKey('jdb-run'),
              onPressed: running || !canRun ? null : onRun,
              icon: running
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow, size: 18),
              label: const Text('Run'),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: onClear, child: const Text('Clear')),
          const Spacer(),
          IconButton(
            tooltip: 'History',
            isSelected: panel == _Panel.history,
            icon: const Icon(Icons.history),
            onPressed: () => onPanel(_Panel.history),
          ),
          IconButton(
            tooltip: 'Examples',
            isSelected: panel == _Panel.examples,
            icon: const Icon(Icons.lightbulb_outline),
            selectedIcon: const Icon(Icons.lightbulb),
            onPressed: () => onPanel(_Panel.examples),
          ),
        ],
      ),
    );
  }
}

class _SqlList extends StatelessWidget {
  const _SqlList({
    required this.items,
    required this.icon,
    required this.empty,
    required this.onSelect,
  });

  final List<String> items;
  final IconData icon;
  final String empty;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return EmptyState(icon: icon, title: empty);
    }
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => ListTile(
        dense: true,
        leading: Icon(icon, size: 18),
        title: Text(
          items[i],
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        onTap: () => onSelect(items[i]),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_database/just_database.dart';

const List<String> _exampleQueries = [
  'SELECT * FROM users',
  'SELECT * FROM users WHERE age > 25 ORDER BY name',
  'SELECT * FROM products WHERE category = \'Electronics\' ORDER BY price DESC',
  'SELECT * FROM orders WHERE status = \'delivered\'',
  'SELECT u.name, COUNT(o.id) AS order_count FROM users u LEFT JOIN orders o ON u.id = o.user_id GROUP BY u.id ORDER BY order_count DESC',
  'SELECT category, COUNT(*) AS count, AVG(price) AS avg_price, MIN(price) AS min_price, MAX(price) AS max_price FROM products GROUP BY category',
  'SELECT o.id, u.name, o.total, o.status FROM orders o INNER JOIN users u ON o.user_id = u.id ORDER BY o.id',
  'SELECT p.name, SUM(oi.quantity) AS units_sold FROM products p INNER JOIN order_items oi ON p.id = oi.product_id GROUP BY p.id ORDER BY units_sold DESC',
  'SELECT * FROM users WHERE active = true AND age BETWEEN 25 AND 40',
  'SELECT * FROM products WHERE name LIKE \'%Pro%\'',
];

class QueryEditorTab extends StatefulWidget {
  const QueryEditorTab({super.key});

  @override
  State<QueryEditorTab> createState() => _QueryEditorTabState();
}

class _QueryEditorTabState extends State<QueryEditorTab> {
  final TextEditingController _sqlController = TextEditingController();
  bool _showHistory = false;
  bool _showExamples = false;

  @override
  void dispose() {
    _sqlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DatabaseProvider>();
    return Column(
      children: [
        // SQL input area
        _SqlInputArea(controller: _sqlController),

        // Action bar
        _ActionBar(
          onRun: () {
            setState(() {
              _showHistory = false;
              _showExamples = false;
            });
            provider.runQuery(_sqlController.text);
          },
          onClear: () => _sqlController.clear(),
          onToggleHistory: () => setState(() {
            _showHistory = !_showHistory;
            _showExamples = false;
          }),
          onToggleExamples: () => setState(() {
            _showExamples = !_showExamples;
            _showHistory = false;
          }),
          isLoading: provider.isLoading,
          showHistory: _showHistory,
          showExamples: _showExamples,
        ),

        // Error banner
        if (provider.lastError != null)
          _ErrorBanner(message: provider.lastError!),

        // Results / History / Examples
        Expanded(
          child: _showHistory
              ? _HistoryPanel(
                  history: provider.queryHistory,
                  onSelect: (sql) {
                    _sqlController.text = sql;
                    setState(() => _showHistory = false);
                  },
                )
              : _showExamples
              ? _ExamplesPanel(
                  onSelect: (sql) {
                    _sqlController.text = sql;
                    setState(() => _showExamples = false);
                  },
                )
              : SizedBox(
                  width: double.infinity,
                  child: _ResultsPanel(result: provider.lastQueryResult),
                ),
        ),
      ],
    );
  }
}

class _SqlInputArea extends StatelessWidget {
  final TextEditingController controller;
  const _SqlInputArea({required this.controller});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minHeight: 100, maxHeight: 180),
      color: isDark ? const Color(0xFF1E1E1E) : const Color(0xFF2D2D2D),
      padding: const EdgeInsets.all(12),
      child: TextField(
        controller: controller,
        maxLines: null,
        expands: true,
        style: const TextStyle(
          fontFamily: 'monospace',
          color: Colors.white,
          fontSize: 13,
          height: 1.5,
        ),
        decoration: const InputDecoration(
          hintText: 'Enter SQL here...',
          hintStyle: TextStyle(color: Colors.grey),
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
  final VoidCallback onRun;
  final VoidCallback onClear;
  final VoidCallback onToggleHistory;
  final VoidCallback onToggleExamples;
  final bool isLoading;
  final bool showHistory;
  final bool showExamples;

  const _ActionBar({
    required this.onRun,
    required this.onClear,
    required this.onToggleHistory,
    required this.onToggleExamples,
    required this.isLoading,
    required this.showHistory,
    required this.showExamples,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: isLoading ? null : onRun,
            icon: isLoading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.play_arrow, size: 18),
            label: const Text('Run'),
          ),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: onClear, child: const Text('Clear')),
          const Spacer(),
          ToggleButtons(
            isSelected: [showHistory, showExamples],
            onPressed: (i) {
              if (i == 0) onToggleHistory();
              if (i == 1) onToggleExamples();
            },
            borderRadius: BorderRadius.circular(8),
            children: const [
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Icon(Icons.history, size: 16),
                    SizedBox(width: 4),
                    Text('History'),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  children: [
                    Icon(Icons.lightbulb, size: 16),
                    SizedBox(width: 4),
                    Text('Examples'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.errorContainer,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline,
            size: 16,
            color: Theme.of(context).colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultsPanel extends StatelessWidget {
  final QueryResult? result;
  const _ResultsPanel({required this.result});

  @override
  Widget build(BuildContext context) {
    if (result == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.table_view, size: 48, color: Colors.grey),
            SizedBox(height: 8),
            Text(
              'Run a query to see results.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }
    final qr = result!;
    if (!qr.success) return const SizedBox.shrink();

    if (qr.columns.isEmpty) {
      return const Center(
        child: Text(
          'Query returned no columns.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    if (qr.rows.isEmpty && qr.affectedRows == 0) {
      return const Center(
        child: Text(
          'Query returned no rows.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }

    if (qr.rows.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle, color: Colors.green, size: 40),
            const SizedBox(height: 8),
            Text('${qr.affectedRows} row(s) affected.'),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Text(
            '${qr.rows.length} row${qr.rows.length != 1 ? 's' : ''}',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        Expanded(
          child: SizedBox(
            width: double.infinity,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: DataTable(
                  columnSpacing: 20,
                  headingRowColor: WidgetStateProperty.all(
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                  columns: qr.columns
                      .map(
                        (c) => DataColumn(
                          label: Text(
                            c,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      )
                      .toList(),
                  rows: qr.rows
                      .map(
                        (row) => DataRow(
                          cells: qr.columns
                              .map(
                                (c) => DataCell(
                                  Text(
                                    row[c]?.toString() ?? 'NULL',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: row[c] == null
                                          ? Colors.grey
                                          : null,
                                      fontStyle: row[c] == null
                                          ? FontStyle.italic
                                          : null,
                                    ),
                                  ),
                                ),
                              )
                              .toList(),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _HistoryPanel extends StatelessWidget {
  final List<String> history;
  final void Function(String) onSelect;

  const _HistoryPanel({required this.history, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    if (history.isEmpty) {
      return const Center(
        child: Text(
          'No query history yet.',
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.separated(
      itemCount: history.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => ListTile(
        dense: true,
        leading: const Icon(Icons.history, size: 16),
        title: Text(
          history[i],
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        onTap: () => onSelect(history[i]),
      ),
    );
  }
}

class _ExamplesPanel extends StatelessWidget {
  final void Function(String) onSelect;
  const _ExamplesPanel({required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: _exampleQueries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => ListTile(
        dense: true,
        leading: const Icon(Icons.lightbulb_outline, size: 16),
        title: Text(
          _exampleQueries[i],
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        onTap: () => onSelect(_exampleQueries[i]),
      ),
    );
  }
}

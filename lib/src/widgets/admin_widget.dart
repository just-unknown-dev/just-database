import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/database.dart';
import '../core/database_manager.dart';
import '../sql/executor.dart';

/// A self-contained admin widget that can be embedded in any Flutter app.
///
/// Usage:
/// ```dart
/// // Embed in a route or dialog
/// JustDatabaseAdminWidget(initialDatabase: myDb)
/// ```
class JustDatabaseAdminWidget extends StatelessWidget {
  final JustDatabase? initialDatabase;
  final String title;

  const JustDatabaseAdminWidget({
    super.key,
    this.initialDatabase,
    this.title = 'Database Admin',
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => _AdminState(initialDatabase),
      child: _AdminView(title: title),
    );
  }
}

class _AdminState extends ChangeNotifier {
  JustDatabase? currentDatabase;
  List<DatabaseInfo> databases = [];
  QueryResult? lastResult;
  String? lastError;
  bool isLoading = false;

  _AdminState(JustDatabase? initial) {
    currentDatabase = initial;
    refresh();
  }

  Future<void> refresh() async {
    isLoading = true;
    notifyListeners();
    try {
      databases = await DatabaseManager.listDatabases();
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> runQuery(String sql) async {
    if (currentDatabase == null) {
      lastError = 'No database selected.';
      notifyListeners();
      return;
    }
    isLoading = true;
    notifyListeners();
    try {
      final s = sql.trim().toLowerCase();
      if (s.startsWith('select')) {
        lastResult = await currentDatabase!.query(sql);
      } else {
        lastResult = await currentDatabase!.execute(sql);
        await refresh();
      }
      lastError = lastResult!.success ? null : lastResult!.errorMessage;
    } catch (e) {
      lastError = e.toString();
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  void selectDatabase(DatabaseInfo info) async {
    try {
      currentDatabase =
          DatabaseManager.getOpenDatabase(info.name) ??
          await DatabaseManager.open(info.name);
      lastError = null;
      notifyListeners();
    } catch (e) {
      lastError = e.toString();
      notifyListeners();
    }
  }
}

class _AdminView extends StatefulWidget {
  final String title;
  const _AdminView({required this.title});

  @override
  State<_AdminView> createState() => _AdminViewState();
}

class _AdminViewState extends State<_AdminView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _queryController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _queryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<_AdminState>();
    final colorScheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Text(widget.title),
            if (state.currentDatabase != null) ...[
              const SizedBox(width: 8),
              Chip(
                label: Text(state.currentDatabase!.name),
                backgroundColor: colorScheme.primaryContainer,
                labelStyle: TextStyle(color: colorScheme.onPrimaryContainer),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ],
        ),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.storage), text: 'DBs'),
            Tab(icon: Icon(Icons.schema), text: 'Schema'),
            Tab(icon: Icon(Icons.code), text: 'Query'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _DatabaseListTab(
            onSelect: (info) {
              context.read<_AdminState>().selectDatabase(info);
              _tabs.animateTo(2); // jump to query tab
            },
          ),
          _SchemaTab(),
          _QueryTab(controller: _queryController),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Database List Tab
// ---------------------------------------------------------------------------

class _DatabaseListTab extends StatelessWidget {
  final void Function(DatabaseInfo) onSelect;
  const _DatabaseListTab({required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<_AdminState>();
    if (state.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (state.databases.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.storage, size: 48, color: Colors.grey),
            const SizedBox(height: 8),
            const Text('No databases found.'),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => context.read<_AdminState>().refresh(),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: context.read<_AdminState>().refresh,
      child: ListView.builder(
        itemCount: state.databases.length,
        itemBuilder: (_, i) {
          final db = state.databases[i];
          final isSelected = state.currentDatabase?.name == db.name;
          return ListTile(
            selected: isSelected,
            leading: Icon(
              db.isOpen ? Icons.lock_open : Icons.lock,
              color: db.isOpen ? Colors.green : Colors.grey,
            ),
            title: Text(db.name),
            subtitle: Text(
              '${db.modeName} • ${db.formattedSize} • ${db.tableCount} tables',
            ),
            trailing: isSelected
                ? const Icon(Icons.check_circle, color: Colors.green)
                : null,
            onTap: () => onSelect(db),
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Schema Tab
// ---------------------------------------------------------------------------

class _SchemaTab extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final state = context.watch<_AdminState>();
    final db = state.currentDatabase;
    if (db == null) {
      return const Center(child: Text('Select a database first.'));
    }
    final tables = db.tableNames;
    if (tables.isEmpty) {
      return const Center(
        child: Text('No tables. Run CREATE TABLE in the Query tab.'),
      );
    }
    return ListView.builder(
      itemCount: tables.length,
      itemBuilder: (_, i) {
        final schema = db.getTableSchema(tables[i]);
        if (schema == null) return const SizedBox.shrink();
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: ExpansionTile(
            leading: const Icon(Icons.table_chart),
            title: Text(
              schema.tableName,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text('${schema.columns.length} columns'),
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Column')),
                    DataColumn(label: Text('Type')),
                    DataColumn(label: Text('Constraints')),
                  ],
                  rows: schema.columns.map((col) {
                    final c = col.constraints;
                    final constraints = [
                      if (c.primaryKey) 'PK',
                      if (c.autoIncrement) 'AI',
                      if (c.notNull) 'NOT NULL',
                      if (c.unique) 'UNIQUE',
                      if (c.hasDefault) 'DEFAULT=${c.defaultValue}',
                      if (c.foreignKeyTable != null) 'FK→${c.foreignKeyTable}',
                    ].join(', ');
                    return DataRow(
                      cells: [
                        DataCell(Text(col.name)),
                        DataCell(
                          Chip(
                            label: Text(col.type.name.toUpperCase()),
                            padding: EdgeInsets.zero,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                        DataCell(Text(constraints)),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Query Tab
// ---------------------------------------------------------------------------

class _QueryTab extends StatelessWidget {
  final TextEditingController controller;
  const _QueryTab({required this.controller});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<_AdminState>();
    return Column(
      children: [
        // SQL input
        Container(
          color: Colors.grey.shade900,
          padding: const EdgeInsets.all(8),
          child: TextField(
            controller: controller,
            maxLines: 5,
            style: const TextStyle(
              fontFamily: 'monospace',
              color: Colors.white,
              fontSize: 13,
            ),
            decoration: const InputDecoration(
              hintText: 'Enter SQL query...',
              hintStyle: TextStyle(color: Colors.grey),
              border: InputBorder.none,
            ),
          ),
        ),
        // Action bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              FilledButton.icon(
                onPressed: state.isLoading
                    ? null
                    : () =>
                          context.read<_AdminState>().runQuery(controller.text),
                icon: state.isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: const Text('Run'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => controller.clear(),
                child: const Text('Clear'),
              ),
            ],
          ),
        ),
        // Error
        if (state.lastError != null)
          Container(
            width: double.infinity,
            color: Colors.red.shade100,
            padding: const EdgeInsets.all(8),
            child: Text(
              state.lastError!,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        // Results
        Expanded(child: _ResultsView(result: state.lastResult)),
      ],
    );
  }
}

class _ResultsView extends StatelessWidget {
  final QueryResult? result;
  const _ResultsView({required this.result});

  @override
  Widget build(BuildContext context) {
    if (result == null) {
      return const Center(child: Text('Run a query to see results.'));
    }
    if (!result!.success) return const SizedBox.shrink();
    if (result!.rows.isEmpty && result!.affectedRows == 0) {
      return const Center(child: Text('Query returned no rows.'));
    }
    if (result!.rows.isEmpty) {
      return Center(child: Text('${result!.affectedRows} row(s) affected.'));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: DataTable(
          columns: result!.columns
              .map((c) => DataColumn(label: Text(c)))
              .toList(),
          rows: result!.rows
              .map(
                (row) => DataRow(
                  cells: result!.columns
                      .map((c) => DataCell(Text(row[c]?.toString() ?? 'NULL')))
                      .toList(),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:just_signals/just_signals.dart';

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
class JustDatabaseAdminWidget extends StatefulWidget {
  final JustDatabase? initialDatabase;
  final String title;

  const JustDatabaseAdminWidget({
    super.key,
    this.initialDatabase,
    this.title = 'Database Admin',
  });

  @override
  State<JustDatabaseAdminWidget> createState() =>
      _JustDatabaseAdminWidgetState();
}

class _JustDatabaseAdminWidgetState extends State<JustDatabaseAdminWidget> {
  late final _AdminState _state;

  @override
  void initState() {
    super.initState();
    _state = _AdminState(widget.initialDatabase);
  }

  @override
  Widget build(BuildContext context) {
    return _AdminView(title: widget.title, state: _state);
  }
}

class _AdminState {
  final Signal<int> revision = Signal(0, debugLabel: 'adminWidgetRevision');

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
    _notify();
    try {
      databases = await DatabaseManager.listDatabases();
      lastError = null;
    } catch (e) {
      lastError = e.toString();
    } finally {
      isLoading = false;
      _notify();
    }
  }

  Future<void> runQuery(String sql) async {
    if (currentDatabase == null) {
      lastError = 'No database selected.';
      _notify();
      return;
    }
    isLoading = true;
    _notify();
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
      _notify();
    }
  }

  void selectDatabase(DatabaseInfo info) async {
    try {
      currentDatabase =
          DatabaseManager.getOpenDatabase(info.name) ??
          await DatabaseManager.open(info.name);
      lastError = null;
      _notify();
    } catch (e) {
      lastError = e.toString();
      _notify();
    }
  }

  void _notify() {
    revision.value++;
  }
}

class _AdminView extends StatefulWidget {
  final String title;
  final _AdminState state;

  const _AdminView({required this.title, required this.state});

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
    return SignalBuilder<int>(
      signal: widget.state.revision,
      builder: (context, value, child) {
        final state = widget.state;
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
                    labelStyle: TextStyle(
                      color: colorScheme.onPrimaryContainer,
                    ),
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
                state: state,
                onSelect: (info) {
                  state.selectDatabase(info);
                  _tabs.animateTo(2); // jump to query tab
                },
              ),
              _SchemaTab(state: state),
              _QueryTab(state: state, controller: _queryController),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Database List Tab
// ---------------------------------------------------------------------------

class _DatabaseListTab extends StatelessWidget {
  final _AdminState state;
  final void Function(DatabaseInfo) onSelect;
  const _DatabaseListTab({required this.state, required this.onSelect});

  @override
  Widget build(BuildContext context) {
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
              onPressed: state.refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: state.refresh,
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
  final _AdminState state;

  const _SchemaTab({required this.state});

  @override
  Widget build(BuildContext context) {
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
  final _AdminState state;
  final TextEditingController controller;
  const _QueryTab({required this.state, required this.controller});

  @override
  Widget build(BuildContext context) {
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
                    : () => state.runQuery(controller.text),
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

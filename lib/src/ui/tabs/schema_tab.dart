import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:just_database/just_database.dart';

class SchemaTab extends StatelessWidget {
  const SchemaTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DatabaseProvider>();
    final db = provider.currentDatabase;

    if (db == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.schema, size: 56, color: Colors.grey),
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

    final tables = db.tableNames;
    if (tables.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.table_chart, size: 56, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              'No tables in "${db.name}"',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            const Text(
              'Use the Query tab to CREATE TABLE.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      itemCount: tables.length,
      itemBuilder: (_, i) {
        final schema = db.getTableSchema(tables[i]);
        if (schema == null) return const SizedBox.shrink();
        return _TableSchemaCard(schema: schema);
      },
    );
  }
}

class _TableSchemaCard extends StatelessWidget {
  final TableSchema schema;
  const _TableSchemaCard({required this.schema});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: const Icon(Icons.table_chart),
        title: Text(
          schema.tableName,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          '${schema.columns.length} column${schema.columns.length != 1 ? 's' : ''}',
        ),
        initiallyExpanded: true,
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 24,
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
                  if (c.notNull && !c.primaryKey) 'NOT NULL',
                  if (c.unique && !c.primaryKey) 'UNIQUE',
                  if (c.hasDefault) 'DEFAULT = ${c.defaultValue ?? 'NULL'}',
                  if (c.foreignKeyTable != null)
                    'FK → ${c.foreignKeyTable}.${c.foreignKeyColumn ?? 'id'}',
                ].join('  ');

                return DataRow(
                  cells: [
                    DataCell(
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (c.primaryKey)
                            const Padding(
                              padding: EdgeInsets.only(right: 4),
                              child: Icon(
                                Icons.key,
                                size: 14,
                                color: Colors.amber,
                              ),
                            ),
                          Text(
                            col.name,
                            style: const TextStyle(fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                    DataCell(_TypeChip(type: col.type)),
                    DataCell(
                      Text(
                        constraints.isEmpty ? '—' : constraints,
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  final DataType type;
  const _TypeChip({required this.type});

  @override
  Widget build(BuildContext context) {
    final color = switch (type) {
      DataType.integer => Colors.blue,
      DataType.text => Colors.green,
      DataType.real => Colors.purple,
      DataType.blob => Colors.brown,
      DataType.boolean => Colors.orange,
      DataType.datetime => Colors.teal,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(25),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withAlpha(80)),
      ),
      child: Text(
        type.name.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

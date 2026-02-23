import 'package:flutter/foundation.dart';
import 'package:just_database/just_database.dart';

/// Example demonstrating persistence and advanced features
Future<void> main() async {
  debugPrint('=== Persistent Database Example ===\n');

  // Create a persistent database
  debugPrint('Creating persistent database...');
  final db = await DatabaseManager.open(
    'my_persistent_db',
    mode: DatabaseMode.standard,
    persist: true,
  );

  // Create a table if it doesn't exist
  await db.execute('''
    CREATE TABLE IF NOT EXISTS tasks (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      description TEXT,
      completed BOOLEAN DEFAULT false,
      priority INTEGER DEFAULT 0,
      created_at INTEGER NOT NULL
    )
  ''');

  // Insert some tasks
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.execute(
    "INSERT INTO tasks (title, description, priority, created_at) "
    "VALUES ('Learn just_database', 'Read documentation and examples', 3, $now)",
  );
  await db.execute(
    "INSERT INTO tasks (title, description, priority, created_at) "
    "VALUES ('Build an app', 'Create a Flutter app using just_database', 2, $now)",
  );
  await db.execute(
    "INSERT INTO tasks (title, priority, created_at) "
    "VALUES ('Deploy to production', 1, $now)",
  );

  // Query tasks by priority
  debugPrint('\nHigh priority tasks:');
  var result = await db.execute(
    'SELECT * FROM tasks WHERE priority >= 2 ORDER BY priority DESC',
  );
  for (var task in result.rows) {
    debugPrint('  [P${task['priority']}] ${task['title']}');
  }

  // Demonstrate query execution
  debugPrint('\nRunning multiple queries...');

  // Run same query pattern multiple times
  for (int i = 0; i < 10; i++) {
    await db.execute('SELECT * FROM tasks WHERE priority > 1');
  }
  debugPrint('Executed 10 queries successfully');

  // Update a task
  await db.execute("UPDATE tasks SET completed = true WHERE id = 1");

  // List all databases
  debugPrint('\nAll databases:');
  final databases = await DatabaseManager.listDatabases();
  for (var dbInfo in databases) {
    debugPrint(
      '  ${dbInfo.name} - ${dbInfo.formattedSize} - ${dbInfo.tableCount} tables',
    );
  }

  // Close the database
  debugPrint('\nClosing database...');
  await DatabaseManager.close('my_persistent_db');

  // Reopen to demonstrate persistence
  debugPrint('Reopening database...');
  final reopened = await DatabaseManager.open('my_persistent_db');

  result = await reopened.execute('SELECT * FROM tasks');
  debugPrint('Tasks after reopening: ${result.rows.length}');
  debugPrint('Data persisted successfully!');

  debugPrint('\n=== Example Complete ===');
}

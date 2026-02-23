import 'package:flutter/foundation.dart';
import 'package:just_database/just_database.dart';

/// Example demonstrating basic usage of just_database
Future<void> main() async {
  debugPrint('=== just_database Example ===\n');

  // Create a database
  debugPrint('Creating database...');
  final db = await JustDatabase.open('example_db', mode: DatabaseMode.standard);

  // Create a table
  debugPrint('Creating users table...');
  await db.execute('''
    CREATE TABLE users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT UNIQUE,
      age INTEGER,
      active BOOLEAN DEFAULT true
    )
  ''');

  // Insert some data
  debugPrint('Inserting users...');
  await db.execute(
    "INSERT INTO users (name, email, age) VALUES ('Alice Johnson', 'alice@example.com', 28)",
  );
  await db.execute(
    "INSERT INTO users (name, email, age) VALUES ('Bob Smith', 'bob@example.com', 34)",
  );
  await db.execute(
    "INSERT INTO users (name, email, age, active) VALUES ('Carol White', 'carol@example.com', 25, false)",
  );

  // Query all users
  debugPrint('\nQuerying all users:');
  var result = await db.execute('SELECT * FROM users');
  for (var row in result.rows) {
    debugPrint('  ${row['name']} (${row['age']}) - ${row['email']}');
  }

  // Query with WHERE clause
  debugPrint('\nActive users over 25:');
  result = await db.execute(
    'SELECT * FROM users WHERE age > 25 AND active = true',
  );
  for (var row in result.rows) {
    debugPrint('  ${row['name']} - Age: ${row['age']}');
  }

  // Update a record
  debugPrint('\nUpdating Carol to active...');
  await db.execute("UPDATE users SET active = true WHERE name = 'Carol White'");

  // Create products table with foreign key
  debugPrint('\nCreating products and orders tables...');
  await db.execute('''
    CREATE TABLE products (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      price REAL NOT NULL,
      stock INTEGER DEFAULT 0
    )
  ''');

  await db.execute('''
    CREATE TABLE orders (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id INTEGER NOT NULL,
      product_id INTEGER NOT NULL,
      quantity INTEGER NOT NULL,
      FOREIGN KEY (user_id) REFERENCES users(id),
      FOREIGN KEY (product_id) REFERENCES products(id)
    )
  ''');

  // Insert products
  await db.execute(
    "INSERT INTO products (name, price, stock) VALUES ('Laptop', 999.99, 10)",
  );
  await db.execute(
    "INSERT INTO products (name, price, stock) VALUES ('Mouse', 29.99, 50)",
  );

  // Insert orders
  await db.execute(
    "INSERT INTO orders (user_id, product_id, quantity) VALUES (1, 1, 1)",
  );
  await db.execute(
    "INSERT INTO orders (user_id, product_id, quantity) VALUES (2, 2, 2)",
  );

  // Check schema
  debugPrint('\nDatabase tables:');
  for (var tableName in db.tableNames) {
    final schema = db.getTableSchema(tableName);
    debugPrint('  $tableName (${schema!.columns.length} columns)');
  }

  // Note: Direct table access for composite indexes is internal
  // In this example, foreign key indexes are automatically created
  debugPrint('\nAutomatic indexes created for foreign keys');

  // Delete a record
  debugPrint('\nDeleting a user...');
  await db.execute("DELETE FROM users WHERE name = 'Carol White'");

  // Final count
  result = await db.execute('SELECT * FROM users');
  debugPrint('\nFinal user count: ${result.rows.length}');

  debugPrint('\n=== Example Complete ===');
}

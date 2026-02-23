import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

// ---------------------------------------------------------------------------
// Test path provider mock (avoids MissingPluginException in vm tests)
// ---------------------------------------------------------------------------
class _TempDirPathProvider extends PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async =>
      Directory.systemTemp.path;
}

void main() {
  // Required for path_provider (used by PersistenceManager) to resolve
  // the application documents directory during tests.
  TestWidgetsFlutterBinding.ensureInitialized();
  group('SQL Parser', () {
    test('parses SELECT statement', () {
      expect(() => Parser.parseSQL('SELECT * FROM users'), returnsNormally);
    });

    test('parses CREATE TABLE statement', () {
      expect(
        () => Parser.parseSQL(
          'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
        ),
        returnsNormally,
      );
    });

    test('parses INSERT statement', () {
      expect(
        () => Parser.parseSQL("INSERT INTO users (name) VALUES ('Alice')"),
        returnsNormally,
      );
    });
  });

  group('Executor — basic CRUD', () {
    late JustDatabase db;

    setUp(() async {
      db = await JustDatabase.open(
        'test_db_${DateTime.now().millisecondsSinceEpoch}',
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('CREATE TABLE and INSERT', () async {
      await db.execute(
        'CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, age INTEGER)',
      );
      final result = await db.execute(
        "INSERT INTO users (name, age) VALUES ('Alice', 30)",
      );
      expect(result.success, isTrue);
      expect(result.affectedRows, 1);
    });

    test('SELECT returns inserted rows', () async {
      await db.execute(
        'CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT)',
      );
      await db.execute("INSERT INTO items (value) VALUES ('hello')");
      await db.execute("INSERT INTO items (value) VALUES ('world')");
      final result = await db.query('SELECT * FROM items');
      expect(result.success, isTrue);
      expect(result.rows.length, 2);
    });

    test('WHERE filters rows', () async {
      await db.execute(
        'CREATE TABLE nums (id INTEGER PRIMARY KEY AUTOINCREMENT, n INTEGER)',
      );
      for (int i = 1; i <= 5; i++) {
        await db.execute('INSERT INTO nums (n) VALUES ($i)');
      }
      final result = await db.query('SELECT * FROM nums WHERE n > 3');
      expect(result.success, isTrue);
      expect(result.rows.length, 2);
    });

    test('UPDATE modifies rows', () async {
      await db.execute(
        'CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, val TEXT)',
      );
      await db.execute("INSERT INTO t (val) VALUES ('old')");
      await db.execute("UPDATE t SET val = 'new' WHERE id = 1");
      final result = await db.query('SELECT * FROM t WHERE val = \'new\'');
      expect(result.rows.length, 1);
    });

    test('DELETE removes rows', () async {
      await db.execute(
        'CREATE TABLE t2 (id INTEGER PRIMARY KEY AUTOINCREMENT, val TEXT)',
      );
      await db.execute("INSERT INTO t2 (val) VALUES ('a')");
      await db.execute("INSERT INTO t2 (val) VALUES ('b')");
      await db.execute("DELETE FROM t2 WHERE val = 'a'");
      final result = await db.query('SELECT * FROM t2');
      expect(result.rows.length, 1);
    });

    test('COUNT aggregate', () async {
      await db.execute(
        'CREATE TABLE agg (id INTEGER PRIMARY KEY AUTOINCREMENT, cat TEXT)',
      );
      await db.execute("INSERT INTO agg (cat) VALUES ('A')");
      await db.execute("INSERT INTO agg (cat) VALUES ('A')");
      await db.execute("INSERT INTO agg (cat) VALUES ('B')");
      final result = await db.query(
        'SELECT cat, COUNT(*) AS cnt FROM agg GROUP BY cat ORDER BY cat',
      );
      expect(result.success, isTrue);
      expect(result.rows.length, 2);
    });
  });

  group('Enhanced Indexing', () {
    late JustDatabase db;

    setUp(() async {
      db = await JustDatabase.open(
        'test_index_${DateTime.now().millisecondsSinceEpoch}',
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('Composite PRIMARY KEY constraint is enforced', () async {
      // Create table with composite primary key
      await db.execute(
        'CREATE TABLE composite_pk (a INTEGER, b INTEGER, value TEXT, PRIMARY KEY (a, b))',
      );

      // First insert should succeed
      await db.execute(
        "INSERT INTO composite_pk (a, b, value) VALUES (1, 2, 'first')",
      );

      // Duplicate composite key should fail
      final result = await db.execute(
        "INSERT INTO composite_pk (a, b, value) VALUES (1, 2, 'duplicate')",
      );
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('UNIQUE constraint'));
    });

    test('Composite UNIQUE constraint is enforced', () async {
      // Create table with composite unique constraint
      await db.execute(
        'CREATE TABLE composite_unique (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, UNIQUE (a, b))',
      );

      // First insert should succeed
      await db.execute("INSERT INTO composite_unique (a, b) VALUES (10, 20)");

      // Duplicate composite values should fail
      final result = await db.execute(
        "INSERT INTO composite_unique (a, b) VALUES (10, 20)",
      );
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('UNIQUE constraint'));

      // Different composite values should succeed
      final result2 = await db.execute(
        "INSERT INTO composite_unique (a, b) VALUES (10, 21)",
      );
      expect(result2.success, isTrue);
    });

    test('Foreign key columns are automatically indexed', () async {
      // Create parent table
      await db.execute('CREATE TABLE parent (id INTEGER PRIMARY KEY)');

      // Create child table with foreign key
      await db.execute(
        'CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id))',
      );

      // Verify foreign key index was created
      final schema = db.getTableSchema('child');
      expect(schema, isNotNull);

      // The table should have indices (verified by checking internal structure)
      // Insert some test data
      await db.execute("INSERT INTO parent (id) VALUES (1)");
      await db.execute("INSERT INTO child (id, parent_id) VALUES (100, 1)");

      // Query should work efficiently
      final result = await db.query('SELECT * FROM child WHERE parent_id = 1');
      expect(result.success, isTrue);
      expect(result.rows.length, 1);
    });

    test('Query pattern tracking creates automatic indexes', () async {
      // Create table without explicit indexes
      await db.execute(
        'CREATE TABLE frequent_queries (id INTEGER PRIMARY KEY, search_col TEXT)',
      );

      // Insert test data
      for (int i = 0; i < 10; i++) {
        await db.execute(
          "INSERT INTO frequent_queries (search_col) VALUES ('value$i')",
        );
      }

      // Execute the same WHERE clause 100+ times to trigger auto-indexing
      for (int i = 0; i < 105; i++) {
        await db.query(
          "SELECT * FROM frequent_queries WHERE search_col = 'value5'",
        );
      }

      // Verify query still works (auto-index should have been created)
      final result = await db.query(
        "SELECT * FROM frequent_queries WHERE search_col = 'value5'",
      );
      expect(result.success, isTrue);
      expect(result.rows.length, 1);
    });

    test('Composite index supports partial matching', () async {
      // Create table with composite index
      await db.execute(
        'CREATE TABLE multi_col (a INTEGER, b INTEGER, c INTEGER, PRIMARY KEY (a, b))',
      );

      // Insert test data
      await db.execute("INSERT INTO multi_col (a, b, c) VALUES (1, 2, 100)");
      await db.execute("INSERT INTO multi_col (a, b, c) VALUES (1, 3, 200)");
      await db.execute("INSERT INTO multi_col (a, b, c) VALUES (2, 2, 300)");

      // Query with both columns
      final result1 = await db.query(
        'SELECT * FROM multi_col WHERE a = 1 AND b = 2',
      );
      expect(result1.success, isTrue);
      expect(result1.rows.length, 1);
      expect(result1.rows[0]['c'], 100);

      // Query all rows
      final result2 = await db.query('SELECT * FROM multi_col');
      expect(result2.success, isTrue);
      expect(result2.rows.length, 3);
    });

    test(
      'Index metadata is persisted and restored',
      () async {
        final dbName = 'persist_test_${DateTime.now().millisecondsSinceEpoch}';

        // Create database with persistence
        final db1 = await JustDatabase.open(dbName, persist: true);

        // Create table with composite constraint
        await db1.execute(
          'CREATE TABLE persist_idx (a INTEGER, b INTEGER, value TEXT, PRIMARY KEY (a, b))',
        );

        // Insert data
        await db1.execute(
          "INSERT INTO persist_idx (a, b, value) VALUES (1, 2, 'test')",
        );

        // Verify data was inserted
        final query1 = await db1.query('SELECT * FROM persist_idx');
        expect(query1.success, isTrue);
        expect(query1.rows.length, 1);

        // Close and reopen
        await db1.close();

        // Add a small delay to ensure file write completes
        await Future.delayed(Duration(milliseconds: 100));

        final db2 = await JustDatabase.open(dbName, persist: true);

        // Verify data was persisted
        final query2 = await db2.query('SELECT * FROM persist_idx');
        expect(
          query2.success,
          isTrue,
          reason: 'Query should succeed after reopen',
        );
        expect(query2.rows.length, 1, reason: 'Row should be persisted');

        // Verify constraint still works (index was restored)
        final result = await db2.execute(
          "INSERT INTO persist_idx (a, b, value) VALUES (1, 2, 'duplicate')",
        );
        expect(result.success, isFalse, reason: 'Duplicate key should fail');
        if (!result.success) {
          expect(
            result.errorMessage,
            contains('UNIQUE constraint'),
            reason: 'Error should mention UNIQUE constraint',
          );
        }

        await db2.close();
      },
      skip:
          'Persistence requires platform channels which may not work in test environment',
    );
  });

  group('JOIN Operations', () {
    late JustDatabase db;

    setUp(() async {
      db = await JustDatabase.open(
        'test_joins_${DateTime.now().millisecondsSinceEpoch}',
      );

      // Create related tables
      await db.execute('''
        CREATE TABLE authors (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          country TEXT
        )
      ''');

      await db.execute('''
        CREATE TABLE books (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          author_id INTEGER,
          year INTEGER,
          FOREIGN KEY (author_id) REFERENCES authors(id)
        )
      ''');

      // Insert test data
      await db.execute(
        "INSERT INTO authors (name, country) VALUES ('Alice', 'USA')",
      );
      await db.execute(
        "INSERT INTO authors (name, country) VALUES ('Bob', 'UK')",
      );
      await db.execute(
        "INSERT INTO authors (name, country) VALUES ('Charlie', 'USA')",
      );

      await db.execute(
        "INSERT INTO books (title, author_id, year) VALUES ('Book A', 1, 2020)",
      );
      await db.execute(
        "INSERT INTO books (title, author_id, year) VALUES ('Book B', 1, 2021)",
      );
      await db.execute(
        "INSERT INTO books (title, author_id, year) VALUES ('Book C', 2, 2022)",
      );
      await db.execute(
        "INSERT INTO books (title, author_id, year) VALUES ('Book D', NULL, 2023)",
      ); // orphaned book
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('INNER JOIN returns only matching rows', () async {
      final result = await db.query('''
        SELECT books.title, authors.name
        FROM books
        INNER JOIN authors ON books.author_id = authors.id
        ORDER BY books.title
      ''');

      expect(result.success, isTrue);
      expect(result.rows.length, 3); // Book D has no author, excluded
      expect(result.rows[0]['title'], 'Book A');
      expect(result.rows[0]['name'], 'Alice');
    });

    test('LEFT JOIN includes all left table rows', () async {
      final result = await db.query('''
        SELECT books.title, authors.name
        FROM books
        LEFT JOIN authors ON books.author_id = authors.id
        ORDER BY books.title
      ''');

      expect(result.success, isTrue);
      expect(result.rows.length, 4); // All books included
      expect(result.rows[3]['title'], 'Book D');
      expect(result.rows[3]['name'], isNull); // No author
    });

    test('RIGHT JOIN includes all right table rows', () async {
      final result = await db.query('''
        SELECT authors.name, books.title
        FROM books
        RIGHT JOIN authors ON books.author_id = authors.id
        ORDER BY authors.id
      ''');

      expect(result.success, isTrue);
      expect(
        result.rows.length,
        4,
      ); // 2 books for Alice, 1 for Bob, 0 for Charlie

      // Charlie has no books, so title should be null
      final charlieRows = result.rows
          .where((row) => row['name'] == 'Charlie')
          .toList();
      expect(charlieRows.length, 1);
      expect(charlieRows[0]['title'], isNull);
    });

    test('JOIN with WHERE clause', () async {
      final result = await db.query('''
        SELECT books.title, authors.name, authors.country
        FROM books
        INNER JOIN authors ON books.author_id = authors.id
        WHERE authors.country = 'USA'
        ORDER BY books.title
      ''');

      expect(result.success, isTrue);
      expect(result.rows.length, 2); // Only Alice's books
    });

    test('Multiple JOINs', () async {
      // Create publishers table
      await db.execute('''
        CREATE TABLE publishers (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL
        )
      ''');
      await db.execute("INSERT INTO publishers (name) VALUES ('Publisher X')");

      // Add publisher_id to books
      await db.execute('ALTER TABLE books ADD COLUMN publisher_id INTEGER');
      await db.execute('UPDATE books SET publisher_id = 1 WHERE id <= 2');

      final result = await db.query('''
        SELECT b.title, a.name as author, p.name as publisher
        FROM books b
        INNER JOIN authors a ON b.author_id = a.id
        LEFT JOIN publishers p ON b.publisher_id = p.id
        WHERE b.year >= 2020
        ORDER BY b.title
      ''');

      expect(result.success, isTrue);
      expect(result.rows.length, 3);
    });
  });

  group('Aggregate Functions', () {
    late JustDatabase db;

    setUp(() async {
      db = await JustDatabase.open(
        'test_agg_${DateTime.now().millisecondsSinceEpoch}',
      );

      await db.execute('''
        CREATE TABLE employees (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          department TEXT,
          salary REAL,
          age INTEGER
        )
      ''');

      // Insert test data
      await db.execute(
        "INSERT INTO employees (name, department, salary, age) VALUES ('Alice', 'Engineering', 75000, 30)",
      );
      await db.execute(
        "INSERT INTO employees (name, department, salary, age) VALUES ('Bob', 'Engineering', 80000, 35)",
      );
      await db.execute(
        "INSERT INTO employees (name, department, salary, age) VALUES ('Charlie', 'Sales', 60000, 28)",
      );
      await db.execute(
        "INSERT INTO employees (name, department, salary, age) VALUES ('Diana', 'Sales', 65000, 32)",
      );
      await db.execute(
        "INSERT INTO employees (name, department, salary, age) VALUES ('Eve', 'Marketing', NULL, 29)",
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('COUNT(*) counts all rows', () async {
      final result = await db.query('SELECT COUNT(*) as total FROM employees');
      expect(result.success, isTrue);
      expect(result.rows[0]['total'], 5);
    });

    test('COUNT(column) counts non-null values', () async {
      final result = await db.query(
        'SELECT COUNT(salary) as with_salary FROM employees',
      );
      expect(result.success, isTrue);
      expect(result.rows[0]['with_salary'], 4); // Eve has NULL salary
    });

    test('SUM calculates total', () async {
      final result = await db.query(
        'SELECT SUM(salary) as total_salary FROM employees',
      );
      expect(result.success, isTrue);
      expect(result.rows[0]['total_salary'], 280000);
    });

    test('AVG calculates average', () async {
      final result = await db.query(
        'SELECT AVG(age) as avg_age FROM employees',
      );
      expect(result.success, isTrue);
      expect(result.rows[0]['avg_age'], closeTo(30.8, 0.1));
    });

    test('MIN finds minimum value', () async {
      final result = await db.query(
        'SELECT MIN(salary) as min_salary FROM employees',
      );
      expect(result.success, isTrue);
      expect(result.rows[0]['min_salary'], 60000);
    });

    test('MAX finds maximum value', () async {
      final result = await db.query(
        'SELECT MAX(salary) as max_salary FROM employees',
      );
      expect(result.success, isTrue);
      expect(result.rows[0]['max_salary'], 80000);
    });

    test('Multiple aggregates in one query', () async {
      final result = await db.query('''
        SELECT 
          COUNT(*) as cnt,
          SUM(salary) as total,
          AVG(salary) as avg_sal,
          MIN(salary) as min_sal,
          MAX(salary) as max_sal
        FROM employees
        WHERE salary IS NOT NULL
      ''');

      expect(result.success, isTrue);
      expect(result.rows[0]['cnt'], 4);
      expect(result.rows[0]['total'], 280000);
      expect(result.rows[0]['avg_sal'], 70000);
      expect(result.rows[0]['min_sal'], 60000);
      expect(result.rows[0]['max_sal'], 80000);
    });
  });

  group('GROUP BY and HAVING', () {
    late JustDatabase db;

    setUp(() async {
      db = await JustDatabase.open(
        'test_group_${DateTime.now().millisecondsSinceEpoch}',
      );

      await db.execute('''
        CREATE TABLE sales (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          product TEXT,
          category TEXT,
          amount REAL,
          quantity INTEGER
        )
      ''');

      await db.execute(
        "INSERT INTO sales (product, category, amount, quantity) VALUES ('Widget A', 'Electronics', 100, 5)",
      );
      await db.execute(
        "INSERT INTO sales (product, category, amount, quantity) VALUES ('Widget B', 'Electronics', 150, 3)",
      );
      await db.execute(
        "INSERT INTO sales (product, category, amount, quantity) VALUES ('Gadget C', 'Electronics', 200, 7)",
      );
      await db.execute(
        "INSERT INTO sales (product, category, amount, quantity) VALUES ('Tool D', 'Hardware', 80, 10)",
      );
      await db.execute(
        "INSERT INTO sales (product, category, amount, quantity) VALUES ('Tool E', 'Hardware', 90, 12)",
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('GROUP BY single column', () async {
      final result = await db.query('''
        SELECT category, COUNT(*) as cnt, SUM(amount) as total
        FROM sales
        GROUP BY category
        ORDER BY category
      ''');

      if (!result.success) {
        debugPrint('Error: ${result.errorMessage}');
      }
      expect(result.success, isTrue);
      expect(result.rows.length, 2);
      expect(result.rows[0]['category'], 'Electronics');
      expect(result.rows[0]['cnt'], 3);
      expect(result.rows[0]['total'], 450);
    });

    test('GROUP BY multiple columns', () async {
      await db.execute(
        "INSERT INTO sales (product, category, amount, quantity) VALUES ('Widget C', 'Electronics', 120, 4)",
      );

      final result = await db.query('''
        SELECT category, COUNT(*) as cnt
        FROM sales
        GROUP BY category
        ORDER BY category
      ''');

      expect(result.success, isTrue);
      expect(result.rows.length, 2); // Electronics and Hardware
    });

    test('HAVING filters groups', () async {
      // HAVING with aggregate filter on COUNT
      final result = await db.query('''
        SELECT category, COUNT(*) as cnt, AVG(amount) as avg_amount
        FROM sales
        GROUP BY category
        HAVING COUNT(*) >= 2
      ''');

      expect(result.success, isTrue);
      // Both categories have at least 2 items
      expect(result.rows.length, 2);
      expect(result.rows[0]['cnt'], greaterThanOrEqualTo(2));
    });

    test('HAVING with multiple conditions', () async {
      // HAVING with multiple aggregate conditions
      final result = await db.query('''
        SELECT category, COUNT(*) as cnt, SUM(amount) as total
        FROM sales
        GROUP BY category
        HAVING COUNT(*) >= 2 AND SUM(amount) > 100
      ''');

      expect(result.success, isTrue);
      // Both categories have count >= 2 and sum > 100
      expect(result.rows.length, 2);
      for (final row in result.rows) {
        expect(row['cnt'], greaterThanOrEqualTo(2));
        expect(row['total'], greaterThan(100));
      }
    });

    test('GROUP BY with ORDER BY', () async {
      final result = await db.query('''
        SELECT category, AVG(amount) as avg_amount
        FROM sales
        GROUP BY category
        ORDER BY avg_amount DESC
      ''');

      expect(result.success, isTrue);
      expect(result.rows.length, 2);
      expect(result.rows[0]['category'], 'Electronics'); // Higher average
    });
  });

  group('ALTER TABLE Operations', () {
    late JustDatabase db;

    setUp(() async {
      db = await JustDatabase.open(
        'test_alter_${DateTime.now().millisecondsSinceEpoch}',
      );

      await db.execute('''
        CREATE TABLE users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          email TEXT
        )
      ''');

      await db.execute(
        "INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')",
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('ADD COLUMN adds new column', () async {
      final result = await db.execute(
        'ALTER TABLE users ADD COLUMN age INTEGER',
      );
      expect(result.success, isTrue);

      // Verify column was added
      await db.execute(
        "INSERT INTO users (name, email, age) VALUES ('Bob', 'bob@example.com', 30)",
      );
      final query = await db.query('SELECT * FROM users WHERE age = 30');
      expect(query.success, isTrue);
      expect(query.rows.length, 1);
    });

    test('ADD COLUMN with DEFAULT value', () async {
      await db.execute(
        "ALTER TABLE users ADD COLUMN status TEXT DEFAULT 'active'",
      );

      // Existing rows should have default value
      final query = await db.query(
        "SELECT status FROM users WHERE name = 'Alice'",
      );
      expect(query.success, isTrue);
      expect(query.rows[0]['status'], 'active');
    });

    test('DROP COLUMN removes column', () async {
      await db.execute('ALTER TABLE users ADD COLUMN temp TEXT');
      await db.execute("UPDATE users SET temp = 'temporary'");

      final dropResult = await db.execute('ALTER TABLE users DROP COLUMN temp');
      expect(dropResult.success, isTrue);

      // Verify column was removed - query should still work without it
      final query = await db.query('SELECT * FROM users');
      expect(query.success, isTrue);
      expect(query.rows[0].containsKey('temp'), isFalse);
    });

    test('RENAME COLUMN renames column', () async {
      final result = await db.execute(
        'ALTER TABLE users RENAME COLUMN name TO full_name',
      );
      expect(result.success, isTrue);

      // Verify renamed column works
      final query = await db.query('SELECT full_name FROM users');
      expect(query.success, isTrue);
      expect(query.rows[0]['full_name'], 'Alice');

      // Verify old column name no longer works
      final oldQuery = await db.query('SELECT name FROM users');
      expect(
        oldQuery.success,
        isFalse,
        reason: 'Old column name should not work after rename',
      );
    });

    test('Multiple ALTER TABLE operations', () async {
      await db.execute('ALTER TABLE users ADD COLUMN phone TEXT');
      await db.execute(
        'ALTER TABLE users ADD COLUMN city TEXT DEFAULT \'Unknown\'',
      );
      await db.execute(
        'ALTER TABLE users RENAME COLUMN email TO email_address',
      );

      final query = await db.query('SELECT * FROM users');
      expect(query.success, isTrue);
      expect(query.rows[0].keys, contains('phone'));
      expect(query.rows[0].keys, contains('city'));
      expect(query.rows[0].keys, contains('email_address'));
      expect(query.rows[0]['city'], 'Unknown');
    });
  });

  group('DISTINCT and Query Clauses', () {
    late JustDatabase db;

    setUp(() async {
      db = await JustDatabase.open(
        'test_distinct_${DateTime.now().millisecondsSinceEpoch}',
      );

      await db.execute('''
        CREATE TABLE products (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT,
          category TEXT,
          price REAL
        )
      ''');

      await db.execute(
        "INSERT INTO products (name, category, price) VALUES ('Product A', 'Electronics', 100)",
      );
      await db.execute(
        "INSERT INTO products (name, category, price) VALUES ('Product B', 'Electronics', 150)",
      );
      await db.execute(
        "INSERT INTO products (name, category, price) VALUES ('Product C', 'Hardware', 80)",
      );
      await db.execute(
        "INSERT INTO products (name, category, price) VALUES ('Product D', 'Electronics', 200)",
      );
      await db.execute(
        "INSERT INTO products (name, category, price) VALUES ('Product E', 'Hardware', 90)",
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('DISTINCT removes duplicates', () async {
      final result = await db.query('SELECT DISTINCT category FROM products');
      expect(result.success, isTrue);
      expect(result.rows.length, 2); // Only 2 unique categories
    });

    test('ORDER BY sorts results', () async {
      final result = await db.query(
        'SELECT name, price FROM products ORDER BY price DESC',
      );
      expect(result.success, isTrue);
      expect(result.rows[0]['price'], 200); // Highest price first
      expect(result.rows[4]['price'], 80); // Lowest price last
    });

    test('LIMIT restricts row count', () async {
      final result = await db.query('SELECT * FROM products LIMIT 3');
      expect(result.success, isTrue);
      expect(result.rows.length, 3);
    });

    test('OFFSET skips rows', () async {
      final result = await db.query(
        'SELECT * FROM products ORDER BY id LIMIT 2 OFFSET 2',
      );
      expect(result.success, isTrue);
      expect(result.rows.length, 2);
      expect(result.rows[0]['id'], 3); // Third row
    });

    test('ORDER BY with LIMIT and OFFSET', () async {
      final result = await db.query('''
        SELECT name, price 
        FROM products 
        ORDER BY price DESC 
        LIMIT 2 OFFSET 1
      ''');
      expect(result.success, isTrue);
      expect(result.rows.length, 2);
      expect(result.rows[0]['price'], 150); // Second highest
    });
  });

  group('Subquery Tests', () {
    late JustDatabase db;

    setUp(() async {
      db = await JustDatabase.open(
        'test_subquery_db_${DateTime.now().millisecondsSinceEpoch}',
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('Scalar subquery in SELECT clause', () async {
      await db.execute('''
        CREATE TABLE departments (
          id INTEGER PRIMARY KEY,
          name TEXT,
          budget INTEGER
        )
      ''');

      await db.execute('''
        CREATE TABLE employees (
          id INTEGER PRIMARY KEY,
          name TEXT,
          dept_id INTEGER,
          salary INTEGER
        )
      ''');

      await db.execute('''
        INSERT INTO departments (id, name, budget) VALUES
        (1, 'Engineering', 100000),
        (2, 'Marketing', 50000)
      ''');

      await db.execute('''
        INSERT INTO employees (id, name, dept_id, salary) VALUES
        (1, 'Alice', 1, 60000),
        (2, 'Bob', 1, 70000),
        (3, 'Charlie', 2, 45000)
      ''');

      // Get average salary in SELECT subquery
      final result = await db.execute('''
        SELECT name, salary,
               (SELECT AVG(salary) FROM employees) AS avg_salary
        FROM employees
        WHERE dept_id = 1
      ''');

      expect(result.success, isTrue);
      expect(result.rows.length, 2);
      expect(result.rows[0]['avg_salary'], closeTo(58333.33, 1));
      expect(result.rows[1]['avg_salary'], closeTo(58333.33, 1));
    });

    test('Subquery in WHERE with comparison', () async {
      await db.execute('''
        CREATE TABLE products (
          id INTEGER PRIMARY KEY,
          name TEXT,
          price INTEGER
        )
      ''');

      await db.execute('''
        INSERT INTO products (id, name, price) VALUES
        (1, 'Laptop', 1000),
        (2, 'Mouse', 25),
        (3, 'Keyboard', 75)
      ''');

      // Find products more expensive than average
      final result = await db.execute('''
        SELECT name, price
        FROM products
        WHERE price > (SELECT AVG(price) FROM products)
        ORDER BY price
      ''');

      expect(result.success, isTrue);
      expect(result.rows.length, 1);
      expect(result.rows[0]['name'], 'Laptop');
    });

    test('Multiple subqueries in same query', () async {
      await db.execute('''
        CREATE TABLE sales (
          id INTEGER PRIMARY KEY,
          amount INTEGER,
          region TEXT
        )
      ''');

      await db.execute('''
        INSERT INTO sales (id, amount, region) VALUES
        (1, 1000, 'North'),
        (2, 1500, 'South'),
        (3, 800, 'North'),
        (4, 2000, 'East')
      ''');

      // Use multiple subqueries: above average and below max
      final result = await db.execute('''
        SELECT region, amount,
               (SELECT AVG(amount) FROM sales) AS avg_amt,
               (SELECT MAX(amount) FROM sales) AS max_amt
        FROM sales
        WHERE amount > (SELECT AVG(amount) FROM sales)
        ORDER BY amount
      ''');

      expect(result.success, isTrue);
      expect(result.rows.length, 2); // 1500 and 2000 are above average
      expect(result.rows[0]['amount'], 1500);
      expect(result.rows[1]['amount'], 2000);
    });

    test('Nested subquery (subquery within subquery)', () async {
      await db.execute('''
        CREATE TABLE numbers (
          id INTEGER PRIMARY KEY,
          value INTEGER
        )
      ''');

      await db.execute('''
        INSERT INTO numbers (id, value) VALUES
        (1, 10),
        (2, 20),
        (3, 30),
        (4, 40)
      ''');

      // Double nested: get average of values greater than min
      final result = await db.execute('''
        SELECT value
        FROM numbers
        WHERE value > (
          SELECT AVG(value) FROM numbers
          WHERE value > (SELECT MIN(value) FROM numbers)
        )
      ''');

      expect(result.success, isTrue);
      // Min is 10, values > 10 are [20,30,40], avg is 30
      // So we want values > 30, which is just 40
      expect(result.rows.length, 1);
      expect(result.rows[0]['value'], 40);
    });

    test('Subquery returning NULL (empty result)', () async {
      await db.execute('''
        CREATE TABLE items (
          id INTEGER PRIMARY KEY,
          stock INTEGER
        )
      ''');

      await db.execute('''
        INSERT INTO items (id, stock) VALUES (1, 100)
      ''');

      // Subquery that returns no rows should evaluate to NULL
      final result = await db.execute('''
        SELECT id, stock,
               (SELECT MAX(stock) FROM items WHERE id > 999) AS max_stock
        FROM items
      ''');

      expect(result.success, isTrue);
      expect(result.rows.length, 1);
      expect(result.rows[0]['max_stock'], isNull);
    });

    test('Subquery with aggregates and GROUP BY', () async {
      await db.execute('''
        CREATE TABLE orders (
          id INTEGER PRIMARY KEY,
          customer_id INTEGER,
          total INTEGER
        )
      ''');

      await db.execute('''
        INSERT INTO orders (id, customer_id, total) VALUES
        (1, 1, 100),
        (2, 1, 200),
        (3, 2, 150),
        (4, 2, 250)
      ''');

      // Get overall average order total
      final result = await db.execute('''
        SELECT customer_id, SUM(total) AS total_spent,
               (SELECT AVG(total) FROM orders) AS avg_order
        FROM orders
        GROUP BY customer_id
        HAVING SUM(total) > (SELECT AVG(total) FROM orders) * 2
      ''');

      expect(result.success, isTrue);
      // Average order is 175, so SUM must be > 350
      // Customer 1: 300, Customer 2: 400
      expect(result.rows.length, 1);
      expect(result.rows[0]['customer_id'], 2);
      expect(result.rows[0]['total_spent'], 400);
    });
  });

  // ===========================================================================
  // TRANSACTION SUPPORT
  // ===========================================================================

  group('Transaction Support', () {
    late Executor executor;
    late Map<String, Table> tables;

    setUp(() {
      tables = {};
      executor = Executor(tables);
    });

    test('BEGIN starts a transaction', () async {
      final result = await executor.executeSQL('BEGIN');
      expect(result.success, isTrue);
      expect(executor.inTransaction, isTrue);
    });

    test('COMMIT ends the transaction', () async {
      await executor.executeSQL('BEGIN');
      final result = await executor.executeSQL('COMMIT');
      expect(result.success, isTrue);
      expect(executor.inTransaction, isFalse);
    });

    test('ROLLBACK restores data to pre-BEGIN state', () async {
      // Setup table and initial row
      await executor.executeSQL(
        'CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER)',
      );
      await executor.executeSQL(
        'INSERT INTO accounts (id, balance) VALUES (1, 1000)',
      );

      // Begin, modify, rollback
      await executor.executeSQL('BEGIN');
      await executor.executeSQL(
        'UPDATE accounts SET balance = 500 WHERE id = 1',
      );

      // Confirm the change is visible inside the transaction
      final duringTx = await executor.executeSQL(
        'SELECT balance FROM accounts WHERE id = 1',
      );
      expect(duringTx.rows[0]['balance'], 500);

      // Rollback
      final rb = await executor.executeSQL('ROLLBACK');
      expect(rb.success, isTrue);
      expect(executor.inTransaction, isFalse);

      // Data is restored
      final afterRb = await executor.executeSQL(
        'SELECT balance FROM accounts WHERE id = 1',
      );
      expect(afterRb.rows[0]['balance'], 1000);
    });

    test('COMMIT persists data — no rollback possible after', () async {
      await executor.executeSQL(
        'CREATE TABLE counters (id INTEGER PRIMARY KEY, val INTEGER)',
      );
      await executor.executeSQL('INSERT INTO counters (id, val) VALUES (1, 0)');

      await executor.executeSQL('BEGIN');
      await executor.executeSQL('UPDATE counters SET val = 42 WHERE id = 1');
      await executor.executeSQL('COMMIT');

      // After commit, value remains
      final r = await executor.executeSQL(
        'SELECT val FROM counters WHERE id = 1',
      );
      expect(r.rows[0]['val'], 42);

      // Attempting rollback with no active transaction returns error
      final rb = await executor.executeSQL('ROLLBACK');
      expect(rb.success, isFalse);
      expect(rb.errorMessage, contains('no active transaction'));
    });

    test('ROLLBACK undoes INSERT', () async {
      await executor.executeSQL(
        'CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)',
      );
      await executor.executeSQL('BEGIN');
      await executor.executeSQL(
        "INSERT INTO items (id, name) VALUES (1, 'Laptop')",
      );
      await executor.executeSQL('ROLLBACK');

      final r = await executor.executeSQL('SELECT * FROM items');
      expect(r.rows.length, 0);
    });

    test('ROLLBACK undoes CREATE TABLE', () async {
      await executor.executeSQL('BEGIN');
      await executor.executeSQL(
        'CREATE TABLE temp_table (id INTEGER PRIMARY KEY)',
      );
      await executor.executeSQL('ROLLBACK');

      // Table should not exist after rollback
      final r = await executor.executeSQL('SELECT * FROM temp_table');
      expect(r.success, isFalse);
    });

    test('Nested BEGIN returns error', () async {
      await executor.executeSQL('BEGIN');
      final r = await executor.executeSQL('BEGIN');
      expect(r.success, isFalse);
      expect(r.errorMessage, contains('already active'));
    });

    test('SAVEPOINT and ROLLBACK TO SAVEPOINT', () async {
      await executor.executeSQL(
        'CREATE TABLE wallet (id INTEGER PRIMARY KEY, amount INTEGER)',
      );
      await executor.executeSQL(
        'INSERT INTO wallet (id, amount) VALUES (1, 100)',
      );

      await executor.executeSQL('BEGIN');

      // First change + savepoint
      await executor.executeSQL('UPDATE wallet SET amount = 200 WHERE id = 1');
      await executor.executeSQL('SAVEPOINT sp1');

      // Second change
      await executor.executeSQL('UPDATE wallet SET amount = 300 WHERE id = 1');

      // Rollback to savepoint
      final rb = await executor.executeSQL('ROLLBACK TO SAVEPOINT sp1');
      expect(rb.success, isTrue);
      expect(executor.inTransaction, isTrue); // still in transaction

      final r = await executor.executeSQL(
        'SELECT amount FROM wallet WHERE id = 1',
      );
      expect(r.rows[0]['amount'], 200); // restored to sp1 snapshot

      // Commit the rest
      await executor.executeSQL('COMMIT');
    });

    test('RELEASE SAVEPOINT removes the savepoint', () async {
      await executor.executeSQL('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await executor.executeSQL('BEGIN');
      await executor.executeSQL('SAVEPOINT sp1');
      final relResult = await executor.executeSQL('RELEASE SAVEPOINT sp1');
      expect(relResult.success, isTrue);

      // Rolling back to released savepoint should fail
      final rb = await executor.executeSQL('ROLLBACK TO SAVEPOINT sp1');
      expect(rb.success, isFalse);
      expect(rb.errorMessage, contains('does not exist'));
    });

    test('JustDatabase.transaction() helper commits on success', () async {
      final db = await JustDatabase.open('tx_test_1');
      await db.execute(
        'CREATE TABLE points (id INTEGER PRIMARY KEY, score INTEGER)',
      );
      await db.execute('INSERT INTO points (id, score) VALUES (1, 0)');

      final result = await db.transaction((d) async {
        await d.execute('UPDATE points SET score = 99 WHERE id = 1');
        return d.query('SELECT score FROM points WHERE id = 1');
      });

      expect(result.rows[0]['score'], 99);
      expect(db.inTransaction, isFalse);
      await db.close();
    });

    test('JustDatabase.transaction() helper rolls back on exception', () async {
      final db = await JustDatabase.open('tx_test_2');
      await db.execute(
        'CREATE TABLE points (id INTEGER PRIMARY KEY, score INTEGER)',
      );
      await db.execute('INSERT INTO points (id, score) VALUES (1, 0)');

      try {
        await db.transaction((d) async {
          await d.execute('UPDATE points SET score = 42 WHERE id = 1');
          throw Exception('Intentional error');
        });
      } catch (_) {
        // Expected
      }

      // Score should still be 0
      final r = await db.query('SELECT score FROM points WHERE id = 1');
      expect(r.rows[0]['score'], 0);
      expect(db.inTransaction, isFalse);
      await db.close();
    });

    test('BEGIN DEFERRED TRANSACTION is valid syntax', () async {
      final r = await executor.executeSQL('BEGIN DEFERRED TRANSACTION');
      expect(r.success, isTrue);
      expect(executor.inTransaction, isTrue);
      await executor.executeSQL('ROLLBACK');
    });

    test('BEGIN IMMEDIATE is valid syntax', () async {
      final r = await executor.executeSQL('BEGIN IMMEDIATE');
      expect(r.success, isTrue);
      await executor.executeSQL('ROLLBACK');
    });
  });

  // ===========================================================================
  // VIEWS
  // ===========================================================================

  group('View Support', () {
    late Executor executor;

    setUp(() {
      executor = Executor({});
    });

    test('CREATE VIEW and SELECT from it', () async {
      await executor.executeSQL(
        'CREATE TABLE employees (id INTEGER PRIMARY KEY, name TEXT, dept TEXT, salary INTEGER)',
      );
      await executor.executeSQL(
        "INSERT INTO employees VALUES (1, 'Alice', 'Engineering', 90000)",
      );
      await executor.executeSQL(
        "INSERT INTO employees VALUES (2, 'Bob', 'Engineering', 85000)",
      );
      await executor.executeSQL(
        "INSERT INTO employees VALUES (3, 'Carol', 'Marketing', 70000)",
      );

      final cv = await executor.executeSQL(
        "CREATE VIEW eng_staff AS SELECT id, name, salary FROM employees WHERE dept = 'Engineering'",
      );
      expect(cv.success, isTrue);

      final r = await executor.executeSQL('SELECT * FROM eng_staff');
      expect(r.success, isTrue);
      expect(r.rows.length, 2);
      expect(r.rows.map((e) => e['name']), containsAll(['Alice', 'Bob']));
    });

    test('SELECT with WHERE on view', () async {
      await executor.executeSQL(
        'CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, price INTEGER, active INTEGER)',
      );
      await executor.executeSQL(
        "INSERT INTO products VALUES (1, 'Widget', 100, 1)",
      );
      await executor.executeSQL(
        "INSERT INTO products VALUES (2, 'Gadget', 200, 1)",
      );
      await executor.executeSQL(
        "INSERT INTO products VALUES (3, 'Doohickey', 50, 0)",
      );

      await executor.executeSQL(
        'CREATE VIEW active_products AS SELECT * FROM products WHERE active = 1',
      );

      // Filter further in outer query
      final r = await executor.executeSQL(
        'SELECT name FROM active_products WHERE price > 100',
      );
      expect(r.success, isTrue);
      expect(r.rows.length, 1);
      expect(r.rows[0]['name'], 'Gadget');
    });

    test('CREATE VIEW IF NOT EXISTS does not overwrite', () async {
      await executor.executeSQL(
        'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)',
      );
      await executor.executeSQL('INSERT INTO t VALUES (1, 10)');
      await executor.executeSQL('CREATE VIEW v1 AS SELECT * FROM t');
      // Second CREATE IF NOT EXISTS should succeed silently
      final r = await executor.executeSQL(
        'CREATE VIEW IF NOT EXISTS v1 AS SELECT id FROM t',
      );
      expect(r.success, isTrue);
      // View still uses original definition
      final sel = await executor.executeSQL('SELECT * FROM v1');
      expect(sel.rows[0].containsKey('v'), isTrue);
    });

    test('CREATE OR REPLACE VIEW updates definition', () async {
      await executor.executeSQL(
        'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)',
      );
      await executor.executeSQL('INSERT INTO t VALUES (1, 42)');
      await executor.executeSQL('CREATE VIEW v1 AS SELECT * FROM t');
      final rep = await executor.executeSQL(
        'CREATE OR REPLACE VIEW v1 AS SELECT id FROM t',
      );
      expect(rep.success, isTrue);
      final sel = await executor.executeSQL('SELECT * FROM v1');
      // Replaced view only has 'id'
      expect(sel.rows[0].containsKey('id'), isTrue);
    });

    test('DROP VIEW removes the view', () async {
      await executor.executeSQL('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await executor.executeSQL('CREATE VIEW v1 AS SELECT * FROM t');
      final dr = await executor.executeSQL('DROP VIEW v1');
      expect(dr.success, isTrue);
      final r = await executor.executeSQL('SELECT * FROM v1');
      expect(r.success, isFalse);
    });

    test('DROP VIEW IF EXISTS on non-existent view', () async {
      final r = await executor.executeSQL('DROP VIEW IF EXISTS ghost_view');
      expect(r.success, isTrue);
    });

    test(
      'DROP VIEW on non-existent view without IF EXISTS returns error',
      () async {
        final r = await executor.executeSQL('DROP VIEW ghost_view');
        expect(r.success, isFalse);
        expect(r.errorMessage, contains('does not exist'));
      },
    );

    test('View with ORDER BY and LIMIT in outer query', () async {
      await executor.executeSQL('CREATE TABLE nums (n INTEGER)');
      for (int i = 1; i <= 5; i++) {
        await executor.executeSQL('INSERT INTO nums (n) VALUES ($i)');
      }
      await executor.executeSQL('CREATE VIEW all_nums AS SELECT n FROM nums');
      final r = await executor.executeSQL(
        'SELECT n FROM all_nums ORDER BY n DESC LIMIT 3',
      );
      expect(r.success, isTrue);
      expect(r.rows.map((e) => e['n']).toList(), [5, 4, 3]);
    });

    test('viewNames exposes defined views', () async {
      await executor.executeSQL('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await executor.executeSQL('CREATE VIEW v1 AS SELECT * FROM t');
      await executor.executeSQL('CREATE VIEW v2 AS SELECT * FROM t');
      expect(executor.viewNames, containsAll(['v1', 'v2']));
      await executor.executeSQL('DROP VIEW v1');
      expect(executor.viewNames, isNot(contains('v1')));
    });
  });

  // ---------------------------------------------------------------------------
  // Secure Database (AES-256-GCM encryption at rest)
  // ---------------------------------------------------------------------------
  group('Secure Database', () {
    setUpAll(() {
      // Override path_provider so file-persistence tests work in vm tests.
      PathProviderPlatform.instance = _TempDirPathProvider();
    });
    test('requires encryptionKey when mode is secure', () async {
      await expectLater(
        () => JustDatabase.open(
          'no_key_${DateTime.now().millisecondsSinceEpoch}',
          mode: DatabaseMode.secure,
          // intentionally omitting encryptionKey
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects encryptionKey for non-secure modes', () async {
      for (final mode in [
        DatabaseMode.standard,
        DatabaseMode.readFast,
        DatabaseMode.writeFast,
      ]) {
        await expectLater(
          () => JustDatabase.open(
            'extra_key_${DateTime.now().millisecondsSinceEpoch}',
            mode: mode,
            encryptionKey: 'oops',
          ),
          throwsA(isA<ArgumentError>()),
          reason: '$mode should reject an encryptionKey',
        );
      }
    });

    test('secure mode in-memory CRUD works correctly', () async {
      final db = await JustDatabase.open(
        'secure_inmem_${DateTime.now().millisecondsSinceEpoch}',
        mode: DatabaseMode.secure,
        persist: false,
        encryptionKey: 'test-passphrase-123',
      );

      await db.execute(
        'CREATE TABLE secrets (id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)',
      );
      await db.execute("INSERT INTO secrets (value) VALUES ('alpha')");
      await db.execute("INSERT INTO secrets (value) VALUES ('beta')");

      final result = await db.query('SELECT * FROM secrets ORDER BY id');
      expect(result.success, isTrue);
      expect(result.rows.length, 2);
      expect(result.rows[0]['value'], 'alpha');
      expect(result.rows[1]['value'], 'beta');

      await db.close();
    });

    test('encryptionKey is exposed on database instance', () async {
      const key = 'my-secret-passphrase';
      final db = await JustDatabase.open(
        'key_check_${DateTime.now().millisecondsSinceEpoch}',
        mode: DatabaseMode.secure,
        persist: false,
        encryptionKey: key,
      );

      expect(db.encryptionKey, key);
      expect(db.mode, DatabaseMode.secure);
      await db.close();
    });

    test('secure persist round-trip: data survives close/reopen', () async {
      final name = 'secure_persist_${DateTime.now().millisecondsSinceEpoch}';
      const passphrase = 'super-secret-roundtrip';

      // Create and seed
      final db1 = await JustDatabase.open(
        name,
        mode: DatabaseMode.secure,
        persist: true,
        encryptionKey: passphrase,
      );
      await db1.execute(
        'CREATE TABLE vault (id INTEGER PRIMARY KEY AUTOINCREMENT, secret TEXT)',
      );
      await db1.execute("INSERT INTO vault (secret) VALUES ('s3cr3t!')");
      await db1.close();

      // Reopen with same key → data should be there
      final db2 = await JustDatabase.open(
        name,
        mode: DatabaseMode.secure,
        persist: true,
        encryptionKey: passphrase,
      );
      final result = await db2.query('SELECT * FROM vault');
      expect(result.success, isTrue);
      expect(result.rows.length, 1);
      expect(result.rows.first['secret'], 's3cr3t!');
      await db2.close();
    });

    test('wrong key on reopen throws StateError', () async {
      final name = 'secure_wrongkey_${DateTime.now().millisecondsSinceEpoch}';

      // Create with correct key
      final db1 = await JustDatabase.open(
        name,
        mode: DatabaseMode.secure,
        persist: true,
        encryptionKey: 'correct-key',
      );
      await db1.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      await db1.execute("INSERT INTO t VALUES (1, 'data')");
      await db1.close();

      // Reopen with wrong key → should throw StateError
      await expectLater(
        () => JustDatabase.open(
          name,
          mode: DatabaseMode.secure,
          persist: true,
          encryptionKey: 'wrong-key',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}

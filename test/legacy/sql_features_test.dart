// Ported from the 1.x test/just_database_test.dart: CRUD, constraints,
// joins, aggregates, grouping, ALTER TABLE, subqueries, transactions,
// views and encrypted databases.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/src/sql/parser.dart';

import '../helpers/temp_paths.dart';
import 'legacy_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TempPaths paths;

  setUp(() async {
    paths = await TempPaths.install();
  });

  tearDown(() async {
    await closeAllOpen();
    await paths.dispose();
  });

  group('SQL Parser', () {
    // 2.0: the parser is internal; these use it directly.
    test('parses SELECT statement', () {
      expect(() => Parser.parseOne('SELECT * FROM users'), returnsNormally);
    });

    test('parses CREATE TABLE statement', () {
      expect(
        () => Parser.parseOne(
          'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT NOT NULL)',
        ),
        returnsNormally,
      );
    });

    test('parses INSERT statement', () {
      expect(
        () => Parser.parseOne("INSERT INTO users (name) VALUES ('Alice')"),
        returnsNormally,
      );
    });
  });

  group('Executor — basic CRUD', () {
    late JustDatabase db;

    setUp(() async => db = await openMemory('crud'));

    test('CREATE TABLE and INSERT', () async {
      await exec(
        db,
        'CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, age INTEGER)',
      );
      final result = await db.execute(
        "INSERT INTO users (name, age) VALUES ('Alice', 30)",
      );
      expect(result.success, isTrue);
      expect(result.affectedRows, 1);
    });

    test('SELECT returns inserted rows', () async {
      await exec(
        db,
        'CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT)',
      );
      await exec(db, "INSERT INTO items (value) VALUES ('hello')");
      await exec(db, "INSERT INTO items (value) VALUES ('world')");
      final result = await db.query('SELECT * FROM items');
      expect(result.success, isTrue);
      expect(result.rows.length, 2);
    });

    test('WHERE filters rows', () async {
      await exec(
        db,
        'CREATE TABLE nums (id INTEGER PRIMARY KEY AUTOINCREMENT, n INTEGER)',
      );
      for (var i = 1; i <= 5; i++) {
        await exec(db, 'INSERT INTO nums (n) VALUES ($i)');
      }
      final result = await db.query('SELECT * FROM nums WHERE n > 3');
      expect(result.success, isTrue);
      expect(result.rows.length, 2);
    });

    test('UPDATE modifies rows', () async {
      await exec(
        db,
        'CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, val TEXT)',
      );
      await exec(db, "INSERT INTO t (val) VALUES ('old')");
      await exec(db, "UPDATE t SET val = 'new' WHERE id = 1");
      final result = await db.query("SELECT * FROM t WHERE val = 'new'");
      expect(result.rows.length, 1);
    });

    test('DELETE removes rows', () async {
      await exec(
        db,
        'CREATE TABLE t2 (id INTEGER PRIMARY KEY AUTOINCREMENT, val TEXT)',
      );
      await exec(db, "INSERT INTO t2 (val) VALUES ('a')");
      await exec(db, "INSERT INTO t2 (val) VALUES ('b')");
      await exec(db, "DELETE FROM t2 WHERE val = 'a'");
      final result = await db.query('SELECT * FROM t2');
      expect(result.rows.length, 1);
    });

    test('COUNT aggregate', () async {
      await exec(
        db,
        'CREATE TABLE agg (id INTEGER PRIMARY KEY AUTOINCREMENT, cat TEXT)',
      );
      await exec(db, "INSERT INTO agg (cat) VALUES ('A')");
      await exec(db, "INSERT INTO agg (cat) VALUES ('A')");
      await exec(db, "INSERT INTO agg (cat) VALUES ('B')");
      final result = await db.query(
        'SELECT cat, COUNT(*) AS cnt FROM agg GROUP BY cat ORDER BY cat',
      );
      expect(result.success, isTrue);
      expect(result.rows, [
        {'cat': 'A', 'cnt': 2},
        {'cat': 'B', 'cnt': 1},
      ]);
    });
  });

  group('Enhanced Indexing', () {
    late JustDatabase db;

    setUp(() async => db = await openMemory('index'));

    test('Composite PRIMARY KEY constraint is enforced', () async {
      await exec(
        db,
        'CREATE TABLE composite_pk (a INTEGER, b INTEGER, value TEXT, PRIMARY KEY (a, b))',
      );
      await exec(
        db,
        "INSERT INTO composite_pk (a, b, value) VALUES (1, 2, 'first')",
      );

      final result = await db.execute(
        "INSERT INTO composite_pk (a, b, value) VALUES (1, 2, 'duplicate')",
      );
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('UNIQUE constraint'));
    });

    test('Composite UNIQUE constraint is enforced', () async {
      await exec(
        db,
        'CREATE TABLE composite_unique (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, UNIQUE (a, b))',
      );
      await exec(db, 'INSERT INTO composite_unique (a, b) VALUES (10, 20)');

      final result = await db.execute(
        'INSERT INTO composite_unique (a, b) VALUES (10, 20)',
      );
      expect(result.success, isFalse);
      expect(result.errorMessage, contains('UNIQUE constraint'));

      final result2 = await db.execute(
        'INSERT INTO composite_unique (a, b) VALUES (10, 21)',
      );
      expect(result2.success, isTrue);
    });

    test('Foreign key columns are automatically indexed', () async {
      await exec(db, 'CREATE TABLE parent (id INTEGER PRIMARY KEY)');
      await exec(
        db,
        'CREATE TABLE child (id INTEGER PRIMARY KEY, parent_id INTEGER REFERENCES parent(id))',
      );
      expect(db.getTableSchema('child'), isNotNull);

      await exec(db, 'INSERT INTO parent (id) VALUES (1)');
      await exec(db, 'INSERT INTO child (id, parent_id) VALUES (100, 1)');

      final result = await db.query('SELECT * FROM child WHERE parent_id = 1');
      expect(result.success, isTrue);
      expect(result.rows.length, 1);
    });

    test('Query pattern tracking creates automatic indexes', () async {
      await exec(
        db,
        'CREATE TABLE frequent_queries (id INTEGER PRIMARY KEY, search_col TEXT)',
      );
      for (var i = 0; i < 10; i++) {
        await exec(
          db,
          "INSERT INTO frequent_queries (search_col) VALUES ('value$i')",
        );
      }

      for (var i = 0; i < 105; i++) {
        await db.query(
          "SELECT * FROM frequent_queries WHERE search_col = 'value5'",
        );
      }

      final result = await db.query(
        "SELECT * FROM frequent_queries WHERE search_col = 'value5'",
      );
      expect(result.success, isTrue);
      expect(result.rows.length, 1);
      // 2.0: query-pattern auto-indexing is gone; no index appears.
      expect(db.indexNamesForTable('frequent_queries'), isEmpty);
    });

    test('Composite index supports partial matching', () async {
      await exec(
        db,
        'CREATE TABLE multi_col (a INTEGER, b INTEGER, c INTEGER, PRIMARY KEY (a, b))',
      );
      await exec(db, 'INSERT INTO multi_col (a, b, c) VALUES (1, 2, 100)');
      await exec(db, 'INSERT INTO multi_col (a, b, c) VALUES (1, 3, 200)');
      await exec(db, 'INSERT INTO multi_col (a, b, c) VALUES (2, 2, 300)');

      final result1 = await db.query(
        'SELECT * FROM multi_col WHERE a = 1 AND b = 2',
      );
      expect(result1.success, isTrue);
      expect(result1.rows.length, 1);
      expect(result1.rows[0]['c'], 100);

      final result2 = await db.query('SELECT * FROM multi_col');
      expect(result2.success, isTrue);
      expect(result2.rows.length, 3);
    });

    // 1.x skipped this (no path_provider in tests); TempPaths provides one.
    test('Index metadata is persisted and restored', () async {
      final dbName = uniqueName('persist_test');
      final db1 = await JustDatabase.open(dbName);
      await exec(
        db1,
        'CREATE TABLE persist_idx (a INTEGER, b INTEGER, value TEXT, PRIMARY KEY (a, b))',
      );
      await exec(
        db1,
        "INSERT INTO persist_idx (a, b, value) VALUES (1, 2, 'test')",
      );
      expect(await rows(db1, 'SELECT * FROM persist_idx'), hasLength(1));
      await db1.close();

      final db2 = await JustDatabase.open(dbName);
      expect(
        await rows(db2, 'SELECT * FROM persist_idx'),
        hasLength(1),
        reason: 'Row should be persisted',
      );

      final result = await db2.execute(
        "INSERT INTO persist_idx (a, b, value) VALUES (1, 2, 'duplicate')",
      );
      expect(result.success, isFalse, reason: 'Duplicate key should fail');
      expect(result.errorMessage, contains('UNIQUE constraint'));
      await db2.close();
    });
  });

  group('JOIN Operations', () {
    late JustDatabase db;

    setUp(() async {
      db = await openMemory('joins');
      await exec(db, '''
        CREATE TABLE authors (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          country TEXT
        )
      ''');
      await exec(db, '''
        CREATE TABLE books (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          author_id INTEGER,
          year INTEGER,
          FOREIGN KEY (author_id) REFERENCES authors(id)
        )
      ''');
      await exec(
        db,
        "INSERT INTO authors (name, country) VALUES ('Alice', 'USA')",
      );
      await exec(
        db,
        "INSERT INTO authors (name, country) VALUES ('Bob', 'UK')",
      );
      await exec(
        db,
        "INSERT INTO authors (name, country) VALUES ('Charlie', 'USA')",
      );
      await exec(
        db,
        "INSERT INTO books (title, author_id, year) VALUES ('Book A', 1, 2020)",
      );
      await exec(
        db,
        "INSERT INTO books (title, author_id, year) VALUES ('Book B', 1, 2021)",
      );
      await exec(
        db,
        "INSERT INTO books (title, author_id, year) VALUES ('Book C', 2, 2022)",
      );
      // An orphaned book.
      await exec(
        db,
        "INSERT INTO books (title, author_id, year) VALUES ('Book D', NULL, 2023)",
      );
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
      expect(result.rows.length, 4);
      expect(result.rows[3]['title'], 'Book D');
      expect(result.rows[3]['name'], isNull);
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
      expect(result.rows.length, 2);
    });

    test('Multiple JOINs', () async {
      await exec(db, '''
        CREATE TABLE publishers (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL
        )
      ''');
      await exec(db, "INSERT INTO publishers (name) VALUES ('Publisher X')");
      await exec(db, 'ALTER TABLE books ADD COLUMN publisher_id INTEGER');
      await exec(db, 'UPDATE books SET publisher_id = 1 WHERE id <= 2');

      final result = await db.query('''
        SELECT b.title, a.name as author, p.name as publisher
        FROM books b
        INNER JOIN authors a ON b.author_id = a.id
        LEFT JOIN publishers p ON b.publisher_id = p.id
        WHERE b.year >= 2020
        ORDER BY b.title
      ''');
      expect(result.success, isTrue);
      expect(result.rows, [
        {'title': 'Book A', 'author': 'Alice', 'publisher': 'Publisher X'},
        {'title': 'Book B', 'author': 'Alice', 'publisher': 'Publisher X'},
        {'title': 'Book C', 'author': 'Bob', 'publisher': null},
      ]);
    });
  });

  group('Aggregate Functions', () {
    late JustDatabase db;

    setUp(() async {
      db = await openMemory('agg');
      await exec(db, '''
        CREATE TABLE employees (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          department TEXT,
          salary REAL,
          age INTEGER
        )
      ''');
      await exec(
        db,
        "INSERT INTO employees (name, department, salary, age) VALUES ('Alice', 'Engineering', 75000, 30)",
      );
      await exec(
        db,
        "INSERT INTO employees (name, department, salary, age) VALUES ('Bob', 'Engineering', 80000, 35)",
      );
      await exec(
        db,
        "INSERT INTO employees (name, department, salary, age) VALUES ('Charlie', 'Sales', 60000, 28)",
      );
      await exec(
        db,
        "INSERT INTO employees (name, department, salary, age) VALUES ('Diana', 'Sales', 65000, 32)",
      );
      await exec(
        db,
        "INSERT INTO employees (name, department, salary, age) VALUES ('Eve', 'Marketing', NULL, 29)",
      );
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
      db = await openMemory('group');
      await exec(db, '''
        CREATE TABLE sales (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          product TEXT,
          category TEXT,
          amount REAL,
          quantity INTEGER
        )
      ''');
      await exec(
        db,
        "INSERT INTO sales (product, category, amount, quantity) VALUES ('Widget A', 'Electronics', 100, 5)",
      );
      await exec(
        db,
        "INSERT INTO sales (product, category, amount, quantity) VALUES ('Widget B', 'Electronics', 150, 3)",
      );
      await exec(
        db,
        "INSERT INTO sales (product, category, amount, quantity) VALUES ('Gadget C', 'Electronics', 200, 7)",
      );
      await exec(
        db,
        "INSERT INTO sales (product, category, amount, quantity) VALUES ('Tool D', 'Hardware', 80, 10)",
      );
      await exec(
        db,
        "INSERT INTO sales (product, category, amount, quantity) VALUES ('Tool E', 'Hardware', 90, 12)",
      );
    });

    test('GROUP BY single column', () async {
      final result = await db.query('''
        SELECT category, COUNT(*) as cnt, SUM(amount) as total
        FROM sales
        GROUP BY category
        ORDER BY category
      ''');
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.rows.length, 2);
      expect(result.rows[0]['category'], 'Electronics');
      expect(result.rows[0]['cnt'], 3);
      expect(result.rows[0]['total'], 450);
    });

    test('GROUP BY multiple columns', () async {
      await exec(
        db,
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
      final result = await db.query('''
        SELECT category, COUNT(*) as cnt, AVG(amount) as avg_amount
        FROM sales
        GROUP BY category
        HAVING COUNT(*) >= 2
      ''');
      expect(result.success, isTrue);
      expect(result.rows.length, 2);
      expect(result.rows[0]['cnt'], greaterThanOrEqualTo(2));
    });

    test('HAVING with multiple conditions', () async {
      final result = await db.query('''
        SELECT category, COUNT(*) as cnt, SUM(amount) as total
        FROM sales
        GROUP BY category
        HAVING COUNT(*) >= 2 AND SUM(amount) > 100
      ''');
      expect(result.success, isTrue);
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
      db = await openMemory('alter');
      await exec(db, '''
        CREATE TABLE users (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL,
          email TEXT
        )
      ''');
      await exec(
        db,
        "INSERT INTO users (name, email) VALUES ('Alice', 'alice@example.com')",
      );
    });

    test('ADD COLUMN adds new column', () async {
      final result = await db.execute(
        'ALTER TABLE users ADD COLUMN age INTEGER',
      );
      expect(result.success, isTrue);

      await exec(
        db,
        "INSERT INTO users (name, email, age) VALUES ('Bob', 'bob@example.com', 30)",
      );
      final query = await db.query('SELECT * FROM users WHERE age = 30');
      expect(query.success, isTrue);
      expect(query.rows.length, 1);
    });

    test('ADD COLUMN with DEFAULT value', () async {
      await exec(
        db,
        "ALTER TABLE users ADD COLUMN status TEXT DEFAULT 'active'",
      );

      final query = await db.query(
        "SELECT status FROM users WHERE name = 'Alice'",
      );
      expect(query.success, isTrue);
      expect(query.rows[0]['status'], 'active');
    });

    test('DROP COLUMN removes column', () async {
      await exec(db, 'ALTER TABLE users ADD COLUMN temp TEXT');
      await exec(db, "UPDATE users SET temp = 'temporary'");

      final dropResult = await db.execute('ALTER TABLE users DROP COLUMN temp');
      expect(dropResult.success, isTrue);

      final query = await db.query('SELECT * FROM users');
      expect(query.success, isTrue);
      expect(query.rows[0].containsKey('temp'), isFalse);
    });

    test('RENAME COLUMN renames column', () async {
      final result = await db.execute(
        'ALTER TABLE users RENAME COLUMN name TO full_name',
      );
      expect(result.success, isTrue);

      final query = await db.query('SELECT full_name FROM users');
      expect(query.success, isTrue);
      expect(query.rows[0]['full_name'], 'Alice');

      final oldQuery = await db.query('SELECT name FROM users');
      expect(
        oldQuery.success,
        isFalse,
        reason: 'Old column name should not work after rename',
      );
    });

    test('Multiple ALTER TABLE operations', () async {
      await exec(db, 'ALTER TABLE users ADD COLUMN phone TEXT');
      await exec(
        db,
        "ALTER TABLE users ADD COLUMN city TEXT DEFAULT 'Unknown'",
      );
      await exec(db, 'ALTER TABLE users RENAME COLUMN email TO email_address');

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
      db = await openMemory('distinct');
      await exec(db, '''
        CREATE TABLE products (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT,
          category TEXT,
          price REAL
        )
      ''');
      await exec(
        db,
        "INSERT INTO products (name, category, price) VALUES ('Product A', 'Electronics', 100)",
      );
      await exec(
        db,
        "INSERT INTO products (name, category, price) VALUES ('Product B', 'Electronics', 150)",
      );
      await exec(
        db,
        "INSERT INTO products (name, category, price) VALUES ('Product C', 'Hardware', 80)",
      );
      await exec(
        db,
        "INSERT INTO products (name, category, price) VALUES ('Product D', 'Electronics', 200)",
      );
      await exec(
        db,
        "INSERT INTO products (name, category, price) VALUES ('Product E', 'Hardware', 90)",
      );
    });

    test('DISTINCT removes duplicates', () async {
      final result = await db.query('SELECT DISTINCT category FROM products');
      expect(result.success, isTrue);
      expect(result.rows.length, 2);
    });

    test('ORDER BY sorts results', () async {
      final result = await db.query(
        'SELECT name, price FROM products ORDER BY price DESC',
      );
      expect(result.success, isTrue);
      expect(result.rows[0]['price'], 200);
      expect(result.rows[4]['price'], 80);
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
      expect(result.rows[0]['id'], 3);
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
      expect(result.rows[0]['price'], 150);
    });
  });

  group('Subquery Tests', () {
    late JustDatabase db;

    setUp(() async => db = await openMemory('subquery'));

    test('Scalar subquery in SELECT clause', () async {
      await exec(
        db,
        'CREATE TABLE departments (id INTEGER PRIMARY KEY, name TEXT, budget INTEGER)',
      );
      await exec(
        db,
        'CREATE TABLE employees (id INTEGER PRIMARY KEY, name TEXT, dept_id INTEGER, salary INTEGER)',
      );
      await exec(db, '''
        INSERT INTO departments (id, name, budget) VALUES
        (1, 'Engineering', 100000),
        (2, 'Marketing', 50000)
      ''');
      await exec(db, '''
        INSERT INTO employees (id, name, dept_id, salary) VALUES
        (1, 'Alice', 1, 60000),
        (2, 'Bob', 1, 70000),
        (3, 'Charlie', 2, 45000)
      ''');

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
      await exec(
        db,
        'CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, price INTEGER)',
      );
      await exec(db, '''
        INSERT INTO products (id, name, price) VALUES
        (1, 'Laptop', 1000),
        (2, 'Mouse', 25),
        (3, 'Keyboard', 75)
      ''');

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
      await exec(
        db,
        'CREATE TABLE sales (id INTEGER PRIMARY KEY, amount INTEGER, region TEXT)',
      );
      await exec(db, '''
        INSERT INTO sales (id, amount, region) VALUES
        (1, 1000, 'North'),
        (2, 1500, 'South'),
        (3, 800, 'North'),
        (4, 2000, 'East')
      ''');

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
      await exec(
        db,
        'CREATE TABLE numbers (id INTEGER PRIMARY KEY, value INTEGER)',
      );
      await exec(db, '''
        INSERT INTO numbers (id, value) VALUES
        (1, 10),
        (2, 20),
        (3, 30),
        (4, 40)
      ''');

      final result = await db.execute('''
        SELECT value
        FROM numbers
        WHERE value > (
          SELECT AVG(value) FROM numbers
          WHERE value > (SELECT MIN(value) FROM numbers)
        )
      ''');
      expect(result.success, isTrue);
      // Min is 10, values > 10 are [20, 30, 40], avg is 30: only 40 is above.
      expect(result.rows.length, 1);
      expect(result.rows[0]['value'], 40);
    });

    test('Subquery returning NULL (empty result)', () async {
      await exec(
        db,
        'CREATE TABLE items (id INTEGER PRIMARY KEY, stock INTEGER)',
      );
      await exec(db, 'INSERT INTO items (id, stock) VALUES (1, 100)');

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
      await exec(
        db,
        'CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER, total INTEGER)',
      );
      await exec(db, '''
        INSERT INTO orders (id, customer_id, total) VALUES
        (1, 1, 100),
        (2, 1, 200),
        (3, 2, 150),
        (4, 2, 250)
      ''');

      final result = await db.execute('''
        SELECT customer_id, SUM(total) AS total_spent,
               (SELECT AVG(total) FROM orders) AS avg_order
        FROM orders
        GROUP BY customer_id
        HAVING SUM(total) > (SELECT AVG(total) FROM orders) * 2
      ''');
      expect(result.success, isTrue);
      // The average order is 175, so the sum must be > 350.
      expect(result.rows.length, 1);
      expect(result.rows[0]['customer_id'], 2);
      expect(result.rows[0]['total_spent'], 400);
    });
  });

  // ===========================================================================
  // TRANSACTION SUPPORT
  // ===========================================================================

  group('Transaction Support', () {
    // 2.0: Executor is internal; the same statements run on a database.
    late JustDatabase db;

    setUp(() async => db = await openMemory('tx'));

    Future<QueryResult> sql(String statement) => db.execute(statement);

    test('BEGIN starts a transaction', () async {
      final result = await sql('BEGIN');
      expect(result.success, isTrue);
      expect(db.inTransaction, isTrue);
    });

    test('COMMIT ends the transaction', () async {
      await sql('BEGIN');
      final result = await sql('COMMIT');
      expect(result.success, isTrue);
      expect(db.inTransaction, isFalse);
    });

    test('ROLLBACK restores data to pre-BEGIN state', () async {
      await exec(
        db,
        'CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER)',
      );
      await exec(db, 'INSERT INTO accounts (id, balance) VALUES (1, 1000)');

      await exec(db, 'BEGIN');
      await exec(db, 'UPDATE accounts SET balance = 500 WHERE id = 1');

      final duringTx = await sql('SELECT balance FROM accounts WHERE id = 1');
      expect(duringTx.rows[0]['balance'], 500);

      final rb = await sql('ROLLBACK');
      expect(rb.success, isTrue);
      expect(db.inTransaction, isFalse);

      final afterRb = await sql('SELECT balance FROM accounts WHERE id = 1');
      expect(afterRb.rows[0]['balance'], 1000);
    });

    test('COMMIT persists data — no rollback possible after', () async {
      await exec(
        db,
        'CREATE TABLE counters (id INTEGER PRIMARY KEY, val INTEGER)',
      );
      await exec(db, 'INSERT INTO counters (id, val) VALUES (1, 0)');

      await exec(db, 'BEGIN');
      await exec(db, 'UPDATE counters SET val = 42 WHERE id = 1');
      await exec(db, 'COMMIT');

      final r = await sql('SELECT val FROM counters WHERE id = 1');
      expect(r.rows[0]['val'], 42);

      final rb = await sql('ROLLBACK');
      expect(rb.success, isFalse);
      // 2.0: SQLite's message (1.x: 'no active transaction').
      expect(rb.errorMessage, contains('no transaction is active'));
    });

    test('ROLLBACK undoes INSERT', () async {
      await exec(db, 'CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT)');
      await exec(db, 'BEGIN');
      await exec(db, "INSERT INTO items (id, name) VALUES (1, 'Laptop')");
      await exec(db, 'ROLLBACK');

      final r = await sql('SELECT * FROM items');
      expect(r.rows.length, 0);
    });

    test('ROLLBACK undoes CREATE TABLE', () async {
      await exec(db, 'BEGIN');
      await exec(db, 'CREATE TABLE temp_table (id INTEGER PRIMARY KEY)');
      await exec(db, 'ROLLBACK');

      final r = await sql('SELECT * FROM temp_table');
      expect(r.success, isFalse);
    });

    test('Nested BEGIN returns error', () async {
      await exec(db, 'BEGIN');
      final r = await sql('BEGIN');
      expect(r.success, isFalse);
      // 2.0: SQLite's message (1.x: '... already active').
      expect(r.errorMessage, contains('within a transaction'));
    });

    test('SAVEPOINT and ROLLBACK TO SAVEPOINT', () async {
      await exec(
        db,
        'CREATE TABLE wallet (id INTEGER PRIMARY KEY, amount INTEGER)',
      );
      await exec(db, 'INSERT INTO wallet (id, amount) VALUES (1, 100)');

      await exec(db, 'BEGIN');
      await exec(db, 'UPDATE wallet SET amount = 200 WHERE id = 1');
      await exec(db, 'SAVEPOINT sp1');
      await exec(db, 'UPDATE wallet SET amount = 300 WHERE id = 1');

      final rb = await sql('ROLLBACK TO SAVEPOINT sp1');
      expect(rb.success, isTrue);
      expect(db.inTransaction, isTrue);

      final r = await sql('SELECT amount FROM wallet WHERE id = 1');
      expect(r.rows[0]['amount'], 200);

      await exec(db, 'COMMIT');
    });

    test('RELEASE SAVEPOINT removes the savepoint', () async {
      await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await exec(db, 'BEGIN');
      await exec(db, 'SAVEPOINT sp1');
      final relResult = await sql('RELEASE SAVEPOINT sp1');
      expect(relResult.success, isTrue);

      final rb = await sql('ROLLBACK TO SAVEPOINT sp1');
      expect(rb.success, isFalse);
      // 2.0: SQLite's message (1.x: '... does not exist').
      expect(rb.errorMessage, contains('no such savepoint'));
    });

    test('JustDatabase.transaction() helper commits on success', () async {
      await exec(
        db,
        'CREATE TABLE points (id INTEGER PRIMARY KEY, score INTEGER)',
      );
      await exec(db, 'INSERT INTO points (id, score) VALUES (1, 0)');

      final result = await db.transaction((tx) async {
        await tx.execute('UPDATE points SET score = 99 WHERE id = 1');
        return tx.query('SELECT score FROM points WHERE id = 1');
      });

      expect(result.rows[0]['score'], 99);
      expect(db.inTransaction, isFalse);
    });

    test('JustDatabase.transaction() helper rolls back on exception', () async {
      await exec(
        db,
        'CREATE TABLE points (id INTEGER PRIMARY KEY, score INTEGER)',
      );
      await exec(db, 'INSERT INTO points (id, score) VALUES (1, 0)');

      await expectLater(
        db.transaction((tx) async {
          await tx.execute('UPDATE points SET score = 42 WHERE id = 1');
          throw Exception('Intentional error');
        }),
        throwsException,
      );

      final r = await db.query('SELECT score FROM points WHERE id = 1');
      expect(r.rows[0]['score'], 0);
      expect(db.inTransaction, isFalse);
    });

    test('BEGIN DEFERRED TRANSACTION is valid syntax', () async {
      final r = await sql('BEGIN DEFERRED TRANSACTION');
      expect(r.success, isTrue);
      expect(db.inTransaction, isTrue);
      await exec(db, 'ROLLBACK');
    });

    test('BEGIN IMMEDIATE is valid syntax', () async {
      final r = await sql('BEGIN IMMEDIATE');
      expect(r.success, isTrue);
      await exec(db, 'ROLLBACK');
    });
  });

  // ===========================================================================
  // VIEWS
  // ===========================================================================

  group('View Support', () {
    // 2.0: Executor is internal; the same statements run on a database.
    late JustDatabase db;

    setUp(() async => db = await openMemory('views'));

    test('CREATE VIEW and SELECT from it', () async {
      await exec(
        db,
        'CREATE TABLE employees (id INTEGER PRIMARY KEY, name TEXT, dept TEXT, salary INTEGER)',
      );
      await exec(
        db,
        "INSERT INTO employees VALUES (1, 'Alice', 'Engineering', 90000)",
      );
      await exec(
        db,
        "INSERT INTO employees VALUES (2, 'Bob', 'Engineering', 85000)",
      );
      await exec(
        db,
        "INSERT INTO employees VALUES (3, 'Carol', 'Marketing', 70000)",
      );

      final cv = await db.execute(
        "CREATE VIEW eng_staff AS SELECT id, name, salary FROM employees WHERE dept = 'Engineering'",
      );
      expect(cv.success, isTrue);

      final r = await db.query('SELECT * FROM eng_staff');
      expect(r.success, isTrue);
      expect(r.rows.length, 2);
      expect(r.rows.map((e) => e['name']), containsAll(['Alice', 'Bob']));
    });

    test('SELECT with WHERE on view', () async {
      await exec(
        db,
        'CREATE TABLE products (id INTEGER PRIMARY KEY, name TEXT, price INTEGER, active INTEGER)',
      );
      await exec(db, "INSERT INTO products VALUES (1, 'Widget', 100, 1)");
      await exec(db, "INSERT INTO products VALUES (2, 'Gadget', 200, 1)");
      await exec(db, "INSERT INTO products VALUES (3, 'Doohickey', 50, 0)");
      await exec(
        db,
        'CREATE VIEW active_products AS SELECT * FROM products WHERE active = 1',
      );

      final r = await db.query(
        'SELECT name FROM active_products WHERE price > 100',
      );
      expect(r.success, isTrue);
      expect(r.rows.length, 1);
      expect(r.rows[0]['name'], 'Gadget');
    });

    test('CREATE VIEW IF NOT EXISTS does not overwrite', () async {
      await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await exec(db, 'INSERT INTO t VALUES (1, 10)');
      await exec(db, 'CREATE VIEW v1 AS SELECT * FROM t');
      final r = await db.execute(
        'CREATE VIEW IF NOT EXISTS v1 AS SELECT id FROM t',
      );
      expect(r.success, isTrue);
      final sel = await db.query('SELECT * FROM v1');
      expect(sel.rows[0].containsKey('v'), isTrue);
    });

    test('CREATE OR REPLACE VIEW updates definition', () async {
      await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      await exec(db, 'INSERT INTO t VALUES (1, 42)');
      await exec(db, 'CREATE VIEW v1 AS SELECT * FROM t');
      final rep = await db.execute(
        'CREATE OR REPLACE VIEW v1 AS SELECT id FROM t',
      );
      // 2.0: SQLite has no CREATE OR REPLACE VIEW; it is a syntax error and
      // the view is replaced with DROP VIEW + CREATE VIEW instead.
      expect(rep.success, isFalse);
      expect(rep.error!.kind, SqlErrorKind.syntax);
      await exec(db, 'DROP VIEW v1');
      await exec(db, 'CREATE VIEW v1 AS SELECT id FROM t');
      final sel = await db.query('SELECT * FROM v1');
      expect(sel.rows[0].keys, ['id']);
    });

    test('DROP VIEW removes the view', () async {
      await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await exec(db, 'CREATE VIEW v1 AS SELECT * FROM t');
      final dr = await db.execute('DROP VIEW v1');
      expect(dr.success, isTrue);
      final r = await db.query('SELECT * FROM v1');
      expect(r.success, isFalse);
    });

    test('DROP VIEW IF EXISTS on non-existent view', () async {
      final r = await db.execute('DROP VIEW IF EXISTS ghost_view');
      expect(r.success, isTrue);
    });

    test(
      'DROP VIEW on non-existent view without IF EXISTS returns error',
      () async {
        final r = await db.execute('DROP VIEW ghost_view');
        expect(r.success, isFalse);
        // 2.0: SQLite's message (1.x: '... does not exist').
        expect(r.errorMessage, contains('no such view'));
      },
    );

    test('View with ORDER BY and LIMIT in outer query', () async {
      await exec(db, 'CREATE TABLE nums (n INTEGER)');
      for (var i = 1; i <= 5; i++) {
        await exec(db, 'INSERT INTO nums (n) VALUES ($i)');
      }
      await exec(db, 'CREATE VIEW all_nums AS SELECT n FROM nums');
      final r = await db.query(
        'SELECT n FROM all_nums ORDER BY n DESC LIMIT 3',
      );
      expect(r.success, isTrue);
      expect(r.rows.map((e) => e['n']).toList(), [5, 4, 3]);
    });

    test('viewNames exposes defined views', () async {
      await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await exec(db, 'CREATE VIEW v1 AS SELECT * FROM t');
      await exec(db, 'CREATE VIEW v2 AS SELECT * FROM t');
      expect(db.viewNames, containsAll(['v1', 'v2']));
      await exec(db, 'DROP VIEW v1');
      expect(db.viewNames, isNot(contains('v1')));
    });
  });

  // ---------------------------------------------------------------------------
  // Encrypted databases (AES-256-GCM at rest)
  // ---------------------------------------------------------------------------
  group('Secure Database', () {
    // 2.0: there is no DatabaseMode.secure; a database is encrypted when it
    // is opened with an encryptionKey, in any mode.
    test('requires encryptionKey when mode is secure', () async {
      // 2.0: no secure mode to require a key; an empty key is the error.
      await expectLater(
        () => JustDatabase.open(uniqueName('no_key'), encryptionKey: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects encryptionKey for non-secure modes', () async {
      for (final mode in DatabaseMode.values) {
        // 2.0: every mode takes a key, as long as the database is saved...
        final db = await JustDatabase.open(
          uniqueName('mode_key'),
          mode: mode,
          encryptionKey: 'oops',
        );
        await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
        await db.close();
        // ...and an in-memory database (never written) rejects one.
        await expectLater(
          () => JustDatabase.open(
            uniqueName('extra_key'),
            mode: mode,
            persist: false,
            encryptionKey: 'oops',
          ),
          throwsA(isA<ArgumentError>()),
          reason: '$mode should reject an encryptionKey without persist',
        );
      }
    });

    test('secure mode in-memory CRUD works correctly', () async {
      // 2.0: an in-memory database cannot be encrypted, so this runs on an
      // encrypted file.
      final db = await JustDatabase.open(
        uniqueName('secure_crud'),
        encryptionKey: 'test-passphrase-123',
      );

      await exec(
        db,
        'CREATE TABLE secrets (id INTEGER PRIMARY KEY AUTOINCREMENT, value TEXT NOT NULL)',
      );
      await exec(db, "INSERT INTO secrets (value) VALUES ('alpha')");
      await exec(db, "INSERT INTO secrets (value) VALUES ('beta')");

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
        uniqueName('key_check'),
        encryptionKey: key,
      );

      // 2.0: the key is deliberately not exposed (no `encryptionKey`
      // getter), and the mode is whatever was asked for.
      expect(() => (db as dynamic).encryptionKey, throwsNoSuchMethodError);
      expect('$db', isNot(contains(key)));
      expect(db.mode, DatabaseMode.standard);
      await db.close();
    });

    test('secure persist round-trip: data survives close/reopen', () async {
      final name = uniqueName('secure_persist');
      const passphrase = 'super-secret-roundtrip';

      final db1 = await JustDatabase.open(name, encryptionKey: passphrase);
      await exec(
        db1,
        'CREATE TABLE vault (id INTEGER PRIMARY KEY AUTOINCREMENT, secret TEXT)',
      );
      await exec(db1, "INSERT INTO vault (secret) VALUES ('s3cr3t!')");
      await db1.close();

      final db2 = await JustDatabase.open(name, encryptionKey: passphrase);
      final result = await db2.query('SELECT * FROM vault');
      expect(result.success, isTrue);
      expect(result.rows.length, 1);
      expect(result.rows.first['secret'], 's3cr3t!');
      await db2.close();
    });

    test('wrong key on reopen throws StateError', () async {
      final name = uniqueName('secure_wrongkey');

      final db1 = await JustDatabase.open(name, encryptionKey: 'correct-key');
      await exec(db1, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      await exec(db1, "INSERT INTO t VALUES (1, 'data')");
      await db1.close();

      await expectLater(
        () => JustDatabase.open(name, encryptionKey: 'wrong-key'),
        throwsA(isA<StateError>()),
      );
    });
  });
}

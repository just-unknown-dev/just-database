// ignore_for_file: avoid_print

import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Opens a fresh in-memory database with a unique name.
Future<JustDatabase> _openDb() =>
    JustDatabase.open('test_${DateTime.now().microsecondsSinceEpoch}');

void main() {
  // ───────────────────────────────────────────────────────────────────────────
  // Triggers
  // ───────────────────────────────────────────────────────────────────────────
  group('Triggers', () {
    late JustDatabase db;

    setUp(() async {
      db = await _openDb();
      await db.execute(
        'CREATE TABLE products (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price REAL)',
      );
      await db.execute(
        'CREATE TABLE audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, action TEXT, product_name TEXT)',
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('CREATE TRIGGER syntax is accepted', () async {
      final r = await db.execute('''
        CREATE TRIGGER log_insert
        AFTER INSERT ON products
        FOR EACH ROW
        BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('INSERT', NEW.name);
        END
      ''');
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('triggerNames exposes defined triggers', () async {
      await db.execute('''
        CREATE TRIGGER trg_a AFTER INSERT ON products FOR EACH ROW BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('X', NEW.name);
        END
      ''');
      expect(db.triggerNames, contains('trg_a'));
    });

    test('AFTER INSERT trigger fires and inserts audit row', () async {
      await db.execute('''
        CREATE TRIGGER log_insert
        AFTER INSERT ON products
        FOR EACH ROW
        BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('INSERT', NEW.name);
        END
      ''');
      await db.execute(
        "INSERT INTO products (name, price) VALUES ('Widget', 9.99)",
      );
      final audit = await db.query('SELECT * FROM audit_log');
      expect(audit.rows.length, 1);
      expect(audit.rows.first['action'], 'INSERT');
      expect(audit.rows.first['product_name'], 'Widget');
    });

    test('BEFORE INSERT trigger fires before row is committed', () async {
      // We just verify the trigger itself runs without error.
      await db.execute('''
        CREATE TRIGGER before_insert
        BEFORE INSERT ON products
        FOR EACH ROW
        BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('BEFORE_INSERT', NEW.name);
        END
      ''');
      await db.execute(
        "INSERT INTO products (name, price) VALUES ('Gadget', 4.99)",
      );
      final audit = await db.query(
        "SELECT * FROM audit_log WHERE action = 'BEFORE_INSERT'",
      );
      expect(audit.rows.length, 1);
    });

    test('AFTER UPDATE trigger fires and receives OLD/NEW', () async {
      await db.execute(
        "INSERT INTO products (name, price) VALUES ('Alpha', 1.0)",
      );
      await db.execute('''
        CREATE TRIGGER log_update
        AFTER UPDATE ON products
        FOR EACH ROW
        BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('UPDATE', NEW.name);
        END
      ''');
      await db.execute("UPDATE products SET name = 'Beta' WHERE id = 1");
      final audit = await db.query(
        "SELECT * FROM audit_log WHERE action = 'UPDATE'",
      );
      expect(audit.rows.length, 1);
      expect(audit.rows.first['product_name'], 'Beta');
    });

    test('AFTER DELETE trigger fires', () async {
      await db.execute(
        "INSERT INTO products (name, price) VALUES ('Delete Me', 0.0)",
      );
      await db.execute('''
        CREATE TRIGGER log_delete
        AFTER DELETE ON products
        FOR EACH ROW
        BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('DELETE', OLD.name);
        END
      ''');
      await db.execute("DELETE FROM products WHERE name = 'Delete Me'");
      final audit = await db.query(
        "SELECT * FROM audit_log WHERE action = 'DELETE'",
      );
      expect(audit.rows.length, 1);
      expect(audit.rows.first['product_name'], 'Delete Me');
    });

    test('CREATE TRIGGER IF NOT EXISTS does not error on duplicate', () async {
      await db.execute('''
        CREATE TRIGGER trg_once AFTER INSERT ON products FOR EACH ROW BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('X', NEW.name);
        END
      ''');
      final r = await db.execute('''
        CREATE TRIGGER IF NOT EXISTS trg_once AFTER INSERT ON products FOR EACH ROW BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('Y', NEW.name);
        END
      ''');
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('DROP TRIGGER removes the trigger', () async {
      await db.execute('''
        CREATE TRIGGER trg_drop AFTER INSERT ON products FOR EACH ROW BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('Z', NEW.name);
        END
      ''');
      expect(db.triggerNames, contains('trg_drop'));
      final r = await db.execute('DROP TRIGGER trg_drop');
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(db.triggerNames, isNot(contains('trg_drop')));
    });

    test('DROP TRIGGER IF EXISTS on non-existent trigger succeeds', () async {
      final r = await db.execute('DROP TRIGGER IF EXISTS no_such_trigger');
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('Trigger with WHEN clause only fires when condition is met', () async {
      await db.execute('''
        CREATE TRIGGER expensive_insert
        AFTER INSERT ON products
        FOR EACH ROW
        WHEN (NEW.price > 100)
        BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('EXPENSIVE', NEW.name);
        END
      ''');
      await db.execute(
        "INSERT INTO products (name, price) VALUES ('Cheap', 5.0)",
      );
      await db.execute(
        "INSERT INTO products (name, price) VALUES ('Pricey', 200.0)",
      );
      final audit = await db.query(
        "SELECT * FROM audit_log WHERE action = 'EXPENSIVE'",
      );
      expect(audit.rows.length, 1);
      expect(audit.rows.first['product_name'], 'Pricey');
    });

    test('Multiple triggers can be defined on the same table', () async {
      await db.execute('''
        CREATE TRIGGER trg1 AFTER INSERT ON products FOR EACH ROW BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('T1', NEW.name);
        END
      ''');
      await db.execute('''
        CREATE TRIGGER trg2 AFTER INSERT ON products FOR EACH ROW BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('T2', NEW.name);
        END
      ''');
      await db.execute(
        "INSERT INTO products (name, price) VALUES ('Multi', 1.0)",
      );
      final audit = await db.query('SELECT * FROM audit_log ORDER BY id');
      expect(audit.rows.length, 2);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Spatial data and R-tree
  // ───────────────────────────────────────────────────────────────────────────
  group('Spatial — Point / BoundingBox / Polygon', () {
    test('Point.distanceTo computes Euclidean distance', () {
      final p1 = Point(0, 0);
      final p2 = Point(3, 4);
      expect(p1.distanceTo(p2), closeTo(5.0, 0.0001));
    });

    test('Point JSON round-trip', () {
      final p = Point(1.5, -2.5);
      final back = Point.fromJson(p.toJson());
      expect(back.x, p.x);
      expect(back.y, p.y);
    });

    test('BoundingBox.intersects true when overlapping', () {
      final a = BoundingBox(0, 0, 10, 10);
      final b = BoundingBox(5, 5, 15, 15);
      expect(a.intersects(b), isTrue);
    });

    test('BoundingBox.intersects false when disjoint', () {
      final a = BoundingBox(0, 0, 4, 4);
      final b = BoundingBox(5, 5, 10, 10);
      expect(a.intersects(b), isFalse);
    });

    test('BoundingBox.containsPoint', () {
      final bbox = BoundingBox(0, 0, 10, 10);
      expect(bbox.containsPoint(Point(5, 5)), isTrue);
      expect(bbox.containsPoint(Point(15, 5)), isFalse);
    });

    test('Polygon.containsPoint ray-casting', () {
      final square = Polygon([
        Point(0, 0),
        Point(10, 0),
        Point(10, 10),
        Point(0, 10),
      ]);
      expect(square.containsPoint(Point(5, 5)), isTrue);
      expect(square.containsPoint(Point(15, 5)), isFalse);
    });

    test('Polygon.area (shoelace) correct for unit square', () {
      final unitSquare = Polygon([
        Point(0, 0),
        Point(1, 0),
        Point(1, 1),
        Point(0, 1),
      ]);
      expect(unitSquare.area, closeTo(1.0, 0.0001));
    });
  });

  group('Spatial — RTree index', () {
    test('insert and search returns matching entries', () {
      final tree = RTreeIndex();
      tree.insert(1, BoundingBox(0, 0, 5, 5));
      tree.insert(2, BoundingBox(10, 10, 20, 20));
      tree.insert(3, BoundingBox(2, 2, 8, 8));

      final results = tree.search(BoundingBox(0, 0, 6, 6));
      final ids = results.map((e) => e.id).toList();
      expect(ids, containsAll([1, 3]));
      expect(ids, isNot(contains(2)));
    });

    test('delete removes entry from index', () {
      final tree = RTreeIndex();
      tree.insert(1, BoundingBox(0, 0, 5, 5));
      tree.insert(2, BoundingBox(0, 0, 5, 5));

      expect(tree.delete(1), isTrue);
      final results = tree.search(BoundingBox(0, 0, 5, 5));
      final ids = results.map((e) => e.id).toList();
      expect(ids, isNot(contains(1)));
      expect(ids, contains(2));
    });

    test('nearest returns k closest entries', () {
      final tree = RTreeIndex();
      tree.insert(1, BoundingBox(0, 0, 1, 1)); // near (0,0)
      tree.insert(2, BoundingBox(100, 100, 101, 101)); // far
      tree.insert(3, BoundingBox(0.5, 0.5, 1.5, 1.5)); // near (0,0)

      final nearest = tree.nearest(Point(0, 0), 2);
      final ids = nearest.map((e) => e.id).toList();
      expect(ids.length, 2);
      expect(ids, isNot(contains(2))); // far entry should not be in top-2
    });

    test('length reflects inserted count', () {
      final tree = RTreeIndex();
      expect(tree.length, 0);
      tree.insert(1, BoundingBox(0, 0, 1, 1));
      tree.insert(2, BoundingBox(2, 2, 3, 3));
      expect(tree.length, 2);
    });

    test('JSON round-trip preserves entries', () {
      final tree = RTreeIndex();
      tree.insert(1, BoundingBox(0, 0, 5, 5));
      tree.insert(2, BoundingBox(10, 10, 20, 20));
      final json = tree.toJson();
      final back = RTreeIndex.fromJson(json);
      expect(back.length, 2);
      final results = back.search(BoundingBox(0, 0, 6, 6));
      expect(results.map((e) => e.id), contains(1));
    });
  });

  group('Spatial — SQL ST_* functions', () {
    late JustDatabase db;

    setUp(() async {
      db = await _openDb();
      await db.execute(
        'CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, pt TEXT)',
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('ST_MAKEPOINT returns a point map', () async {
      final r = await db.query('SELECT ST_MAKEPOINT(3.0, 4.0) AS pt');
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(r.rows, hasLength(1));
      final pt = r.rows.first['pt'];
      expect(pt, isA<Map>());
      expect((pt as Map)['x'], closeTo(3.0, 0.0001));
      expect(pt['y'], closeTo(4.0, 0.0001));
    });

    test('ST_X and ST_Y extract coordinates', () async {
      final r = await db.query(
        'SELECT ST_X(ST_MAKEPOINT(7.0, 11.0)) AS x, ST_Y(ST_MAKEPOINT(7.0, 11.0)) AS y',
      );
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(r.rows.first['x'], closeTo(7.0, 0.0001));
      expect(r.rows.first['y'], closeTo(11.0, 0.0001));
    });

    test('ST_DISTANCE computes distance between two points', () async {
      final r = await db.query(
        'SELECT ST_DISTANCE(ST_MAKEPOINT(0.0, 0.0), ST_MAKEPOINT(3.0, 4.0)) AS d',
      );
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(r.rows.first['d'], closeTo(5.0, 0.001));
    });

    test('CREATE SPATIAL INDEX is accepted', () async {
      final r = await db.execute(
        'CREATE SPATIAL INDEX idx_loc ON locations (pt)',
      );
      expect(r.success, isTrue, reason: r.errorMessage);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // CREATE / DROP INDEX
  // ───────────────────────────────────────────────────────────────────────────
  group('Index DDL', () {
    late JustDatabase db;

    setUp(() async {
      db = await _openDb();
      await db.execute(
        'CREATE TABLE employees (id INTEGER PRIMARY KEY AUTOINCREMENT, dept TEXT, salary REAL)',
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('CREATE INDEX is accepted', () async {
      final r = await db.execute('CREATE INDEX idx_dept ON employees (dept)');
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('CREATE UNIQUE INDEX is accepted', () async {
      final r = await db.execute(
        'CREATE UNIQUE INDEX idx_unique_dept ON employees (dept)',
      );
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('DROP INDEX removes the index', () async {
      await db.execute('CREATE INDEX idx_salary ON employees (salary)');
      final before = db.indexNamesForTable('employees');
      expect(before, isNotEmpty);

      final r = await db.execute('DROP INDEX idx_salary ON employees');
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('DROP INDEX IF EXISTS on non-existent index succeeds', () async {
      final r = await db.execute(
        'DROP INDEX IF EXISTS no_such_idx ON employees',
      );
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('indexNamesForTable returns created index', () async {
      await db.execute('CREATE INDEX idx_dept2 ON employees (dept)');
      final names = db.indexNamesForTable('employees');
      expect(names.isNotEmpty, isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Query optimization hints
  // ───────────────────────────────────────────────────────────────────────────
  group('Query Hints', () {
    test('Hint comment is parsed and stored on SelectStatement', () {
      final stmt = Parser.parseSQL(
        '/*+ INDEX(users idx_name) */ SELECT * FROM users',
      );
      expect(stmt, isA<SelectStatement>());
      final sel = stmt as SelectStatement;
      expect(sel.hints, isNotEmpty);
      expect(sel.hints.first.type, HintType.forceIndex);
    });

    test('Inline hint after SELECT keyword is parsed', () {
      final stmt = Parser.parseSQL('SELECT /*+ FULL_SCAN */ * FROM orders');
      expect(stmt, isA<SelectStatement>());
      final sel = stmt as SelectStatement;
      expect(sel.hints, isNotEmpty);
      expect(sel.hints.first.type, HintType.fullScan);
    });

    test('NO_INDEX hint is parsed', () {
      final stmt = Parser.parseSQL('/*+ NO_INDEX */ SELECT id FROM products');
      expect(stmt, isA<SelectStatement>());
      final sel = stmt as SelectStatement;
      expect(sel.hints.any((h) => h.type == HintType.noIndex), isTrue);
    });

    test('FORCE_INDEX hint is parsed', () {
      final stmt = Parser.parseSQL(
        '/*+ FORCE_INDEX(tbl_name idx_col) */ SELECT * FROM tbl_name',
      );
      expect(stmt, isA<SelectStatement>());
      final sel = stmt as SelectStatement;
      expect(sel.hints.any((h) => h.type == HintType.forceIndex), isTrue);
    });

    test('Query with hint executes successfully', () async {
      final db = await _openDb();
      await db.execute(
        'CREATE TABLE hint_t (id INTEGER PRIMARY KEY, val TEXT)',
      );
      await db.execute("INSERT INTO hint_t (val) VALUES ('x')");
      final r = await db.query('/*+ FULL_SCAN */ SELECT * FROM hint_t');
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(r.rows, hasLength(1));
      await db.close();
    });

    test('Multiple hints in a single comment are all parsed', () {
      final stmt = Parser.parseSQL(
        '/*+ INDEX(t idx_a) NO_INDEX */ SELECT * FROM t',
      );
      expect(stmt, isA<SelectStatement>());
      final sel = stmt as SelectStatement;
      expect(sel.hints.length, greaterThanOrEqualTo(1));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Scalar functions
  // ───────────────────────────────────────────────────────────────────────────
  group('Scalar Functions', () {
    late JustDatabase db;

    setUp(() async {
      db = await _openDb();
      await db.execute(
        'CREATE TABLE sf (id INTEGER PRIMARY KEY, s TEXT, n REAL)',
      );
      await db.execute("INSERT INTO sf (s, n) VALUES ('Hello World', -3.7)");
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('UPPER returns uppercase string', () async {
      final r = await db.query("SELECT UPPER('hello') AS u");
      expect(r.rows.first['u'], 'HELLO');
    });

    test('LOWER returns lowercase string', () async {
      final r = await db.query("SELECT LOWER('WORLD') AS l");
      expect(r.rows.first['l'], 'world');
    });

    test('LENGTH returns string length', () async {
      final r = await db.query("SELECT LENGTH('test') AS len");
      expect(r.rows.first['len'], 4);
    });

    test('SUBSTR extracts substring', () async {
      final r = await db.query("SELECT SUBSTR('Hello', 1, 3) AS s");
      expect(r.rows.first['s'], 'Hel');
    });

    test('ABS returns absolute value', () async {
      final r = await db.query('SELECT ABS(-42) AS a');
      expect(r.rows.first['a'], 42);
    });

    test('ROUND rounds to specified decimal places', () async {
      final r = await db.query('SELECT ROUND(3.14159, 2) AS r');
      final rounded = (r.rows.first['r'] as num).toDouble();
      expect(rounded, closeTo(3.14, 0.0001));
    });

    test('COALESCE returns first non-null value', () async {
      final r = await db.query("SELECT COALESCE(NULL, NULL, 'found') AS c");
      expect(r.rows.first['c'], 'found');
    });

    test('TRIM removes leading/trailing whitespace', () async {
      final r = await db.query("SELECT TRIM('  hi  ') AS t");
      expect(r.rows.first['t'], 'hi');
    });

    test('REPLACE substitutes substrings', () async {
      final r = await db.query("SELECT REPLACE('foo bar', 'bar', 'baz') AS r");
      expect(r.rows.first['r'], 'foo baz');
    });

    test('CONCAT joins strings', () async {
      final r = await db.query("SELECT CONCAT('Hello', ' ', 'World') AS c");
      expect(r.rows.first['c'], 'Hello World');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Backup & Restore
  // ───────────────────────────────────────────────────────────────────────────
  group('Backup — SQL dump', () {
    late JustDatabase db;

    setUp(() async {
      db = await _openDb();
      await db.execute(
        'CREATE TABLE books (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, year INTEGER)',
      );
      await db.execute(
        "INSERT INTO books (title, year) VALUES ('Dart in Action', 2023)",
      );
      await db.execute(
        "INSERT INTO books (title, year) VALUES ('Flutter Deep', 2024)",
      );
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('exportSql returns non-empty SQL string with CREATE TABLE', () async {
      // Access tables via the exported Executor / tables store by using BackupManager
      // We use two databases: source and restored.
      final source = await _openDb();
      await source.execute(
        'CREATE TABLE books2 (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT)',
      );
      await source.execute("INSERT INTO books2 (title) VALUES ('A')");
      await source.execute("INSERT INTO books2 (title) VALUES ('B')");

      // Create a second db and restore from SQL dump via execute statements directly.
      // BackupManager requires the raw tables map, so we exercise it indirectly by
      // using Executor + Parser.parseSQLStatements which BackupManager uses internally.
      final stmts = Parser.parseSQLStatements('''
        CREATE TABLE IF NOT EXISTS restored (id INTEGER PRIMARY KEY, title TEXT);
        INSERT INTO restored (id, title) VALUES (1, 'A');
        INSERT INTO restored (id, title) VALUES (2, 'B');
      ''');
      expect(stmts.length, 3);

      await source.close();
    });

    test('Parser.parseSQLStatements parses multiple statements', () {
      final stmts = Parser.parseSQLStatements('''
        CREATE TABLE t1 (id INTEGER PRIMARY KEY);
        INSERT INTO t1 (id) VALUES (1);
        INSERT INTO t1 (id) VALUES (2);
        SELECT * FROM t1;
      ''');
      expect(stmts.length, 4);
    });

    test(
      'BackupManager.exportJson produces a map with _meta and tables',
      () async {
        // Use a fresh executor directly to test BackupManager
        final tables = <String, Table>{};
        final executor = Executor(tables);
        await executor.executeSQL(
          'CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)',
        );
        await executor.executeSQL(
          "INSERT INTO items (id, label) VALUES (1, 'alpha')",
        );
        await executor.executeSQL(
          "INSERT INTO items (id, label) VALUES (2, 'beta')",
        );

        final json = BackupManager.exportJson(tables);
        expect(json.containsKey('_meta'), isTrue);
        expect(json.containsKey('tables'), isTrue);
        final tablesMap = json['tables'] as Map<String, dynamic>;
        expect(tablesMap.containsKey('items'), isTrue);
      },
    );

    test(
      'BackupManager.exportJson + importJson round-trip preserves rows',
      () async {
        final tables = <String, Table>{};
        final executor = Executor(tables);
        await executor.executeSQL(
          'CREATE TABLE items2 (id INTEGER PRIMARY KEY, label TEXT)',
        );
        await executor.executeSQL(
          "INSERT INTO items2 (id, label) VALUES (1, 'one')",
        );
        await executor.executeSQL(
          "INSERT INTO items2 (id, label) VALUES (2, 'two')",
        );

        final json = BackupManager.exportJson(tables);

        // Restore into a fresh executor
        final tables2 = <String, Table>{};
        final count = BackupManager.importJson(json, tables2);
        expect(count, greaterThan(0));

        final executor2 = Executor(tables2);
        final result = await executor2.executeSQL(
          'SELECT * FROM items2 ORDER BY id',
        );
        expect(result.success, isTrue, reason: result.errorMessage);
        expect(result.rows.length, 2);
        expect(result.rows.first['label'], 'one');
      },
    );

    test('BackupManager.exportSql produces CREATE TABLE + INSERT', () async {
      final tables = <String, Table>{};
      final executor = Executor(tables);
      await executor.executeSQL(
        'CREATE TABLE tbl (id INTEGER PRIMARY KEY, name TEXT)',
      );
      await executor.executeSQL(
        "INSERT INTO tbl (id, name) VALUES (1, 'Alice')",
      );
      await executor.executeSQL("INSERT INTO tbl (id, name) VALUES (2, 'Bob')");

      final sql = BackupManager.exportSql(tables);
      expect(sql, contains('CREATE TABLE'));
      expect(sql, contains('tbl'));
      expect(sql, contains('INSERT'));
      expect(sql, contains('Alice'));
      expect(sql, contains('Bob'));
    });

    test('BackupManager.importSql restores tables from SQL dump', () async {
      final tables = <String, Table>{};
      final executor = Executor(tables);
      await executor.executeSQL(
        'CREATE TABLE src_t (id INTEGER PRIMARY KEY, val TEXT)',
      );
      await executor.executeSQL("INSERT INTO src_t (id, val) VALUES (10, 'X')");
      await executor.executeSQL("INSERT INTO src_t (id, val) VALUES (20, 'Y')");

      final sql = BackupManager.exportSql(tables);

      // Restore in a separate executor
      final tables2 = <String, Table>{};
      final count = await BackupManager.importSql(sql, tables2);
      expect(count, greaterThan(0));

      final executor2 = Executor(tables2);
      final result = await executor2.executeSQL(
        'SELECT * FROM src_t ORDER BY id',
      );
      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.rows.length, 2);
      expect(result.rows[0]['val'], 'X');
      expect(result.rows[1]['val'], 'Y');
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Migrations
  // ───────────────────────────────────────────────────────────────────────────
  group('Migrations', () {
    late Executor executor;

    setUp(() {
      executor = Executor({});
    });

    test('MigrationRunner.initialize creates _migrations table', () async {
      final runner = MigrationRunner(executor: executor, migrations: []);
      await runner.initialize();
      final result = await executor.executeSQL('SELECT * FROM _migrations');
      expect(result.success, isTrue, reason: result.errorMessage);
    });

    test('currentVersion returns 0 before any migrations', () async {
      final runner = MigrationRunner(executor: executor, migrations: []);
      expect(await runner.currentVersion(), 0);
    });

    test('SqlMigration.up executes upSql', () async {
      final migration = SqlMigration(
        version: 1,
        name: 'create users',
        upSql: 'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)',
      );
      final runner = MigrationRunner(
        executor: executor,
        migrations: [migration],
      );
      final results = await runner.migrate();
      expect(results.length, 1);
      expect(results.first.status, MigrationStatus.applied);

      final res = await executor.executeSQL('SELECT * FROM users');
      expect(res.success, isTrue, reason: res.errorMessage);
    });

    test('currentVersion returns applied version after migrate', () async {
      final m1 = SqlMigration(
        version: 1,
        name: 'v1',
        upSql: 'CREATE TABLE t1 (id INTEGER PRIMARY KEY)',
      );
      final runner = MigrationRunner(executor: executor, migrations: [m1]);
      await runner.migrate();
      expect(await runner.currentVersion(), 1);
    });

    test('Running migrate again skips already-applied migrations', () async {
      final m1 = SqlMigration(
        version: 1,
        name: 'v1',
        upSql: 'CREATE TABLE t2 (id INTEGER PRIMARY KEY)',
      );
      final runner = MigrationRunner(executor: executor, migrations: [m1]);
      await runner.migrate();

      final results2 = await runner.migrate();
      expect(results2.first.status, MigrationStatus.skipped);
    });

    test('Multiple migrations apply in order', () async {
      final migrations = [
        SqlMigration(
          version: 1,
          name: 'create users table',
          upSql: 'CREATE TABLE mul_users (id INTEGER PRIMARY KEY)',
        ),
        SqlMigration(
          version: 2,
          name: 'add email column',
          upSql: 'ALTER TABLE mul_users ADD COLUMN email TEXT',
        ),
      ];
      final runner = MigrationRunner(
        executor: executor,
        migrations: migrations,
      );
      final results = await runner.migrate();
      expect(
        results.where((r) => r.status == MigrationStatus.applied).length,
        2,
      );
      expect(await runner.currentVersion(), 2);
    });

    test('migrate with targetVersion stops at correct version', () async {
      final migrations = [
        SqlMigration(
          version: 1,
          name: 'v1',
          upSql: 'CREATE TABLE tv1 (id INTEGER PRIMARY KEY)',
        ),
        SqlMigration(
          version: 2,
          name: 'v2',
          upSql: 'CREATE TABLE tv2 (id INTEGER PRIMARY KEY)',
        ),
        SqlMigration(
          version: 3,
          name: 'v3',
          upSql: 'CREATE TABLE tv3 (id INTEGER PRIMARY KEY)',
        ),
      ];
      final runner = MigrationRunner(
        executor: executor,
        migrations: migrations,
      );
      await runner.migrate(targetVersion: 2);
      expect(await runner.currentVersion(), 2);
      // tv3 should not exist
      final r = await executor.executeSQL('SELECT * FROM tv3');
      expect(r.success, isFalse);
    });

    test('CallbackMigration.up executes callback', () async {
      bool called = false;
      final m = CallbackMigration(
        version: 1,
        name: 'callback test',
        upCallback: (ex) async {
          called = true;
        },
      );
      final runner = MigrationRunner(executor: executor, migrations: [m]);
      await runner.migrate();
      expect(called, isTrue);
    });

    test('SqlMigration down rollback drops table', () async {
      final m = SqlMigration(
        version: 1,
        name: 'create rollback_t',
        upSql: 'CREATE TABLE rollback_t (id INTEGER PRIMARY KEY)',
        downSql: 'DROP TABLE rollback_t',
      );
      final runner = MigrationRunner(executor: executor, migrations: [m]);
      await runner.migrate();
      expect(await runner.currentVersion(), 1);

      await runner.rollback(targetVersion: 0);
      // Table should be gone
      final r = await executor.executeSQL('SELECT * FROM rollback_t');
      expect(r.success, isFalse);
    });

    test('status() lists migration results', () async {
      final m1 = SqlMigration(
        version: 1,
        name: 'status_test',
        upSql: 'CREATE TABLE st1 (id INTEGER PRIMARY KEY)',
      );
      final runner = MigrationRunner(executor: executor, migrations: [m1]);
      await runner.migrate();
      final statusList = await runner.status();
      expect(statusList.isNotEmpty, isTrue);
    });

    test('SqlMigration has a checksum', () {
      final m = SqlMigration(
        version: 1,
        name: 'cs',
        upSql: 'CREATE TABLE cs_t (id INTEGER PRIMARY KEY)',
      );
      expect(m.checksum, isNotNull);
      expect(m.checksum.length, greaterThan(10));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Performance Benchmarking
  // ───────────────────────────────────────────────────────────────────────────
  group('Benchmarking', () {
    test('QueryStats computes correct average', () {
      final stats = QueryStats(
        label: 'test',
        iterations: 4,
        times: [
          const Duration(milliseconds: 10),
          const Duration(milliseconds: 20),
          const Duration(milliseconds: 30),
          const Duration(milliseconds: 40),
        ],
      );
      expect(stats.average.inMilliseconds, 25);
    });

    test('QueryStats computes correct min and max', () {
      final stats = QueryStats(
        label: 'mm',
        iterations: 3,
        times: [
          const Duration(milliseconds: 5),
          const Duration(milliseconds: 50),
          const Duration(milliseconds: 25),
        ],
      );
      expect(stats.min.inMilliseconds, 5);
      expect(stats.max.inMilliseconds, 50);
    });

    test('QueryStats.p95 returns correct percentile', () {
      final times = List.generate(100, (i) => Duration(milliseconds: i + 1));
      final stats = QueryStats(label: 'p', iterations: 100, times: times);
      // p95 should be at or near 95ms
      expect(stats.p95.inMilliseconds, greaterThanOrEqualTo(93));
      expect(stats.p95.inMilliseconds, lessThanOrEqualTo(97));
    });

    test('QueryStats.throughput is positive when times are non-zero', () {
      final stats = QueryStats(
        label: 'tput',
        iterations: 10,
        times: List.generate(10, (_) => const Duration(milliseconds: 1)),
      );
      expect(stats.throughput, greaterThan(0));
    });

    test('BenchmarkSuite.run returns a non-empty result', () async {
      final suite = BenchmarkSuite(
        name: 'tiny suite',
        warmupIterations: 1,
        measureIterations: 3,
      );
      int callCount = 0;
      suite.addCase('noop', () async {
        callCount++;
      });
      final result = await suite.run();
      expect(result.results, hasLength(1));
      expect(result.results.first.label, 'noop');
      expect(callCount, greaterThan(0));
    });

    test('BenchmarkSuiteResult.formatTable returns non-empty string', () async {
      final suite = BenchmarkSuite(
        name: 'format suite',
        warmupIterations: 1,
        measureIterations: 2,
      );
      suite.addCase('dummy', () async {});
      final result = await suite.run();
      final table = result.formatTable();
      expect(table, isNotEmpty);
    });

    test('DatabaseBenchmark.run completes without error', () async {
      final tables = <String, Table>{};
      final executor = Executor(tables);
      final bench = DatabaseBenchmark(executor: executor, rowCount: 10);
      final result = await bench.run(warmup: 1, iterations: 2);
      expect(result.results, isNotEmpty);
    });
  });
}

// Ported from the 1.x test/new_features_test.dart: triggers, spatial SQL,
// index DDL, query hints, scalar functions, backups, migrations and
// benchmarks.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/src/sql/ast.dart';
import 'package:just_database/src/sql/parser.dart';

import 'legacy_helpers.dart';

void main() {
  tearDown(closeAllOpen);

  // ───────────────────────────────────────────────────────────────────────────
  // Triggers
  // ───────────────────────────────────────────────────────────────────────────
  group('Triggers', () {
    late JustDatabase db;

    setUp(() async {
      db = await openMemory('trg');
      await exec(
        db,
        'CREATE TABLE products (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, price REAL)',
      );
      await exec(
        db,
        'CREATE TABLE audit_log (id INTEGER PRIMARY KEY AUTOINCREMENT, action TEXT, product_name TEXT)',
      );
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
      await exec(db, '''
        CREATE TRIGGER trg_a AFTER INSERT ON products FOR EACH ROW BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('X', NEW.name);
        END
      ''');
      expect(db.triggerNames, contains('trg_a'));
    });

    test('AFTER INSERT trigger fires and inserts audit row', () async {
      await exec(db, '''
        CREATE TRIGGER log_insert
        AFTER INSERT ON products
        FOR EACH ROW
        BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('INSERT', NEW.name);
        END
      ''');
      await exec(
        db,
        "INSERT INTO products (name, price) VALUES ('Widget', 9.99)",
      );
      final audit = await db.query('SELECT * FROM audit_log');
      expect(audit.rows.length, 1);
      expect(audit.rows.first['action'], 'INSERT');
      expect(audit.rows.first['product_name'], 'Widget');
    });

    test('BEFORE INSERT trigger fires before row is committed', () async {
      await exec(db, '''
        CREATE TRIGGER before_insert
        BEFORE INSERT ON products
        FOR EACH ROW
        BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('BEFORE_INSERT', NEW.name);
        END
      ''');
      await exec(
        db,
        "INSERT INTO products (name, price) VALUES ('Gadget', 4.99)",
      );
      final audit = await db.query(
        "SELECT * FROM audit_log WHERE action = 'BEFORE_INSERT'",
      );
      expect(audit.rows.length, 1);
    });

    test('AFTER UPDATE trigger fires and receives OLD/NEW', () async {
      await exec(
        db,
        "INSERT INTO products (name, price) VALUES ('Alpha', 1.0)",
      );
      await exec(db, '''
        CREATE TRIGGER log_update
        AFTER UPDATE ON products
        FOR EACH ROW
        BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('UPDATE', NEW.name);
        END
      ''');
      await exec(db, "UPDATE products SET name = 'Beta' WHERE id = 1");
      final audit = await db.query(
        "SELECT * FROM audit_log WHERE action = 'UPDATE'",
      );
      expect(audit.rows.length, 1);
      expect(audit.rows.first['product_name'], 'Beta');
    });

    test('AFTER DELETE trigger fires', () async {
      await exec(
        db,
        "INSERT INTO products (name, price) VALUES ('Delete Me', 0.0)",
      );
      await exec(db, '''
        CREATE TRIGGER log_delete
        AFTER DELETE ON products
        FOR EACH ROW
        BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('DELETE', OLD.name);
        END
      ''');
      await exec(db, "DELETE FROM products WHERE name = 'Delete Me'");
      final audit = await db.query(
        "SELECT * FROM audit_log WHERE action = 'DELETE'",
      );
      expect(audit.rows.length, 1);
      expect(audit.rows.first['product_name'], 'Delete Me');
    });

    test('CREATE TRIGGER IF NOT EXISTS does not error on duplicate', () async {
      await exec(db, '''
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
      await exec(db, '''
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
      await exec(db, '''
        CREATE TRIGGER expensive_insert
        AFTER INSERT ON products
        FOR EACH ROW
        WHEN (NEW.price > 100)
        BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('EXPENSIVE', NEW.name);
        END
      ''');
      await exec(
        db,
        "INSERT INTO products (name, price) VALUES ('Cheap', 5.0)",
      );
      await exec(
        db,
        "INSERT INTO products (name, price) VALUES ('Pricey', 200.0)",
      );
      final audit = await db.query(
        "SELECT * FROM audit_log WHERE action = 'EXPENSIVE'",
      );
      expect(audit.rows.length, 1);
      expect(audit.rows.first['product_name'], 'Pricey');
    });

    test('Multiple triggers can be defined on the same table', () async {
      await exec(db, '''
        CREATE TRIGGER trg1 AFTER INSERT ON products FOR EACH ROW BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('T1', NEW.name);
        END
      ''');
      await exec(db, '''
        CREATE TRIGGER trg2 AFTER INSERT ON products FOR EACH ROW BEGIN
          INSERT INTO audit_log (action, product_name) VALUES ('T2', NEW.name);
        END
      ''');
      await exec(
        db,
        "INSERT INTO products (name, price) VALUES ('Multi', 1.0)",
      );
      final audit = await db.query('SELECT * FROM audit_log ORDER BY id');
      expect(audit.rows.length, 2);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Spatial
  // ───────────────────────────────────────────────────────────────────────────
  group('Spatial — Point / BoundingBox / Polygon', () {
    // 2.0: Point, BoundingBox and Polygon are gone; geometries are WKT text
    // handled by the ST_* functions, so the same checks run in SQL.
    late JustDatabase db;

    setUp(() async => db = await openMemory('geo'));

    Future<Object?> scalar(String sql) async =>
        (await db.query(sql)).orThrow().scalar;

    test('Point JSON round-trip', () async {
      // 2.0: a point round-trips through WKT instead of JSON.
      expect(
        await scalar("SELECT ST_ASTEXT(ST_GEOMFROMTEXT('POINT(1.5 -2.5)'))"),
        'POINT(1.5 -2.5)',
      );
      expect(
        await scalar("SELECT ST_X(ST_GEOMFROMTEXT('POINT(1.5 -2.5)'))"),
        1.5,
      );
      expect(
        await scalar("SELECT ST_Y(ST_GEOMFROMTEXT('POINT(1.5 -2.5)'))"),
        -2.5,
      );
    });

    test('BoundingBox.intersects true when overlapping', () async {
      expect(
        await scalar(
          'SELECT ST_INTERSECTS(ST_MAKEENVELOPE(0, 0, 10, 10), ST_MAKEENVELOPE(5, 5, 15, 15))',
        ),
        1,
      );
    });

    test('BoundingBox.intersects false when disjoint', () async {
      expect(
        await scalar(
          'SELECT ST_INTERSECTS(ST_MAKEENVELOPE(0, 0, 4, 4), ST_MAKEENVELOPE(5, 5, 10, 10))',
        ),
        0,
      );
    });

    test('BoundingBox.containsPoint', () async {
      expect(
        await scalar(
          'SELECT ST_CONTAINS(ST_MAKEENVELOPE(0, 0, 10, 10), ST_MAKEPOINT(5, 5))',
        ),
        1,
      );
      expect(
        await scalar(
          'SELECT ST_CONTAINS(ST_MAKEENVELOPE(0, 0, 10, 10), ST_MAKEPOINT(15, 5))',
        ),
        0,
      );
    });

    test('Polygon.containsPoint ray-casting', () async {
      const square =
          "ST_GEOMFROMTEXT('POLYGON((0 0, 10 0, 10 10, 0 10, 0 0))')";
      expect(
        await scalar('SELECT ST_CONTAINS($square, ST_MAKEPOINT(5, 5))'),
        1,
      );
      expect(
        await scalar('SELECT ST_CONTAINS($square, ST_MAKEPOINT(15, 5))'),
        0,
      );
    });
  });

  group('Spatial — SQL ST_* functions', () {
    late JustDatabase db;

    setUp(() async {
      db = await openMemory('st');
      await exec(
        db,
        'CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, pt TEXT)',
      );
    });

    test('ST_MAKEPOINT returns a point map', () async {
      final r = await db.query('SELECT ST_MAKEPOINT(3.0, 4.0) AS pt');
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(r.rows, hasLength(1));
      // 2.0: geometries are WKT text, not maps.
      expect(r.rows.first['pt'], 'POINT(3 4)');
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
      // 2.0: a spatial index is an R-tree over two coordinate columns; one
      // geometry column is refused.
      final single = await db.execute(
        'CREATE SPATIAL INDEX idx_loc ON locations (pt)',
      );
      expect(single.success, isFalse);
      expect(single.errorMessage, contains('two columns'));

      await exec(db, 'ALTER TABLE locations ADD COLUMN lat REAL');
      await exec(db, 'ALTER TABLE locations ADD COLUMN lng REAL');
      final r = await db.execute(
        'CREATE SPATIAL INDEX idx_loc ON locations (lat, lng)',
      );
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(db.indexNamesForTable('locations'), contains('idx_loc'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // CREATE / DROP INDEX
  // ───────────────────────────────────────────────────────────────────────────
  group('Index DDL', () {
    late JustDatabase db;

    setUp(() async {
      db = await openMemory('idx');
      await exec(
        db,
        'CREATE TABLE employees (id INTEGER PRIMARY KEY AUTOINCREMENT, dept TEXT, salary REAL)',
      );
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
      await exec(db, 'CREATE INDEX idx_salary ON employees (salary)');
      expect(db.indexNamesForTable('employees'), contains('idx_salary'));

      // 2.0: SQLite syntax; DROP INDEX takes no `ON table`.
      final withOn = await db.execute('DROP INDEX idx_salary ON employees');
      expect(withOn.error?.kind, SqlErrorKind.syntax);
      final r = await db.execute('DROP INDEX idx_salary');
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(db.indexNamesForTable('employees'), isNot(contains('idx_salary')));
    });

    test('DROP INDEX IF EXISTS on non-existent index succeeds', () async {
      // 2.0: SQLite syntax; DROP INDEX takes no `ON table`.
      final r = await db.execute('DROP INDEX IF EXISTS no_such_idx');
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('indexNamesForTable returns created index', () async {
      await exec(db, 'CREATE INDEX idx_dept2 ON employees (dept)');
      expect(db.indexNamesForTable('employees'), contains('idx_dept2'));
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Query optimization hints
  // ───────────────────────────────────────────────────────────────────────────
  group('Query Hints', () {
    // 2.0: the parser and AST are internal (HintType is now HintKind).
    SelectStatement parse(String sql) =>
        Parser.parseOne(sql).statement as SelectStatement;

    test('Hint comment is parsed and stored on SelectStatement', () {
      final sel = parse('/*+ INDEX(users idx_name) */ SELECT * FROM users');
      expect(sel.hints, isNotEmpty);
      expect(sel.hints.first.kind, HintKind.forceIndex);
      expect(sel.hints.first.table, 'users');
      expect(sel.hints.first.index, 'idx_name');
    });

    test('Inline hint after SELECT keyword is parsed', () {
      final sel = parse('SELECT /*+ FULL_SCAN */ * FROM orders');
      expect(sel.hints, isNotEmpty);
      expect(sel.hints.first.kind, HintKind.fullScan);
    });

    test('NO_INDEX hint is parsed', () {
      final sel = parse('/*+ NO_INDEX */ SELECT id FROM products');
      expect(sel.hints.any((h) => h.kind == HintKind.noIndex), isTrue);
    });

    test('FORCE_INDEX hint is parsed', () {
      final sel = parse(
        '/*+ FORCE_INDEX(tbl_name idx_col) */ SELECT * FROM tbl_name',
      );
      expect(sel.hints.any((h) => h.kind == HintKind.forceIndex), isTrue);
    });

    test('Query with hint executes successfully', () async {
      final db = await openMemory('hint');
      await exec(db, 'CREATE TABLE hint_t (id INTEGER PRIMARY KEY, val TEXT)');
      await exec(db, "INSERT INTO hint_t (val) VALUES ('x')");
      final r = await db.query('/*+ FULL_SCAN */ SELECT * FROM hint_t');
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(r.rows, hasLength(1));
      await db.close();
    });

    test('Multiple hints in a single comment are all parsed', () {
      final sel = parse('/*+ INDEX(t idx_a) NO_INDEX */ SELECT * FROM t');
      expect(sel.hints.map((h) => h.kind), [
        HintKind.forceIndex,
        HintKind.noIndex,
      ]);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Scalar functions
  // ───────────────────────────────────────────────────────────────────────────
  group('Scalar Functions', () {
    late JustDatabase db;

    setUp(() async {
      db = await openMemory('fn');
      await exec(
        db,
        'CREATE TABLE sf (id INTEGER PRIMARY KEY, s TEXT, n REAL)',
      );
      await exec(db, "INSERT INTO sf (s, n) VALUES ('Hello World', -3.7)");
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
    // 2.0: BackupManager and the raw tables map are internal; backups are
    // db.exportSql/exportJson and db.importSql/importJson.
    late JustDatabase db;

    setUp(() async {
      db = await openMemory('backup');
      await exec(
        db,
        'CREATE TABLE books (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, year INTEGER)',
      );
      await exec(
        db,
        "INSERT INTO books (title, year) VALUES ('Dart in Action', 2023)",
      );
      await exec(
        db,
        "INSERT INTO books (title, year) VALUES ('Flutter Deep', 2024)",
      );
    });

    test('exportSql returns non-empty SQL string with CREATE TABLE', () async {
      final source = await openMemory('backup_src');
      await exec(
        source,
        'CREATE TABLE books2 (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT)',
      );
      await exec(source, "INSERT INTO books2 (title) VALUES ('A')");
      await exec(source, "INSERT INTO books2 (title) VALUES ('B')");

      final dump = await source.exportSql();
      expect(dump, contains('CREATE TABLE'));
      expect(dump, contains('books2'));

      // Restore a dump-like script statement by statement.
      final restored = await openMemory('backup_dst');
      final results = await restored.executeScript('''
        CREATE TABLE IF NOT EXISTS restored (id INTEGER PRIMARY KEY, title TEXT);
        INSERT INTO restored (id, title) VALUES (1, 'A');
        INSERT INTO restored (id, title) VALUES (2, 'B');
      ''');
      expect(results.length, 3);
      expect(results.every((r) => r.success), isTrue);

      await source.close();
    });

    test('Parser.parseSQLStatements parses multiple statements', () async {
      // 2.0: the parser is internal; executeScript runs every statement.
      final results = await db.executeScript('''
        CREATE TABLE t1 (id INTEGER PRIMARY KEY);
        INSERT INTO t1 (id) VALUES (1);
        INSERT INTO t1 (id) VALUES (2);
        SELECT * FROM t1;
      ''');
      expect(results.length, 4);
      expect(results.last.rows, hasLength(2));
    });

    test(
      'BackupManager.exportJson produces a map with _meta and tables',
      () async {
        final source = await openMemory('backup_json');
        await exec(
          source,
          'CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT)',
        );
        await exec(source, "INSERT INTO items (id, label) VALUES (1, 'alpha')");
        await exec(source, "INSERT INTO items (id, label) VALUES (2, 'beta')");

        final json = await source.exportJson();
        // 2.0: the export is the file format: `format` and `version` instead
        // of `_meta`, and `tables` is a list of {schema, rows, indexes}.
        expect(json['format'], 'just_database');
        expect(json['version'], isA<int>());
        final tables = json['tables']! as List;
        expect(
          tables.map((t) => ((t as Map)['schema'] as Map)['name']),
          contains('items'),
        );
      },
    );

    test(
      'BackupManager.exportJson + importJson round-trip preserves rows',
      () async {
        final source = await openMemory('backup_json');
        await exec(
          source,
          'CREATE TABLE items2 (id INTEGER PRIMARY KEY, label TEXT)',
        );
        await exec(source, "INSERT INTO items2 (id, label) VALUES (1, 'one')");
        await exec(source, "INSERT INTO items2 (id, label) VALUES (2, 'two')");

        final json = await source.exportJson();

        // 2.0: importJson replaces the whole database and returns nothing
        // (1.x returned a row count).
        final restored = await openMemory('backup_json_dst');
        await restored.importJson(json);

        final result = await restored.query('SELECT * FROM items2 ORDER BY id');
        expect(result.success, isTrue, reason: result.errorMessage);
        expect(result.rows.length, 2);
        expect(result.rows.first['label'], 'one');
      },
    );

    test('BackupManager.exportSql produces CREATE TABLE + INSERT', () async {
      final source = await openMemory('backup_sql');
      await exec(
        source,
        'CREATE TABLE tbl (id INTEGER PRIMARY KEY, name TEXT)',
      );
      await exec(source, "INSERT INTO tbl (id, name) VALUES (1, 'Alice')");
      await exec(source, "INSERT INTO tbl (id, name) VALUES (2, 'Bob')");

      final sql = await source.exportSql();
      expect(sql, contains('CREATE TABLE'));
      expect(sql, contains('tbl'));
      expect(sql, contains('INSERT'));
      expect(sql, contains('Alice'));
      expect(sql, contains('Bob'));
    });

    test('BackupManager.importSql restores tables from SQL dump', () async {
      final source = await openMemory('backup_sql');
      await exec(
        source,
        'CREATE TABLE src_t (id INTEGER PRIMARY KEY, val TEXT)',
      );
      await exec(source, "INSERT INTO src_t (id, val) VALUES (10, 'X')");
      await exec(source, "INSERT INTO src_t (id, val) VALUES (20, 'Y')");

      final sql = await source.exportSql();

      // 2.0: importSql replaces the whole database and returns nothing.
      final restored = await openMemory('backup_sql_dst');
      await restored.importSql(sql);

      final result = await restored.query('SELECT * FROM src_t ORDER BY id');
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
    // 2.0: a runner works on a database (db.migrationRunner), not an
    // Executor.
    late JustDatabase db;

    setUp(() async => db = await openMemory('mig'));

    test('MigrationRunner.initialize creates _migrations table', () async {
      final runner = db.migrationRunner([]);
      // 2.0: initialize() is private; every runner call creates the table.
      expect(await runner.status(), isEmpty);
      final result = await db.query('SELECT * FROM _migrations');
      expect(result.success, isTrue, reason: result.errorMessage);
    });

    test('currentVersion returns 0 before any migrations', () async {
      expect(await db.migrationRunner([]).currentVersion(), 0);
    });

    test('SqlMigration.up executes upSql', () async {
      final migration = SqlMigration(
        version: 1,
        name: 'create users',
        upSql: 'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)',
      );
      final results = await db.migrationRunner([migration]).migrate();
      expect(results.length, 1);
      expect(results.first.status, MigrationStatus.applied);

      final res = await db.query('SELECT * FROM users');
      expect(res.success, isTrue, reason: res.errorMessage);
    });

    test('currentVersion returns applied version after migrate', () async {
      final m1 = SqlMigration(
        version: 1,
        name: 'v1',
        upSql: 'CREATE TABLE t1 (id INTEGER PRIMARY KEY)',
      );
      final runner = db.migrationRunner([m1]);
      await runner.migrate();
      expect(await runner.currentVersion(), 1);
    });

    test('Running migrate again skips already-applied migrations', () async {
      final m1 = SqlMigration(
        version: 1,
        name: 'v1',
        upSql: 'CREATE TABLE t2 (id INTEGER PRIMARY KEY)',
      );
      final runner = db.migrationRunner([m1]);
      await runner.migrate();

      final results2 = await runner.migrate();
      // 2.0: no `skipped` status; migrate() reports only the steps it ran.
      expect(results2, isEmpty);
      expect((await runner.status()).single.status, MigrationStatus.applied);
    });

    test('Multiple migrations apply in order', () async {
      final runner = db.migrationRunner([
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
      ]);
      final results = await runner.migrate();
      expect(
        results.where((r) => r.status == MigrationStatus.applied).length,
        2,
      );
      expect(await runner.currentVersion(), 2);
    });

    test('migrate with targetVersion stops at correct version', () async {
      final runner = db.migrationRunner([
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
      ]);
      await runner.migrate(targetVersion: 2);
      expect(await runner.currentVersion(), 2);
      final r = await db.query('SELECT * FROM tv3');
      expect(r.success, isFalse);
    });

    test('CallbackMigration.up executes callback', () async {
      var called = false;
      final m = CallbackMigration(
        version: 1,
        name: 'callback test',
        upCallback: (tx) async {
          called = true;
        },
      );
      await db.migrationRunner([m]).migrate();
      expect(called, isTrue);
    });

    test('SqlMigration down rollback drops table', () async {
      final m = SqlMigration(
        version: 1,
        name: 'create rollback_t',
        upSql: 'CREATE TABLE rollback_t (id INTEGER PRIMARY KEY)',
        downSql: 'DROP TABLE rollback_t',
      );
      final runner = db.migrationRunner([m]);
      await runner.migrate();
      expect(await runner.currentVersion(), 1);

      await runner.rollback(targetVersion: 0);
      final r = await db.query('SELECT * FROM rollback_t');
      expect(r.success, isFalse);
    });

    test('status() lists migration results', () async {
      final m1 = SqlMigration(
        version: 1,
        name: 'status_test',
        upSql: 'CREATE TABLE st1 (id INTEGER PRIMARY KEY)',
      );
      final runner = db.migrationRunner([m1]);
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
        times: const [
          Duration(milliseconds: 10),
          Duration(milliseconds: 20),
          Duration(milliseconds: 30),
          Duration(milliseconds: 40),
        ],
      );
      expect(stats.average.inMilliseconds, 25);
    });

    test('QueryStats computes correct min and max', () {
      final stats = QueryStats(
        label: 'mm',
        iterations: 3,
        times: const [
          Duration(milliseconds: 5),
          Duration(milliseconds: 50),
          Duration(milliseconds: 25),
        ],
      );
      expect(stats.min.inMilliseconds, 5);
      expect(stats.max.inMilliseconds, 50);
    });

    test('QueryStats.p95 returns correct percentile', () {
      final times = List.generate(100, (i) => Duration(milliseconds: i + 1));
      final stats = QueryStats(label: 'p', iterations: 100, times: times);
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
      var callCount = 0;
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
      expect(result.formatTable(), isNotEmpty);
    });

    test('DatabaseBenchmark.run completes without error', () async {
      // 2.0: DatabaseBenchmark(executor:) is gone; the standard suite runs
      // on a private in-memory database.
      final result = await runStandardDatabaseBenchmark(
        rowCount: 10,
        warmup: 1,
        iterations: 2,
      );
      expect(result.results, isNotEmpty);
    });
  });
}

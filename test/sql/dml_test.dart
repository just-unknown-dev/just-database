// Audit probes for INSERT/UPDATE/DELETE, triggers, DDL and transactions in
// the SQL executor. Every test asserts the CORRECT behaviour.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import '../helpers/engine_harness.dart';

void main() {
  late Map<String, Object> tables;
  late EngineHarness ex;

  setUp(() async {
    tables = {};
    ex = EngineHarness(tables);
    for (final s in [
      'CREATE TABLE t (id INTEGER PRIMARY KEY, u INTEGER UNIQUE, name TEXT NOT NULL, note TEXT)',
      "INSERT INTO t (id, u, name) VALUES (1, 10, 'a'), (2, 20, 'b'), (3, 30, 'c')",
      'CREATE TABLE log (msg TEXT, ref INTEGER)',
    ]) {
      final r = await ex.executeSQL(s);
      expect(r.success, isTrue, reason: '$s -> ${r.errorMessage}');
    }
  });

  Future<QueryResult> sql(String s) => ex.executeSQL(s);
  Future<void> ok(String s) async {
    final r = await sql(s);
    expect(r.success, isTrue, reason: '$s -> ${r.errorMessage}');
  }

  Future<List<Map<String, dynamic>>> rows(String s) async {
    final r = await sql(s);
    expect(r.success, isTrue, reason: '$s -> ${r.errorMessage}');
    return r.rows;
  }

  Future<int> count(String table) async =>
      (await rows('SELECT * FROM $table')).length;

  group('statement atomicity', () {
    test('SQL-A1 failing multi-row INSERT inserts nothing', () async {
      final r = await sql(
        "INSERT INTO t (id, u, name) VALUES (4, 40, 'd'), (5, 50, 'e'), (1, 60, 'dup')",
      );
      expect(r.success, isFalse);
      expect(await count('t'), 3);
    });

    test('SQL-A2 failing multi-row UPDATE changes nothing', () async {
      // Row 2 takes u = 99 first, then row 3 collides with it.
      final r = await sql('UPDATE t SET u = 99 WHERE id >= 2');
      expect(r.success, isFalse);
      final u2 = (await rows('SELECT u FROM t WHERE id = 2')).single['u'];
      expect(u2, 20);
    });

    test('SQL-A3 failing AFTER INSERT trigger undoes the INSERT', () async {
      await ok('''CREATE TRIGGER bad AFTER INSERT ON t BEGIN
                  INSERT INTO no_such_table (x) VALUES (1); END''');
      final r = await sql("INSERT INTO t (id, u, name) VALUES (9, 90, 'z')");
      expect(r.success, isFalse);
      expect(await count('t'), 3);
    });
  });

  group('validation', () {
    test('SQL-I12 auto-assigned id continues after explicit ids', () async {
      // t already holds explicit ids 1, 2, 3.
      final r = await sql("INSERT INTO t (u, name) VALUES (40, 'd')");
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('SQL-I1 INSERT with more values than columns is an error', () async {
      await ok('CREATE TABLE two (a INTEGER, b INTEGER)');
      final r = await sql('INSERT INTO two VALUES (1, 2, 3)');
      expect(r.success, isFalse);
    });

    test('SQL-I2 INSERT with fewer values than columns is an error', () async {
      await ok('CREATE TABLE two (a INTEGER, b INTEGER)');
      final r = await sql('INSERT INTO two VALUES (1)');
      expect(r.success, isFalse);
    });

    test('SQL-I3 INSERT into an unknown column is an error', () async {
      final r = await sql(
        "INSERT INTO t (id, u, name, nmae) VALUES (4, 40, 'd', 'x')",
      );
      expect(r.success, isFalse);
    });

    test('SQL-I4 INSERT column names are case-insensitive', () async {
      await ok("INSERT INTO t (ID, U, NAME) VALUES (4, 40, 'd')");
      final r = await rows('SELECT name FROM t WHERE id = 4');
      expect(r.single['name'], 'd');
    });

    test('SQL-I4b UPDATE column names are case-insensitive', () async {
      await ok("UPDATE t SET NAME = 'zz' WHERE id = 1");
      final r = await rows('SELECT * FROM t WHERE id = 1');
      expect(r.single['name'], 'zz', reason: 'row is ${r.single}');
    });

    test('SQL-I5 UPDATE of an unknown column is an error', () async {
      final r = await sql("UPDATE t SET nmae = 'x' WHERE id = 1");
      expect(r.success, isFalse);
    });

    test('SQL-I6 UPDATE cannot set a NOT NULL column to NULL', () async {
      final r = await sql('UPDATE t SET name = NULL WHERE id = 1');
      expect(r.success, isFalse);
    });

    test('SQL-I7 unknown column in WHERE is an error (DELETE)', () async {
      final r = await sql('DELETE FROM t WHERE nmae IS NULL');
      expect(r.success, isFalse);
      expect(await count('t'), 3);
    });

    test('SQL-I8 unknown column on the right of SET is an error', () async {
      final r = await sql('UPDATE t SET note = nmae');
      expect(r.success, isFalse);
    });

    test('SQL-I9 UPDATE keeps a composite UNIQUE constraint', () async {
      await ok('CREATE TABLE cu (a INTEGER, b INTEGER, UNIQUE (a, b))');
      await ok('INSERT INTO cu (a, b) VALUES (1, 1), (1, 2)');
      final r = await sql('UPDATE cu SET b = 1 WHERE b = 2');
      expect(r.success, isFalse);
    });

    test('SQL-I10 ALTER TABLE ADD COLUMN keeps REFERENCES/ON DELETE', () async {
      await ok('CREATE TABLE p (id INTEGER PRIMARY KEY)');
      await ok('CREATE TABLE c (id INTEGER PRIMARY KEY)');
      await ok(
        'ALTER TABLE c ADD COLUMN pid INTEGER REFERENCES p (id) ON DELETE CASCADE',
      );
      final fk = ex.schemaOf('c')!.foreignKeys.single;
      expect(fk.parentTable, 'p');
      expect(fk.onDelete, ForeignKeyAction.cascade);
    });

    test('SQL-I11 DEFAULT CURRENT_TIMESTAMP is not silently NULL', () async {
      final r = await sql(
        'CREATE TABLE ts (id INTEGER, at DATETIME DEFAULT CURRENT_TIMESTAMP)',
      );
      if (r.success) {
        await ok('INSERT INTO ts (id) VALUES (1)');
        expect((await rows('SELECT at FROM ts')).single['at'], isNotNull);
      }
    });
  });

  group('triggers', () {
    test('SQL-G1 AFTER INSERT trigger sees the generated NEW.id', () async {
      await ok(
        'CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
      );
      await ok('''CREATE TRIGGER log_insert AFTER INSERT ON items BEGIN
                  INSERT INTO log (msg, ref) VALUES ('ins', NEW.id); END''');
      await ok("INSERT INTO items (name) VALUES ('w')");
      expect((await rows('SELECT ref FROM log')).single['ref'], 1);
    });

    test('SQL-G2 AFTER INSERT trigger sees column DEFAULTs in NEW', () async {
      await ok("CREATE TABLE d (id INTEGER PRIMARY KEY, s TEXT DEFAULT 'new')");
      await ok('''CREATE TRIGGER d_ins AFTER INSERT ON d BEGIN
                  INSERT INTO log (msg, ref) VALUES (NEW.s, NEW.id); END''');
      await ok('INSERT INTO d (id) VALUES (7)');
      expect((await rows('SELECT msg FROM log')).single['msg'], 'new');
    });

    test(
      'SQL-G3 CREATE TRIGGER IF NOT EXISTS keeps the existing trigger',
      () async {
        await ok('''CREATE TRIGGER tg AFTER INSERT ON t BEGIN
                  INSERT INTO log (msg) VALUES ('first'); END''');
        await ok('''CREATE TRIGGER IF NOT EXISTS tg AFTER INSERT ON t BEGIN
                  INSERT INTO log (msg) VALUES ('second'); END''');
        await ok("INSERT INTO t (id, u, name) VALUES (4, 40, 'd')");
        expect((await rows('SELECT msg FROM log')).single['msg'], 'first');
      },
    );

    test('SQL-G4 DROP TABLE drops its triggers', () async {
      await ok('''CREATE TRIGGER tg AFTER INSERT ON t BEGIN
                  INSERT INTO log (msg) VALUES ('old trigger'); END''');
      await ok('DROP TABLE t');
      await ok('CREATE TABLE t (id INTEGER)');
      await ok('INSERT INTO t (id) VALUES (1)');
      expect(await rows('SELECT * FROM log'), isEmpty);
    });

    test(
      'SQL-G5 a trigger that inserts into its own table does not recurse',
      () async {
        // SQLite (recursive_triggers OFF, the default) fires it once.
        await ok('CREATE TABLE r (n INTEGER)');
        await ok('''CREATE TRIGGER rec AFTER INSERT ON r WHEN (NEW.n < 50) BEGIN
                  INSERT INTO r (n) VALUES (NEW.n + 1); END''');
        await ok('INSERT INTO r (n) VALUES (1)');
        expect(await count('r'), 2);
      },
    );

    test(
      'SQL-G6 UPDATE OF col fires when col is assigned its old value',
      () async {
        await ok('''CREATE TRIGGER tu AFTER UPDATE OF name ON t BEGIN
                  INSERT INTO log (msg) VALUES ('fired'); END''');
        await ok("UPDATE t SET name = 'a' WHERE id = 1");
        expect(await rows('SELECT * FROM log'), hasLength(1));
      },
    );

    test('SQL-G7 CREATE TRIGGER on a missing table is an error', () async {
      final r = await sql('''CREATE TRIGGER x AFTER INSERT ON nosuch BEGIN
                  INSERT INTO log (msg) VALUES ('x'); END''');
      expect(r.success, isFalse);
    });

    test(
      'SQL-G8 trigger body SELECT ... WHERE false does not run RAISE',
      () async {
        // The SQLite validation idiom: only rows with a negative u are refused.
        await ok('''CREATE TRIGGER guard BEFORE INSERT ON t BEGIN
                  SELECT RAISE(ABORT, 'negative u') WHERE NEW.u < 0; END''');
        final r = await sql("INSERT INTO t (id, u, name) VALUES (4, 40, 'd')");
        expect(r.success, isTrue, reason: r.errorMessage);
      },
    );
  });

  group('transactions', () {
    test('SQL-X1 ROLLBACK undoes CREATE TRIGGER', () async {
      await ok('BEGIN');
      await ok('''CREATE TRIGGER tx_tg AFTER INSERT ON t BEGIN
                  INSERT INTO log (msg) VALUES ('tx'); END''');
      await ok('ROLLBACK');
      expect(ex.triggerNames, isNot(contains('tx_tg')));
    });

    test('SQL-X2 ROLLBACK undoes CREATE VIEW', () async {
      await ok('BEGIN');
      await ok('CREATE VIEW tx_v AS SELECT id FROM t');
      await ok('ROLLBACK');
      expect(ex.viewNames, isNot(contains('tx_v')));
    });

    test('SQL-X3 RELEASE a releases the later savepoint b too', () async {
      await ok('BEGIN');
      await ok('SAVEPOINT a');
      await ok('SAVEPOINT b');
      await ok('RELEASE a');
      final r = await sql('ROLLBACK TO b');
      expect(r.success, isFalse);
    });

    test('SQL-X4 savepoint names are case-insensitive', () async {
      await ok('BEGIN');
      await ok('SAVEPOINT Sp');
      final r = await sql('ROLLBACK TO sp');
      expect(r.success, isTrue, reason: r.errorMessage);
    });
  });

  group('QueryBuilder string building', () {
    late JustDatabase db;
    setUp(() async {
      db = await JustDatabase.open('sql_probe_qb', persist: false);
      await db.execute(
        'CREATE TABLE q (id INTEGER PRIMARY KEY, x REAL, at DATETIME)',
      );
    });
    tearDown(() => db.close());

    test('SQL-Q1 insert(double.infinity) is not silently NULL', () async {
      final r = await db.from('q').insert({'id': 1, 'x': double.infinity});
      if (r.success) {
        final x = (await db.query('SELECT x FROM q')).rows.single['x'];
        expect(x, double.infinity);
      }
    });

    test('SQL-Q2 insert(DateTime) works', () async {
      final r = await db.from('q').insert({'id': 2, 'at': DateTime.utc(2024)});
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test(
      'SQL-Q3 query() with a write statement is rejected or persisted',
      () async {
        // query() takes a read lock and never schedules a save.
        final r = await db.query('DELETE FROM q');
        expect(r.success, isFalse);
      },
    );
  });
}

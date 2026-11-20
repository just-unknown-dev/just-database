// Audit probes for the SQL lexer/parser. Every test asserts the CORRECT
// (SQLite-like or documented) behaviour, so a failing test marks a bug.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import '../helpers/engine_harness.dart';

void main() {
  late Map<String, Object> tables;
  late EngineHarness ex;

  setUp(() async {
    tables = {};
    ex = EngineHarness(tables);
    await ex.executeSQL(
      'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, dept TEXT)',
    );
    await ex.executeSQL(
      "INSERT INTO people (id, name, age, dept) VALUES "
      "(1, 'Ann', 30, 'a'), (2, 'Bob', NULL, 'b'), (3, 'Cid', 20, 'a'), (4, 'Dee', 40, NULL)",
    );
    await ex.executeSQL('CREATE TABLE depts (code TEXT, title TEXT)');
    await ex.executeSQL(
      "INSERT INTO depts (code, title) VALUES ('a', 'Alpha'), ('b', 'Beta')",
    );
  });

  Future<QueryResult> sql(String s) => ex.executeSQL(s);
  Future<List<Map<String, dynamic>>> rows(String s) async {
    final r = await sql(s);
    expect(r.success, isTrue, reason: '$s -> ${r.errorMessage}');
    return r.rows;
  }

  Future<int> count(String table) async =>
      (await rows('SELECT * FROM $table')).length;

  group('trailing tokens', () {
    test(
      'SQL-P1 DELETE with a misspelled WHERE must not delete every row',
      () async {
        final r = await sql('DELETE FROM people WHRE id = 1');
        expect(
          await count('people'),
          4,
          reason: 'rows deleted: ${r.affectedRows}',
        );
        expect(r.success, isFalse);
      },
    );

    test(
      'SQL-P2 UPDATE with a misspelled WHERE must not update every row',
      () async {
        final r = await sql("UPDATE people SET name = 'X' WEHRE id = 1");
        final names = (await rows(
          'SELECT name FROM people',
        )).map((r) => r['name']);
        expect(
          names.where((n) => n == 'X'),
          isEmpty,
          reason: 'updated ${r.affectedRows}',
        );
        expect(r.success, isFalse);
      },
    );

    test('SQL-P1b two statements in one call: both run, or an error', () async {
      final r = await sql(
        "INSERT INTO depts (code, title) VALUES ('c', 'C'); DELETE FROM depts WHERE code = 'a'",
      );
      if (r.success) {
        final codes = (await rows(
          'SELECT code FROM depts',
        )).map((e) => e['code']);
        expect(codes, isNot(contains('a')));
      }
    });

    test('SQL-P1c UNION is either supported or rejected', () async {
      final r = await sql(
        'SELECT code FROM depts UNION SELECT dept FROM people',
      );
      if (r.success) expect(r.rows, hasLength(3)); // a, b, NULL
    });

    test(
      'SQL-P1d HAVING without GROUP BY or aggregates is not ignored',
      () async {
        final r = await sql('SELECT name FROM people HAVING 1 = 0');
        if (r.success) expect(r.rows, isEmpty);
      },
    );

    test(
      'SQL-P3 comma join is either rejected or joined (not ignored)',
      () async {
        final r = await sql(
          'SELECT * FROM people, depts WHERE people.dept = depts.code',
        );
        if (r.success) expect(r.rows, hasLength(3));
      },
    );

    test('SQL-P4 LIMIT offset, count is either rejected or honoured', () async {
      final r = await sql('SELECT id FROM people ORDER BY id LIMIT 1, 2');
      if (r.success) {
        expect(r.rows.map((e) => e['id']).toList(), [2, 3]);
      }
    });

    test('SQL-P5 GROUP BY qualified column groups by that column', () async {
      final r = await sql(
        'SELECT dept, COUNT(*) AS n FROM people GROUP BY people.dept',
      );
      expect(r.success, isTrue, reason: r.errorMessage);
      expect(r.rows, hasLength(3)); // a, b, NULL
    });

    test('SQL-P5b GROUP BY expression is rejected or honoured', () async {
      final r = await sql(
        'SELECT COUNT(*) AS n FROM people GROUP BY LOWER(dept)',
      );
      if (r.success) expect(r.rows, hasLength(3));
    });
  });

  group('lexer', () {
    test('SQL-P6 double-quoted identifier', () async {
      final r = await rows('SELECT "name" FROM people WHERE id = 1');
      expect(r.single.values.single, 'Ann');
    });

    test('SQL-P6b backtick identifier', () async {
      final r = await rows('SELECT `name` FROM people WHERE id = 1');
      expect(r.single.values.single, 'Ann');
    });

    test('SQL-P7 unterminated string literal is an error', () async {
      final r = await sql("SELECT * FROM people WHERE name = 'Ann");
      expect(r.success, isFalse);
    });

    test('SQL-P8 || concatenation', () async {
      final r = await rows("SELECT 'a' || 'b' AS v");
      expect(r.single['v'], 'ab');
    });

    test(
      'SQL-P13 hex literal is 16 or an error, never 0 aliased x10',
      () async {
        final r = await sql('SELECT 0x10');
        if (r.success) expect(r.rows.single.values.single, 16);
      },
    );

    test('SQL-P14 blob literal X\'0102\' (emitted by the ORM)', () async {
      await sql('CREATE TABLE blobs (b BLOB)');
      final r = await sql("INSERT INTO blobs (b) VALUES (X'0102')");
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test(
      'SQL-P19 integer literal above 2^63 does not crash the lexer',
      () async {
        final r = await sql('SELECT 9223372036854775808 AS v');
        // SQLite turns it into a REAL.
        expect(r.success, isTrue, reason: r.errorMessage);
      },
    );

    test('SQL-P20 unicode identifier', () async {
      final r = await sql('CREATE TABLE café (id INTEGER)');
      expect(r.success, isTrue, reason: r.errorMessage);
    });
  });

  group('expressions', () {
    test('SQL-P9 CASE expression', () async {
      final r = await rows(
        "SELECT CASE WHEN age > 25 THEN 'old' ELSE 'young' END AS c FROM people WHERE id = 3",
      );
      expect(r.single['c'], 'young');
    });

    test('SQL-P10 CAST', () async {
      final r = await rows("SELECT CAST('5' AS INTEGER) AS v");
      expect(r.single['v'], 5);
    });

    test('SQL-P11 IN (subquery)', () async {
      final r = await rows(
        'SELECT name FROM people WHERE dept IN (SELECT code FROM depts) ORDER BY name',
      );
      expect(r.map((e) => e['name']).toList(), ['Ann', 'Bob', 'Cid']);
    });

    test('SQL-P12 EXISTS (subquery)', () async {
      final r = await rows(
        'SELECT name FROM people WHERE EXISTS (SELECT 1 FROM depts) ORDER BY name',
      );
      expect(r, hasLength(4));
    });

    test(
      'SQL-P21 a = b = c is parsed fully (not truncated after a = b)',
      () async {
        // SQLite: (1 = 1) = 0  ->  1 = 0  ->  0
        final r = await sql('SELECT 1 = 1 = 0 AS v');
        if (r.success) expect(r.rows.single['v'], anyOf(0, false));
      },
    );
  });

  group('DDL', () {
    test('SQL-P15 DEFAULT with a negative number', () async {
      final r = await sql('CREATE TABLE neg (a INTEGER DEFAULT -1)');
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('SQL-P16 common keywords as column names (text, count)', () async {
      final r = await sql(
        'CREATE TABLE notes (id INTEGER, text TEXT, count INTEGER)',
      );
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('SQL-P17 README trigger syntax: WHEN without parentheses', () async {
      await sql('CREATE TABLE users2 (id INTEGER PRIMARY KEY, email TEXT)');
      final r = await sql('''
        CREATE TRIGGER normalise_email
        BEFORE INSERT ON users2
        WHEN NEW.email IS NOT NULL
        BEGIN
          UPDATE users2 SET email = LOWER(NEW.email) WHERE id = NEW.id;
        END
      ''');
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('SQL-P18 README spatial index syntax (no index name)', () async {
      await sql(
        'CREATE TABLE locations (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, lat REAL, lng REAL)',
      );
      final r = await sql('CREATE SPATIAL INDEX ON locations (lat, lng)');
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('SQL-P22 duplicate column names are rejected', () async {
      final r = await sql('CREATE TABLE dup (a INTEGER, a TEXT)');
      expect(r.success, isFalse);
    });
  });
}

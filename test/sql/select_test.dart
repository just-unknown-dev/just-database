// Audit probes for SELECT semantics in the SQL executor. Every test asserts
// the CORRECT (SQLite-like or documented) behaviour; a failure marks a bug.
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
      'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT, age INTEGER, dept TEXT)',
      "INSERT INTO people (id, name, age, dept) VALUES "
          "(1, 'Ann', 30, 'a'), (2, 'Bob', NULL, 'b'), (3, 'Cid', 20, 'a'), (4, 'Dee', 40, NULL)",
      'CREATE TABLE empty_t (id INTEGER PRIMARY KEY, x INTEGER)',
      'CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT)',
      "INSERT INTO authors (id, name) VALUES (1, 'Austen'), (2, 'Bronte'), (3, 'Carroll')",
      'CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER, title TEXT)',
      "INSERT INTO books (id, author_id, title) VALUES (10, 1, 'Emma'), (11, 1, 'Persuasion'), (12, 2, 'Jane Eyre'), (13, NULL, 'Anon')",
    ]) {
      final r = await ex.executeSQL(s);
      expect(r.success, isTrue, reason: '$s -> ${r.errorMessage}');
    }
  });

  Future<QueryResult> sql(String s) => ex.executeSQL(s);
  Future<List<Map<String, dynamic>>> rows(String s) async {
    final r = await sql(s);
    expect(r.success, isTrue, reason: '$s -> ${r.errorMessage}');
    return r.rows;
  }

  Future<List<dynamic>> col(String s, String c) async =>
      (await rows(s)).map((r) => r[c]).toList();

  group('projection', () {
    test('SQL-E1 scalar function in SELECT list keeps every row', () async {
      final r = await rows('SELECT UPPER(name) AS n FROM people');
      expect(r, hasLength(4));
    });

    test('SQL-E1b README spatial distance query returns every row', () async {
      await sql(
        'CREATE TABLE loc (id INTEGER PRIMARY KEY, name TEXT, lat REAL, lng REAL)',
      );
      await sql(
        "INSERT INTO loc (name, lat, lng) VALUES ('P', 51.5, -0.1), ('Q', 52.0, 0.0), ('R', 53.0, 1.0)",
      );
      final r = await rows('''
        SELECT name, ST_DISTANCE(ST_MAKEPOINT(lat, lng), ST_MAKEPOINT(51.5, -0.1)) AS dist
        FROM loc ORDER BY dist LIMIT 5''');
      expect(r.map((e) => e['name']).toList(), ['P', 'Q', 'R']);
    });

    test('SQL-E2 two unaliased expressions give two columns', () async {
      final r = await rows('SELECT age + 1, age + 2 FROM people WHERE id = 1');
      expect(r.single.values.toList(), [31, 32]);
    });

    test('SQL-E3 a.id and b.id in a join give two columns', () async {
      final r = await rows(
        'SELECT authors.id, books.id FROM authors JOIN books ON authors.id = books.author_id WHERE books.id = 12',
      );
      expect(r.single.values.toList(), [2, 12]);
    });

    test('SQL-E4 COUNT(*) on an empty table is keyed "COUNT(*)"', () async {
      final r = await rows('SELECT COUNT(*) FROM empty_t');
      expect(r.single['COUNT(*)'], 0, reason: 'got ${r.single}');
    });

    test('SQL-E5 two aggregates on an empty table give two columns', () async {
      final r = await rows('SELECT COUNT(*), MAX(x) FROM empty_t');
      expect(r.single.length, 2, reason: 'got ${r.single}');
    });
  });

  group('aggregates', () {
    test('SQL-E6 COUNT(DISTINCT col)', () async {
      final r = await rows('SELECT COUNT(DISTINCT dept) AS n FROM people');
      expect(r.single['n'], 2);
    });

    test('SQL-E6b SUM(DISTINCT col)', () async {
      final r = await rows('SELECT SUM(DISTINCT age) AS s FROM people');
      expect(r.single['s'], 90);
      await sql(
        "INSERT INTO people (id, name, age, dept) VALUES (5, 'Eve', 30, 'a')",
      );
      final r2 = await rows('SELECT SUM(DISTINCT age) AS s FROM people');
      expect(r2.single['s'], 90);
    });

    test('SQL-E15 arithmetic on aggregates (MAX - MIN)', () async {
      final r = await rows('SELECT MAX(age) - MIN(age) AS spread FROM people');
      expect(r.single['spread'], 20);
    });

    test('SQL-E16 scalar function around an aggregate (ROUND(AVG))', () async {
      final r = await rows('SELECT ROUND(AVG(age), 1) AS a FROM people');
      expect(r.single['a'], 30.0);
    });

    test(
      'SQL-E17 admin UI sample: GROUP BY u.id gives one row per user',
      () async {
        final r = await rows(
          'SELECT a.name, COUNT(b.id) AS n FROM authors a LEFT JOIN books b ON a.id = b.author_id GROUP BY a.id ORDER BY n DESC',
        );
        expect(r.map((e) => e['n']).toList(), [2, 1, 0]);
      },
    );

    test('SQL-E7 SUM over no rows is NULL', () async {
      final r = await rows('SELECT SUM(x) AS s FROM empty_t');
      expect(r.single['s'], isNull);
    });

    test('SQL-E7b SUM over only NULLs is NULL', () async {
      final r = await rows('SELECT SUM(age) AS s FROM people WHERE id = 2');
      expect(r.single['s'], isNull);
    });

    test('SQL-E8 ORDER BY COUNT(*) after GROUP BY', () async {
      final r = await rows(
        'SELECT dept, COUNT(*) AS n FROM people GROUP BY dept ORDER BY COUNT(*) DESC',
      );
      expect(r.first['dept'], 'a');
    });

    test('SQL-E9 HAVING COUNT(*) BETWEEN', () async {
      final r = await rows(
        'SELECT dept FROM people GROUP BY dept HAVING COUNT(*) BETWEEN 2 AND 3',
      );
      expect(r.map((e) => e['dept']).toList(), ['a']);
    });

    test('SQL-E9b HAVING NOT', () async {
      final r = await rows(
        'SELECT dept FROM people GROUP BY dept HAVING NOT COUNT(*) > 1',
      );
      expect(r, hasLength(2));
    });

    test('SQL-E10 GROUP BY keeps NULL and the string NULL apart', () async {
      await sql(
        "INSERT INTO people (id, name, age, dept) VALUES (5, 'Eve', 1, 'NULL')",
      );
      final r = await rows(
        'SELECT dept, COUNT(*) AS n FROM people GROUP BY dept',
      );
      expect(r, hasLength(4)); // a, b, NULL, 'NULL'
    });

    test(
      'SQL-E10b GROUP BY a, b does not merge (x|y, z) with (x, y|z)',
      () async {
        await sql('CREATE TABLE g (a TEXT, b TEXT)');
        await sql("INSERT INTO g (a, b) VALUES ('x|y', 'z'), ('x', 'y|z')");
        final r = await rows('SELECT a, b, COUNT(*) AS n FROM g GROUP BY a, b');
        expect(r, hasLength(2));
      },
    );

    test('SQL-E11 DISTINCT keeps NULL and the string NULL apart', () async {
      await sql(
        "INSERT INTO people (id, name, age, dept) VALUES (5, 'Eve', 1, 'NULL')",
      );
      final r = await rows('SELECT DISTINCT dept FROM people');
      expect(r, hasLength(4));
    });

    test('SQL-E12 GROUP BY an unknown column is an error', () async {
      final r = await sql('SELECT COUNT(*) FROM people GROUP BY nosuch');
      expect(r.success, isFalse);
    });
  });

  group('ORDER BY', () {
    test('SQL-E13 ORDER BY a column that is not selected', () async {
      final names = await col(
        'SELECT name FROM people ORDER BY age DESC',
        'name',
      );
      expect(names, ['Dee', 'Ann', 'Cid', 'Bob']);
    });

    test('SQL-E14 ORDER BY position', () async {
      final names = await col(
        'SELECT id, name FROM people ORDER BY 2 DESC',
        'name',
      );
      expect(names, ['Dee', 'Cid', 'Bob', 'Ann']);
    });
  });

  group('three-valued NULL logic', () {
    test('SQL-N1 col = NULL matches nothing', () async {
      expect(await rows('SELECT * FROM people WHERE age = NULL'), isEmpty);
    });

    test('SQL-N2 col != 5 skips NULL', () async {
      expect(
        await col('SELECT id FROM people WHERE age != 30 ORDER BY id', 'id'),
        [3, 4],
      );
    });

    test('SQL-N3 col < 25 skips NULL', () async {
      expect(await col('SELECT id FROM people WHERE age < 25', 'id'), [3]);
    });

    test('SQL-N4 NOT (col = 30) skips NULL', () async {
      expect(
        await col(
          'SELECT id FROM people WHERE NOT (age = 30) ORDER BY id',
          'id',
        ),
        [3, 4],
      );
    });

    test('SQL-N5 NOT IN with a NULL in the list matches nothing', () async {
      expect(
        await rows('SELECT * FROM people WHERE age NOT IN (30, NULL)'),
        isEmpty,
      );
    });

    test('SQL-N6 NULL IN (..., NULL) is not true', () async {
      expect(
        await rows('SELECT * FROM people WHERE age IN (30, NULL) AND id = 2'),
        isEmpty,
      );
    });

    test('SQL-N7 NOT BETWEEN skips NULL', () async {
      expect(
        await col(
          'SELECT id FROM people WHERE age NOT BETWEEN 25 AND 35 ORDER BY id',
          'id',
        ),
        [3, 4],
      );
    });

    test('SQL-N8 NOT LIKE skips NULL', () async {
      expect(
        await col(
          "SELECT id FROM people WHERE dept NOT LIKE 'a' ORDER BY id",
          'id',
        ),
        [2],
      );
    });

    test('SQL-N9 NULL + 1 is NULL', () async {
      expect((await rows('SELECT NULL + 1 AS v')).single['v'], isNull);
    });

    test('SQL-N9b age * 2 is NULL for a NULL age', () async {
      expect(
        (await rows(
          'SELECT age * 2 AS v FROM people WHERE id = 2',
        )).single['v'],
        isNull,
      );
    });

    test('SQL-N10 JOIN ON never matches NULL to NULL', () async {
      await sql('CREATE TABLE l (k INTEGER)');
      await sql('CREATE TABLE r (k INTEGER)');
      await sql('INSERT INTO l (k) VALUES (NULL)');
      await sql('INSERT INTO r (k) VALUES (NULL)');
      expect(await rows('SELECT * FROM l JOIN r ON l.k = r.k'), isEmpty);
    });
  });

  group('types and functions', () {
    test("SQL-T1 '10' + 5 is 15 (SQLite numeric +)", () async {
      expect((await rows("SELECT '10' + 5 AS v")).single['v'], 15);
    });

    test('SQL-T2 -7 % 3 is -1 (truncated remainder)', () async {
      expect((await rows('SELECT -7 % 3 AS v')).single['v'], -1);
    });

    test('SQL-T3 BOOLEAN column compared with 1', () async {
      await sql('CREATE TABLE flags (id INTEGER PRIMARY KEY, active BOOLEAN)');
      await sql('INSERT INTO flags (id, active) VALUES (1, 1), (2, 0)');
      expect(await col('SELECT id FROM flags WHERE active = 1', 'id'), [1]);
    });

    test('SQL-T3b SUM of a BOOLEAN column', () async {
      await sql('CREATE TABLE flags (id INTEGER PRIMARY KEY, active BOOLEAN)');
      await sql('INSERT INTO flags (id, active) VALUES (1, 1), (2, 1), (3, 0)');
      expect((await rows('SELECT SUM(active) AS s FROM flags')).single['s'], 2);
    });

    test('SQL-T4 LIKE % matches across a newline', () async {
      await sql('CREATE TABLE notes (body TEXT)');
      await sql("INSERT INTO notes (body) VALUES ('line1\nline2')");
      expect(
        await rows("SELECT * FROM notes WHERE body LIKE 'line1%line2'"),
        hasLength(1),
      );
    });

    test(
      'SQL-T5 integer overflow does not wrap to a negative number',
      () async {
        final v = (await rows(
          'SELECT 9223372036854775807 + 1 AS v',
        )).single['v'];
        expect(v is num && v > 0, isTrue, reason: 'got $v');
      },
    );

    test('SQL-T6 ROUND(NULL) is NULL', () async {
      expect((await rows('SELECT ROUND(NULL) AS v')).single['v'], isNull);
    });

    test('SQL-T7 SUBSTR(NULL, 1) is NULL', () async {
      expect((await rows('SELECT SUBSTR(NULL, 1) AS v')).single['v'], isNull);
    });

    test("SQL-T8 REPLACE('abc', '', 'x') is 'abc'", () async {
      expect(
        (await rows("SELECT REPLACE('abc', '', 'x') AS v")).single['v'],
        'abc',
      );
    });

    test('SQL-T9 SUBSTR with a negative length does not crash', () async {
      final r = await sql("SELECT SUBSTR('hello', 3, -1) AS v");
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test('SQL-T10 SUBSTR with negative start counts from the end', () async {
      expect(
        (await rows("SELECT SUBSTR('hello', -3) AS v")).single['v'],
        'llo',
      );
    });
  });

  group('joins and subqueries', () {
    test('SQL-J1 ambiguous unqualified column is an error', () async {
      final r = await sql(
        'SELECT id FROM authors JOIN books ON authors.id = books.author_id',
      );
      expect(r.success, isFalse, reason: 'got ${r.rows}');
    });

    test(
      'SQL-J2 empty join result with a right-table column is not an error',
      () async {
        final r = await sql(
          'SELECT books.title FROM authors JOIN books ON authors.id = books.author_id + 100',
        );
        expect(r.success, isTrue, reason: r.errorMessage);
        expect(r.rows, isEmpty);
      },
    );

    test('SQL-J3 correlated scalar subquery', () async {
      final r = await rows('''
        SELECT name, (SELECT COUNT(*) FROM books WHERE books.author_id = authors.id) AS n
        FROM authors ORDER BY name''');
      expect(r.map((e) => e['n']).toList(), [2, 1, 0]);
    });

    test('SQL-J4 RIGHT JOIN rows all have the same columns', () async {
      final r = await rows(
        'SELECT * FROM books RIGHT JOIN authors ON books.author_id = authors.id',
      );
      final shapes = r.map((e) => (e.keys.toList()..sort()).join(',')).toSet();
      expect(shapes, hasLength(1), reason: shapes.join('\n'));
    });

    test(
      'SQL-J5 LEFT JOIN: unmatched left row keeps its own column values',
      () async {
        // authors.id is non-null for Carroll; the unqualified "id" must not be
        // replaced by the NULL padding of books.id (SQLite would reject the
        // ambiguous name; it must never silently read NULL).
        final r = await rows(
          "SELECT * FROM authors LEFT JOIN books ON authors.id = books.author_id WHERE authors.name = 'Carroll'",
        );
        expect(r.single['id'], 3, reason: 'got ${r.single}');
      },
    );
  });

  group('views and FROM-less SELECT', () {
    setUp(() async {
      await sql('CREATE VIEW v AS SELECT id, name, dept FROM people');
    });

    test('SQL-V1 COUNT(*) over a view', () async {
      expect((await rows('SELECT COUNT(*) AS n FROM v')).single['n'], 4);
    });

    test('SQL-V2 DISTINCT over a view', () async {
      expect(await rows('SELECT DISTINCT dept FROM v'), hasLength(3));
    });

    test('SQL-V3 JOIN on a view is applied (not dropped)', () async {
      await sql('CREATE TABLE depts (code TEXT, title TEXT)');
      await sql("INSERT INTO depts (code, title) VALUES ('a', 'Alpha')");
      final r = await sql(
        'SELECT v.name, depts.title FROM v JOIN depts ON v.dept = depts.code',
      );
      if (r.success) expect(r.rows, hasLength(2));
    });

    test('SQL-V4 GROUP BY over a view', () async {
      final r = await rows('SELECT dept, COUNT(*) AS n FROM v GROUP BY dept');
      expect(r, hasLength(3));
    });

    test('SQL-D1 SELECT without FROM honours WHERE', () async {
      expect(await rows('SELECT 1 AS one WHERE 1 = 0'), isEmpty);
    });
  });
}

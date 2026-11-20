import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/src/engine/engine.dart';
import 'package:just_database/src/sql/parser.dart';
import 'package:just_database/src/sql/sql_exception.dart';
import 'package:just_database/src/storage/catalog.dart';

void main() {
  late Engine e;
  StatementResult run(String sql, [List<Object?> p = const []]) =>
      e.execute(Parser.parseOne(sql), p);
  List<List<Object?>> q(String sql, [List<Object?> p = const []]) =>
      run(sql, p).rows;

  setUp(() {
    e = Engine(Catalog());
    run(
      'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER, dept TEXT)',
    );
    run(
      "INSERT INTO people (name, age, dept) VALUES ('Ann', 30, 'eng'), ('Bob', NULL, 'eng'), ('Cid', 25, 'ops'), ('Dee', 40, NULL)",
    );
  });

  test('basic select, where, order', () {
    expect(q('SELECT name FROM people WHERE age > 26 ORDER BY age DESC'), [
      ['Dee'],
      ['Ann'],
    ]);
    expect(q('SELECT name FROM people ORDER BY age DESC'), [
      ['Dee'],
      ['Ann'],
      ['Cid'],
      ['Bob'],
    ]);
    expect(run('SELECT id, name FROM people WHERE id = 3').rows, [
      [3, 'Cid'],
    ]);
  });

  test('three-valued logic', () {
    expect(q('SELECT name FROM people WHERE age != 30 ORDER BY name'), [
      ['Cid'],
      ['Dee'],
    ]);
    expect(q('SELECT name FROM people WHERE age = NULL'), isEmpty);
    expect(q('SELECT name FROM people WHERE age IS NULL'), [
      ['Bob'],
    ]);
    expect(q('SELECT NULL + 1, 1 IN (2, NULL), 1 NOT IN (2, 3)'), [
      [null, null, 1],
    ]);
  });

  test('aggregates and grouping', () {
    expect(
      q(
        'SELECT dept, COUNT(*), COUNT(age), SUM(age), AVG(age) FROM people GROUP BY dept ORDER BY dept',
      ),
      [
        [null, 1, 1, 40, 40.0],
        ['eng', 2, 1, 30, 30.0],
        ['ops', 1, 1, 25, 25.0],
      ],
    );
    expect(
      q('SELECT COUNT(*), SUM(age), MAX(age) - MIN(age) FROM people WHERE 0'),
      [
        [0, null, null],
      ],
    );
    expect(q('SELECT UPPER(name) FROM people ORDER BY 1'), [
      ['ANN'],
      ['BOB'],
      ['CID'],
      ['DEE'],
    ]);
    expect(q('SELECT COUNT(DISTINCT dept) FROM people'), [
      [2],
    ]);
    expect(
      q('SELECT dept, COUNT(*) AS n FROM people GROUP BY dept HAVING n > 1'),
      [
        ['eng', 2],
      ],
    );
    expect(q('SELECT name, MAX(age) FROM people'), [
      ['Dee', 40],
    ]);
  });

  test('result column names', () {
    final r = run(
      'SELECT age+1, age+2, COUNT(*) FROM people GROUP BY age ORDER BY age LIMIT 1',
    );
    expect(r.columns, ['age+1', 'age+2', 'COUNT(*)']);
  });

  test('joins', () {
    run(
      'CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER, title TEXT)',
    );
    run(
      "INSERT INTO books (author_id, title) VALUES (1, 'A1'), (1, 'A2'), (3, 'C1')",
    );
    expect(
      q(
        'SELECT p.name, b.title FROM people p JOIN books b ON b.author_id = p.id ORDER BY b.title',
      ),
      [
        ['Ann', 'A1'],
        ['Ann', 'A2'],
        ['Cid', 'C1'],
      ],
    );
    expect(
      q(
        'SELECT p.name, b.title FROM people p LEFT JOIN books b ON b.author_id = p.id WHERE b.id IS NULL ORDER BY p.name',
      ),
      [
        ['Bob', null],
        ['Dee', null],
      ],
    );
    expect(
      () =>
          q('SELECT id FROM people JOIN books ON books.author_id = people.id'),
      throwsA(isA<SqlException>()),
    );
    expect(
      q(
        'SELECT p.name, (SELECT COUNT(*) FROM books b WHERE b.author_id = p.id) FROM people p ORDER BY p.id',
      ),
      [
        ['Ann', 2],
        ['Bob', 0],
        ['Cid', 1],
        ['Dee', 0],
      ],
    );
    expect(
      q(
        'SELECT name FROM people WHERE id IN (SELECT author_id FROM books) ORDER BY name',
      ),
      [
        ['Ann'],
        ['Cid'],
      ],
    );
    expect(
      q(
        'SELECT name FROM people p WHERE NOT EXISTS (SELECT 1 FROM books WHERE author_id = p.id) ORDER BY name',
      ),
      [
        ['Bob'],
        ['Dee'],
      ],
    );
    expect(
      q(
        'SELECT b.title, p.name FROM books b RIGHT JOIN people p ON b.author_id = p.id ORDER BY p.id, b.title',
      ),
      [
        ['A1', 'Ann'],
        ['A2', 'Ann'],
        [null, 'Bob'],
        ['C1', 'Cid'],
        [null, 'Dee'],
      ],
    );
  });

  test('trailing text and multiple statements are errors', () {
    expect(
      () => q('DELETE FROM people WHRE id = 1'),
      throwsA(isA<SqlException>()),
    );
    expect(q('SELECT COUNT(*) FROM people'), [
      [4],
    ]);
    expect(
      () => Parser.parseOne('SELECT 1; SELECT 2'),
      throwsA(isA<SqlException>()),
    );
  });

  test('statement atomicity and constraints', () {
    run('CREATE TABLE u (id INTEGER PRIMARY KEY, v INTEGER UNIQUE)');
    run('INSERT INTO u (v) VALUES (1), (2)');
    expect(
      () => run('INSERT INTO u (v) VALUES (3), (1)'),
      throwsA(isA<SqlException>()),
    );
    expect(q('SELECT v FROM u ORDER BY v'), [
      [1],
      [2],
    ]);
    expect(() => run('UPDATE u SET v = 5'), throwsA(isA<SqlException>()));
    expect(q('SELECT v FROM u ORDER BY v'), [
      [1],
      [2],
    ]);
    run('CREATE TABLE k (a INTEGER, b TEXT, PRIMARY KEY (a))');
    run("INSERT INTO k VALUES (1, 'x')");
    expect(
      () => run("INSERT INTO k VALUES ('1', 'y')"),
      throwsA(isA<SqlException>()),
    );
    run('INSERT INTO u (id, v) VALUES (10, 10)');
    run('INSERT INTO u (v) VALUES (11)');
    expect(q('SELECT id FROM u WHERE v = 11'), [
      [11],
    ]);
  });

  test('transactions and savepoints', () {
    run('BEGIN');
    run("INSERT INTO people (name) VALUES ('Eve')");
    run('SAVEPOINT a');
    run("INSERT INTO people (name) VALUES ('Fay')");
    run('ROLLBACK TO a');
    run('COMMIT');
    expect(q("SELECT name FROM people WHERE name IN ('Eve', 'Fay')"), [
      ['Eve'],
    ]);
    run('BEGIN');
    run('CREATE VIEW v AS SELECT name FROM people');
    run('ROLLBACK');
    expect(() => q('SELECT * FROM v'), throwsA(isA<SqlException>()));
  });

  test('triggers, views, foreign keys', () {
    run('CREATE TABLE log (msg TEXT)');
    run(
      "CREATE TRIGGER t1 AFTER INSERT ON people WHEN NEW.age IS NOT NULL BEGIN INSERT INTO log VALUES ('added ' || NEW.id || ' ' || NEW.name); END",
    );
    run("INSERT INTO people (name, age) VALUES ('Gus', 50)");
    expect(q('SELECT msg FROM log'), [
      ['added 5 Gus'],
    ]);
    run('CREATE VIEW adults AS SELECT name, age FROM people WHERE age >= 30');
    expect(q('SELECT COUNT(*) FROM adults'), [
      [3],
    ]);
    run('CREATE TABLE parent (id INTEGER PRIMARY KEY)');
    run(
      'CREATE TABLE child (id INTEGER PRIMARY KEY, pid INTEGER REFERENCES parent(id) ON DELETE CASCADE)',
    );
    run('INSERT INTO parent VALUES (1), (2)');
    run('INSERT INTO child (pid) VALUES (1), (1), (2)');
    expect(
      () => run('INSERT INTO child (pid) VALUES (9)'),
      throwsA(isA<SqlException>()),
    );
    run('DELETE FROM parent WHERE id = 1');
    expect(q('SELECT pid FROM child'), [
      [2],
    ]);
  });

  test('upsert, case, cast, like, compound, params', () {
    run('CREATE TABLE kv (k TEXT PRIMARY KEY, v INTEGER)');
    run("INSERT INTO kv VALUES ('a', 1)");
    run(
      "INSERT INTO kv VALUES ('a', 5) ON CONFLICT(k) DO UPDATE SET v = v + excluded.v",
    );
    expect(q('SELECT v FROM kv'), [
      [6],
    ]);
    expect(
      q(
        "SELECT CASE WHEN 1 > 2 THEN 'x' ELSE 'y' END, CAST('12abc' AS INTEGER), 'ab' || 'cd', 'Hello' LIKE 'h%'",
      ),
      [
        ['y', 12, 'abcd', 1],
      ],
    );
    expect(q('SELECT 1 UNION SELECT 2 UNION SELECT 1 ORDER BY 1 DESC'), [
      [2],
      [1],
    ]);
    expect(
      q('SELECT name FROM people WHERE id = ? OR name = :n ORDER BY id', [
        1,
        'Cid',
      ]),
      [
        ['Ann'],
        ['Cid'],
      ],
    );
    expect(q("SELECT '10' + 5, -7 % 3, 7 / 2, 7.0 / 2, typeof(1e400)"), [
      [15, -1, 3, 3.5, 'real'],
    ]);
  });

  test('date functions', () {
    expect(
      q(
        "SELECT date('2024-01-31', '+1 month'), strftime('%Y/%m/%d %H', '2024-02-03 04:05:06')",
      ),
      [
        ['2024-03-02', '2024/02/03 04'],
      ],
    );
  });
}

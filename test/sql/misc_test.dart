// Audit probes: executor shared state under concurrency, result shape,
// DATETIME comparisons, and rough performance timings (printed, not asserted
// except where noted).
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import '../helpers/engine_harness.dart';

void main() {
  test(
    'SQL-R1 concurrent statements: each trigger sees its own NEW row',
    () async {
      final db = await JustDatabase.open('sql_probe_race', persist: false);
      await db.execute('CREATE TABLE a (v INTEGER)');
      await db.execute('CREATE TABLE b (v INTEGER)');
      await db.execute('CREATE TABLE log (src TEXT, v INTEGER)');
      await db.execute('''CREATE TRIGGER ta AFTER INSERT ON a BEGIN
        INSERT INTO log (src, v) VALUES ('a', NEW.v); END''');
      await db.execute('''CREATE TRIGGER tb AFTER INSERT ON b BEGIN
        INSERT INTO log (src, v) VALUES ('b', NEW.v); END''');
      // Different tables -> different write locks -> they interleave.
      await Future.wait([
        for (var i = 0; i < 20; i++) ...[
          db.execute('INSERT INTO a (v) VALUES ($i)'),
          db.execute('INSERT INTO b (v) VALUES (${1000 + i})'),
        ],
      ]);
      final log = (await db.query('SELECT src, v FROM log')).rows;
      final wrong = log
          .where((r) => (r['src'] == 'a') != ((r['v'] as int?) ?? -1) < 1000)
          .toList();
      expect(
        wrong,
        isEmpty,
        reason:
            '${wrong.length} of ${log.length} log rows read the other statement\'s NEW',
      );
      await db.close();
    },
  );

  group('result shape', () {
    late EngineHarness ex;
    setUp(() async {
      ex = EngineHarness({});
      await ex.executeSQL(
        'CREATE TABLE s (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)',
      );
    });

    test('SQL-S1 SELECT * returns columns in schema order', () async {
      await ex.executeSQL("INSERT INTO s (age, name, id) VALUES (5, 'x', 1)");
      final r = await ex.executeSQL('SELECT * FROM s');
      expect(r.columns, ['id', 'name', 'age']);
    });

    test('SQL-S2 columns are reported for an empty result', () async {
      final r = await ex.executeSQL('SELECT id, name FROM s');
      expect(r.columns, ['id', 'name']);
    });

    test("SQL-S3 DATETIME column = the literal it was inserted with", () async {
      await ex.executeSQL('CREATE TABLE ev (at DATETIME)');
      await ex.executeSQL("INSERT INTO ev (at) VALUES ('2024-01-01')");
      final r = await ex.executeSQL("SELECT * FROM ev WHERE at = '2024-01-01'");
      expect(r.rows, hasLength(1));
    });

    test(
      'SQL-S4 a /*+ comment in an expression position does not break parsing',
      () async {
        await ex.executeSQL("INSERT INTO s (id, name, age) VALUES (7, 'x', 1)");
        final r = await ex.executeSQL('SELECT id /*+ note */ FROM s');
        expect(r.success, isTrue, reason: r.errorMessage);
        expect(r.rows, [
          {'id': 7},
        ]);
      },
    );
  });

  group('timings (printed)', () {
    Future<EngineHarness> seeded(int n) async {
      final ex = EngineHarness({});
      await ex.executeSQL(
        'CREATE TABLE p (id INTEGER PRIMARY KEY, v INTEGER, s TEXT)',
      );
      await ex.executeSQL(
        'CREATE TABLE c (id INTEGER PRIMARY KEY, pid INTEGER)',
      );
      final buf = StringBuffer('INSERT INTO p (id, v, s) VALUES ');
      final buf2 = StringBuffer('INSERT INTO c (id, pid) VALUES ');
      for (var i = 0; i < n; i++) {
        if (i > 0) {
          buf.write(',');
          buf2.write(',');
        }
        buf.write("($i, ${i % 97}, 'name$i')");
        buf2.write('($i, $i)');
      }
      await ex.executeSQL(buf.toString());
      await ex.executeSQL(buf2.toString());
      return ex;
    }

    Future<int> time(EngineHarness ex, String q) async {
      final sw = Stopwatch()..start();
      final r = await ex.executeSQL(q);
      expect(r.success, isTrue, reason: '$q -> ${r.errorMessage}');
      return sw.elapsedMilliseconds;
    }

    test('SQL-PERF scaling (n vs 2n)', () async {
      for (final q in [
        'UPDATE p SET v = v + 1',
        'SELECT * FROM p WHERE id = 5',
        'SELECT DISTINCT s FROM p',
        'SELECT * FROM p JOIN c ON p.id = c.pid',
        'SELECT * FROM p WHERE v = (SELECT MAX(v) FROM p)',
        "SELECT * FROM p WHERE s LIKE '%99%'",
      ]) {
        final a = await time(await seeded(500), q);
        final b = await time(await seeded(1000), q);
        // ignore: avoid_print
        print('PERF ${a}ms@500 ${b}ms@1000  $q');
      }
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}

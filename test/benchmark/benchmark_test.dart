// Audit probes for the benchmark helpers.
// Every test asserts the CORRECT behaviour.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';

Future<JustDatabase> _db() => JustDatabase.open(
  'bench_${DateTime.now().microsecondsSinceEpoch}',
  persist: false,
);

void main() {
  test('STO bench-drops-user-table: the standard benchmark leaves a user '
      'table called _bench_t alone', () async {
    final db = await _db();
    await db.execute(
      'CREATE TABLE _bench_t (id INTEGER PRIMARY KEY, val INTEGER, '
      'label TEXT)',
    );
    await db.execute(
      "INSERT INTO _bench_t (val, label) VALUES (7, 'precious')",
    );
    await db.runStandardBenchmark(rowCount: 5, warmup: 0, iterations: 1);
    final r = await db.query("SELECT * FROM _bench_t WHERE label = 'precious'");
    expect(
      r.success && r.rows.isNotEmpty,
      isTrue,
      reason: 'user table: ${r.errorMessage ?? r.rows}',
    );
  });

  test('STO bench-error-timed: benchmarkQuery on failing SQL reports the '
      'failure instead of timings', () async {
    final db = await _db();
    Object? error;
    QueryStats? stats;
    try {
      stats = await db.benchmarkQuery(
        'broken',
        'SELECT * FROM no_such_table',
        warmup: 0,
        iterations: 3,
      );
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull, reason: 'got timings ${stats?.format()}');
  });

  test('STO bench-in-tx: the benchmark inside a transaction does not commit '
      'or roll back the caller\'s work', () async {
    final db = await _db();
    await db.execute('CREATE TABLE u (id INTEGER PRIMARY KEY)');
    await db.beginTransaction();
    await db.execute('INSERT INTO u (id) VALUES (1)');
    await db.runStandardBenchmark(rowCount: 3, warmup: 0, iterations: 1);
    expect(db.inTransaction, isTrue);
    await db.rollback();
    final r = await db.query('SELECT * FROM u');
    expect(r.rows, isEmpty);
    expect(db.tableNames, isNot(contains('_bench_t')));
  });
}

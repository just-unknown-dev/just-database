import 'dart:async';
import 'dart:math';

import 'database_mode.dart';
import 'just_database.dart';
import '../sql/parser.dart';

/// Timings of one benchmarked operation.
class QueryStats {
  /// Creates statistics from [times].
  const QueryStats({
    required this.label,
    required this.iterations,
    required this.times,
  });

  final String label;
  final int iterations;

  /// Every measured run.
  final List<Duration> times;

  Duration get total => times.fold(Duration.zero, (a, d) => a + d);
  Duration get min =>
      times.isEmpty ? Duration.zero : times.reduce((a, b) => a < b ? a : b);
  Duration get max =>
      times.isEmpty ? Duration.zero : times.reduce((a, b) => a > b ? a : b);
  Duration get average => times.isEmpty
      ? Duration.zero
      : Duration(microseconds: total.inMicroseconds ~/ times.length);

  Duration get median {
    if (times.isEmpty) return Duration.zero;
    final sorted = List.of(times)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return Duration(
      microseconds:
          (sorted[mid - 1].inMicroseconds + sorted[mid].inMicroseconds) ~/ 2,
    );
  }

  Duration _percentile(double p) {
    if (times.isEmpty) return Duration.zero;
    final sorted = List.of(times)..sort();
    return sorted[((p / 100) * (sorted.length - 1)).round()];
  }

  Duration get p95 => _percentile(95);
  Duration get p99 => _percentile(99);

  /// Operations per second.
  double get throughput {
    final ms = total.inMicroseconds / 1000.0;
    return ms == 0 ? double.infinity : iterations * 1000.0 / ms;
  }

  /// One line of text.
  String format({String indent = ''}) =>
      '$indent$label: avg=${_ms(average)} min=${_ms(min)} max=${_ms(max)} '
      'p95=${_ms(p95)} p99=${_ms(p99)} '
      'throughput=${throughput.toStringAsFixed(0)} ops/s (n=$iterations)';

  static String _ms(Duration d) =>
      '${(d.inMicroseconds / 1000.0).toStringAsFixed(2)}ms';
}

/// One benchmarked operation.
class BenchmarkCase {
  const BenchmarkCase({
    required this.name,
    required this.body,
    this.setup,
    this.teardown,
  });
  final String name;
  final Future<void> Function() body;
  final Future<void> Function()? setup;
  final Future<void> Function()? teardown;
}

/// The results of a suite.
class BenchmarkSuiteResult {
  const BenchmarkSuiteResult({
    required this.suiteName,
    required this.results,
    required this.runAt,
  });
  final String suiteName;
  final List<QueryStats> results;
  final DateTime runAt;

  /// The results as text.
  String formatTable() {
    final b = StringBuffer(
      '=== Benchmark: $suiteName (${runAt.toIso8601String()}) ===\n',
    );
    for (final r in results) {
      b.writeln(r.format(indent: '  '));
    }
    return b.toString();
  }
}

/// Runs [BenchmarkCase]s: warm-up runs, then measured runs, yielding to the
/// event loop between runs so a UI stays responsive.
class BenchmarkSuite {
  BenchmarkSuite({
    required this.name,
    this.warmupIterations = 5,
    this.measureIterations = 100,
  });

  final String name;
  final List<BenchmarkCase> cases = [];
  final int warmupIterations;
  final int measureIterations;

  void add(BenchmarkCase bc) => cases.add(bc);

  void addCase(
    String caseName,
    Future<void> Function() body, {
    Future<void> Function()? setup,
    Future<void> Function()? teardown,
  }) => cases.add(
    BenchmarkCase(name: caseName, body: body, setup: setup, teardown: teardown),
  );

  /// Runs every case.
  Future<BenchmarkSuiteResult> run() async {
    final results = <QueryStats>[];
    for (final bc in cases) {
      await bc.setup?.call();
      try {
        for (var i = 0; i < warmupIterations; i++) {
          await bc.body();
          await Future<void>.delayed(Duration.zero);
        }
        final times = <Duration>[];
        final watch = Stopwatch();
        for (var i = 0; i < measureIterations; i++) {
          watch
            ..reset()
            ..start();
          await bc.body();
          watch.stop();
          times.add(watch.elapsed);
          await Future<void>.delayed(Duration.zero);
        }
        results.add(
          QueryStats(
            label: bc.name,
            iterations: measureIterations,
            times: times,
          ),
        );
      } finally {
        await bc.teardown?.call();
      }
    }
    return BenchmarkSuiteResult(
      suiteName: name,
      results: results,
      runAt: DateTime.now(),
    );
  }
}

/// Benchmarks for databases.
extension JustDatabaseBenchmark on JustDatabase {
  /// Runs the standard suite (inserts, lookups, updates, deletes, counts,
  /// sorting, a join and parsing) against a private in-memory database of
  /// [rowCount] rows, so this database is never touched.
  Future<BenchmarkSuiteResult> runStandardBenchmark({
    int rowCount = 1000,
    int warmup = 3,
    int iterations = 50,
  }) => runStandardDatabaseBenchmark(
    rowCount: rowCount,
    warmup: warmup,
    iterations: iterations,
  );

  /// Times the read-only [sql] (a SELECT) on this database. Throws the
  /// statement's `SqlException` when it fails.
  Future<QueryStats> benchmarkQuery(
    String label,
    String sql, {
    Object? parameters,
    int warmup = 3,
    int iterations = 50,
  }) async {
    for (var i = 0; i < warmup; i++) {
      (await query(sql, parameters)).orThrow();
      await Future<void>.delayed(Duration.zero);
    }
    final times = <Duration>[];
    final watch = Stopwatch();
    for (var i = 0; i < iterations; i++) {
      watch
        ..reset()
        ..start();
      (await query(sql, parameters)).orThrow();
      watch.stop();
      times.add(watch.elapsed);
      await Future<void>.delayed(Duration.zero);
    }
    return QueryStats(label: label, iterations: iterations, times: times);
  }
}

/// The standard suite on a private in-memory database; see
/// [JustDatabaseBenchmark.runStandardBenchmark].
Future<BenchmarkSuiteResult> runStandardDatabaseBenchmark({
  int rowCount = 1000,
  int warmup = 3,
  int iterations = 50,
}) async {
  final name = '__bench_${Random().nextInt(1 << 30)}';
  final db = await JustDatabase.open(
    name,
    persist: false,
    mode: DatabaseMode.standard,
  );
  try {
    (await db.execute(
      'CREATE TABLE t (id INTEGER PRIMARY KEY, val INTEGER, label TEXT)',
    )).orThrow();
    (await db.execute('CREATE INDEX t_val ON t (val)')).orThrow();
    (await db.execute(
      'CREATE TABLE u (id INTEGER PRIMARY KEY, t_id INTEGER, note TEXT)',
    )).orThrow();
    await db.transaction((tx) async {
      for (var i = 1; i <= rowCount; i++) {
        await tx.execute('INSERT INTO t (id, val, label) VALUES (?, ?, ?)', [
          i,
          i % 100,
          'row $i',
        ]);
        await tx.execute('INSERT INTO u (t_id, note) VALUES (?, ?)', [
          i,
          'note $i',
        ]);
      }
    });
    final suite =
        BenchmarkSuite(
            name: 'Just Database, $rowCount rows',
            warmupIterations: warmup,
            measureIterations: iterations,
          )
          ..addCase('INSERT one row', () async {
            (await db.execute('INSERT INTO t (val, label) VALUES (?, ?)', [
              42,
              'new',
            ])).orThrow();
          })
          ..addCase('SELECT 100 rows', () async {
            (await db.query('SELECT * FROM t LIMIT 100')).orThrow();
          })
          ..addCase('SELECT by primary key', () async {
            (await db.query('SELECT * FROM t WHERE id = ?', [
              rowCount ~/ 2,
            ])).orThrow();
          })
          ..addCase('SELECT by indexed column', () async {
            (await db.query('SELECT * FROM t WHERE val = ?', [7])).orThrow();
          })
          ..addCase('UPDATE by primary key', () async {
            (await db.execute('UPDATE t SET label = ? WHERE id = ?', [
              'changed',
              1,
            ])).orThrow();
          })
          ..addCase('INSERT + DELETE by key', () async {
            final r = (await db.execute(
              'INSERT INTO t (val, label) VALUES (0, ?)',
              ['tmp'],
            )).orThrow();
            (await db.execute('DELETE FROM t WHERE id = ?', [
              r.lastInsertRowId,
            ])).orThrow();
          })
          ..addCase('SELECT COUNT(*)', () async {
            (await db.query('SELECT COUNT(*) FROM t')).orThrow();
          })
          ..addCase('ORDER BY with LIMIT', () async {
            (await db.query(
              'SELECT * FROM t ORDER BY val DESC, id LIMIT 10',
            )).orThrow();
          })
          ..addCase('JOIN on key', () async {
            (await db.query(
              'SELECT COUNT(*) FROM t JOIN u ON u.t_id = t.id',
            )).orThrow();
          })
          ..addCase('Parse only', () async {
            Parser.parseOne(
              'SELECT id, val FROM t WHERE val > 50 ORDER BY id LIMIT 5',
            );
          });
    return await suite.run();
  } finally {
    await db.close();
  }
}

/// Formats [stats] as an aligned table.
String formatQueryStats(List<QueryStats> stats) {
  final b = StringBuffer();
  final width = stats.fold<int>(10, (w, s) => max(w, s.label.length));
  b.writeln('${'Case'.padRight(width)}  avg(ms)  p95(ms)  ops/s');
  for (final s in stats) {
    b.writeln(
      '${s.label.padRight(width)}  '
      '${(s.average.inMicroseconds / 1000).toStringAsFixed(2).padLeft(7)}  '
      '${(s.p95.inMicroseconds / 1000).toStringAsFixed(2).padLeft(7)}  '
      '${s.throughput.toStringAsFixed(0)}',
    );
  }
  return b.toString();
}

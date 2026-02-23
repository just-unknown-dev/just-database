import '../sql/executor.dart';
import '../sql/parser.dart';

/// Statistics for a single query or operation.
class QueryStats {
  final String label;
  final int iterations;
  final List<Duration> times;

  const QueryStats({
    required this.label,
    required this.iterations,
    required this.times,
  });

  Duration get total => times.fold(Duration.zero, (acc, d) => acc + d);

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
    final idx = ((p / 100) * (sorted.length - 1)).round();
    return sorted[idx];
  }

  Duration get p95 => _percentile(95);
  Duration get p99 => _percentile(99);

  /// Operations per second based on total time.
  double get throughput {
    final totalMs = total.inMicroseconds / 1000.0;
    if (totalMs == 0) return double.infinity;
    return (iterations * 1000.0) / totalMs;
  }

  /// Returns a human-readable summary line.
  String format({String indent = ''}) {
    return '$indent$label: '
        'avg=${_us(average)} min=${_us(min)} max=${_us(max)} '
        'p95=${_us(p95)} p99=${_us(p99)} '
        'throughput=${throughput.toStringAsFixed(0)} ops/s '
        '(n=$iterations)';
  }

  static String _us(Duration d) =>
      '${(d.inMicroseconds / 1000.0).toStringAsFixed(2)}ms';
}

/// A single benchmark test case.
class BenchmarkCase {
  final String name;
  final Future<void> Function() body;
  final Future<void> Function()? setup;
  final Future<void> Function()? teardown;

  const BenchmarkCase({
    required this.name,
    required this.body,
    this.setup,
    this.teardown,
  });
}

/// Result from running a full [BenchmarkSuite].
class BenchmarkSuiteResult {
  final String suiteName;
  final List<QueryStats> results;
  final DateTime runAt;

  const BenchmarkSuiteResult({
    required this.suiteName,
    required this.results,
    required this.runAt,
  });

  String formatTable() {
    final buf = StringBuffer();
    buf.writeln('=== Benchmark: $suiteName (${runAt.toIso8601String()}) ===');
    for (final r in results) {
      buf.writeln(r.format(indent: '  '));
    }
    return buf.toString();
  }
}

/// A collection of named benchmark cases that can be run together.
class BenchmarkSuite {
  final String name;
  final List<BenchmarkCase> cases = [];
  final int warmupIterations;
  final int measureIterations;

  BenchmarkSuite({
    required this.name,
    this.warmupIterations = 5,
    this.measureIterations = 100,
  });

  void add(BenchmarkCase bc) => cases.add(bc);

  /// Convenience method to add a benchmark with just a body function.
  void addCase(
    String caseName,
    Future<void> Function() body, {
    Future<void> Function()? setup,
    Future<void> Function()? teardown,
  }) {
    cases.add(
      BenchmarkCase(
        name: caseName,
        body: body,
        setup: setup,
        teardown: teardown,
      ),
    );
  }

  Future<BenchmarkSuiteResult> run() async {
    final results = <QueryStats>[];
    for (final bc in cases) {
      final stats = await _runCase(bc);
      results.add(stats);
    }
    return BenchmarkSuiteResult(
      suiteName: name,
      results: results,
      runAt: DateTime.now(),
    );
  }

  Future<QueryStats> _runCase(BenchmarkCase bc) async {
    // Warm-up
    for (int i = 0; i < warmupIterations; i++) {
      await bc.setup?.call();
      await bc.body();
      await bc.teardown?.call();
    }

    // Measurement
    final times = <Duration>[];
    for (int i = 0; i < measureIterations; i++) {
      await bc.setup?.call();
      final start = DateTime.now();
      await bc.body();
      times.add(DateTime.now().difference(start));
      await bc.teardown?.call();
    }
    return QueryStats(
      label: bc.name,
      iterations: measureIterations,
      times: times,
    );
  }
}

/// Pre-built benchmark scenarios for JustDatabase.
class DatabaseBenchmark {
  final Executor executor;
  final int rowCount;

  DatabaseBenchmark({required this.executor, this.rowCount = 1000});

  /// Runs the standard benchmark suite and returns formatted results.
  Future<BenchmarkSuiteResult> run({int? warmup, int? iterations}) async {
    final suite = BenchmarkSuite(
      name: 'JustDatabase v$rowCount rows',
      warmupIterations: warmup ?? 3,
      measureIterations: iterations ?? 50,
    );

    await _setupBenchmarkTables();

    suite.addCase(
      'INSERT single row',
      () => executor.executeSQL(
        "INSERT INTO _bench_t (val, label) VALUES (42, 'test')",
      ),
    );

    suite.addCase(
      'SELECT * (no index)',
      () => executor.executeSQL('SELECT * FROM _bench_t LIMIT 100'),
    );

    suite.addCase(
      'SELECT WHERE by indexed column',
      () => executor.executeSQL('SELECT * FROM _bench_t WHERE id = 1'),
    );

    suite.addCase(
      'UPDATE single row',
      () => executor.executeSQL(
        "UPDATE _bench_t SET label = 'updated' WHERE id = 1",
      ),
    );

    suite.addCase('DELETE single row', () async {
      // Re-insert to avoid running out of rows
      await executor.executeSQL(
        "INSERT INTO _bench_t (id, val, label) VALUES (99999, 0, 'del')",
      );
      await executor.executeSQL('DELETE FROM _bench_t WHERE id = 99999');
    });

    suite.addCase(
      'SELECT COUNT(*)',
      () => executor.executeSQL('SELECT COUNT(*) AS c FROM _bench_t'),
    );

    suite.addCase(
      'SELECT with ORDER BY',
      () => executor.executeSQL(
        'SELECT * FROM _bench_t ORDER BY val DESC LIMIT 10',
      ),
    );

    suite.addCase(
      'SQL parse only (no execute)',
      () async =>
          Parser.parseSQL('SELECT id, val FROM _bench_t WHERE val > 50'),
    );

    final result = await suite.run();
    await _teardownBenchmarkTables();
    return result;
  }

  /// Runs a single SQL query benchmarked [iterations] times.
  Future<QueryStats> runQuery(
    String label,
    String sql, {
    int warmup = 3,
    int iterations = 100,
  }) async {
    // Warm-up
    for (int i = 0; i < warmup; i++) {
      await executor.executeSQL(sql);
    }
    final times = <Duration>[];
    for (int i = 0; i < iterations; i++) {
      final start = DateTime.now();
      await executor.executeSQL(sql);
      times.add(DateTime.now().difference(start));
    }
    return QueryStats(label: label, iterations: iterations, times: times);
  }

  /// Sets up benchmark support tables with [rowCount] rows.
  Future<void> _setupBenchmarkTables() async {
    await executor.executeSQL('DROP TABLE IF EXISTS _bench_t');
    await executor.executeSQL('''
      CREATE TABLE _bench_t (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        val INTEGER,
        label TEXT
      )
    ''');
    // Bulk insert
    final batch = StringBuffer();
    for (int i = 0; i < rowCount; i++) {
      if (i > 0) batch.write('; ');
      batch.write(
        "INSERT INTO _bench_t (val, label) VALUES (${i % 1000}, 'row_$i')",
      );
    }
    final stmts = Parser.parseSQLStatements(batch.toString());
    for (final stmt in stmts) {
      await executor.execute(stmt);
    }
  }

  Future<void> _teardownBenchmarkTables() async {
    await executor.executeSQL('DROP TABLE IF EXISTS _bench_t');
  }

  /// Formats a list of [QueryStats] results as a text table.
  static String formatTable(List<QueryStats> stats) {
    final colWidth = stats.fold(
      10,
      (w, s) => s.label.length > w ? s.label.length : w,
    );
    final buf = StringBuffer();
    final header =
        '${'Operation'.padRight(colWidth)}  ${'Avg(ms)'.padLeft(8)}  '
        '${'Min(ms)'.padLeft(8)}  ${'Max(ms)'.padLeft(8)}  '
        '${'P95(ms)'.padLeft(8)}  ${'ops/s'.padLeft(10)}';
    buf.writeln(header);
    buf.writeln('-' * header.length);
    for (final s in stats) {
      buf.writeln(
        '${s.label.padRight(colWidth)}  '
        '${_ms(s.average).padLeft(8)}  '
        '${_ms(s.min).padLeft(8)}  '
        '${_ms(s.max).padLeft(8)}  '
        '${_ms(s.p95).padLeft(8)}  '
        '${s.throughput.toStringAsFixed(0).padLeft(10)}',
      );
    }
    return buf.toString();
  }

  static String _ms(Duration d) =>
      (d.inMicroseconds / 1000.0).toStringAsFixed(3);
}

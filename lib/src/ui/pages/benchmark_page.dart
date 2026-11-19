import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../benchmark/benchmark.dart';
import '../../core/just_database.dart';
import '../../sql/sql_exception.dart';
import '../admin_utils.dart';
import '../widgets/admin_widgets.dart';

/// Runs the standard benchmark suite, or times a SELECT on [database].
///
/// The standard suite runs on a private in-memory database, so no data is
/// touched; it yields to the event loop between runs, so the page stays
/// responsive. A custom query must be a SELECT (it runs through
/// `JustDatabase.query`, which refuses anything else).
class BenchmarkPage extends StatefulWidget {
  /// Creates the page. Without a [database] only the standard suite runs.
  const BenchmarkPage({super.key, this.database});

  /// The database custom queries run on.
  final JustDatabase? database;

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  final _formKey = GlobalKey<FormState>();
  final _rowCount = TextEditingController(text: '1000');
  final _warmup = TextEditingController(text: '3');
  final _iterations = TextEditingController(text: '50');
  final _query = TextEditingController(text: 'SELECT * FROM users LIMIT 100');
  final _label = TextEditingController(text: 'My query');

  bool _custom = false;
  bool _running = false;
  String? _error;
  BenchmarkSuiteResult? _suiteResult;
  QueryStats? _customResult;

  @override
  void dispose() {
    _rowCount.dispose();
    _warmup.dispose();
    _iterations.dispose();
    _query.dispose();
    _label.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running || !(_formKey.currentState?.validate() ?? false)) return;
    final warmup = int.parse(_warmup.text.trim());
    final iterations = int.parse(_iterations.text.trim());
    final db = widget.database;
    setState(() {
      _running = true;
      _error = null;
      _suiteResult = null;
      _customResult = null;
    });
    try {
      if (_custom) {
        if (db == null || !db.isOpen) {
          throw StateError('No open database to run the query on.');
        }
        final label = _label.text.trim().isEmpty
            ? 'Custom query'
            : _label.text.trim();
        final stats = await db.benchmarkQuery(
          label,
          _query.text,
          warmup: warmup,
          iterations: iterations,
        );
        if (!mounted) return;
        setState(() => _customResult = stats);
      } else {
        final rows = int.parse(_rowCount.text.trim());
        final result = db != null && db.isOpen
            ? await db.runStandardBenchmark(
                rowCount: rows,
                warmup: warmup,
                iterations: iterations,
              )
            : await runStandardDatabaseBenchmark(
                rowCount: rows,
                warmup: warmup,
                iterations: iterations,
              );
        if (!mounted) return;
        setState(() => _suiteResult = result);
      }
    } on SqlException catch (e) {
      if (!mounted) return;
      setState(() => _error = 'The query failed: ${e.message}');
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = describeError(e));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  void _clear() => setState(() {
    _suiteResult = null;
    _customResult = null;
    _error = null;
  });

  String? _intError(String? text, int min, int max) {
    final v = int.tryParse((text ?? '').trim());
    if (v == null) return 'Enter a whole number';
    if (v < min || v > max) return 'Use $min to $max';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final db = widget.database;
    final suite = _suiteResult;
    final custom = _customResult;
    final Widget results;
    if (_running) {
      results = const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Benchmarking…'),
          ],
        ),
      );
    } else if (!_custom && suite != null) {
      results = _SuiteResultView(result: suite);
    } else if (_custom && custom != null) {
      results = ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        children: [
          _StatCard(stats: custom, maxThroughput: custom.throughput),
          const SizedBox(height: 8),
          _CopyButton(text: formatQueryStats([custom])),
        ],
      );
    } else {
      results = EmptyState(
        icon: Icons.speed,
        title: _custom ? 'Time a SELECT' : 'Standard suite',
        message: _custom
            ? 'The query runs ${db == null ? 'on the selected database' : 'on "${db.name}"'}; '
                  'only SELECT statements are allowed.'
            : 'Runs on a private in-memory database: your data is not touched.',
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          db == null ? 'Benchmark' : 'Benchmark — ${db.name}',
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Form(key: _formKey, child: _config(context)),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                FilledButton.icon(
                  onPressed: _running || (_custom && db == null) ? null : _run,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(_running ? 'Running…' : 'Run benchmark'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _running ? null : _clear,
                  icon: const Icon(Icons.clear),
                  label: const Text('Clear'),
                ),
              ],
            ),
          ),
          if (_error != null)
            MessageBanner(
              message: _error!,
              tone: BannerTone.error,
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              onClose: () => setState(() => _error = null),
            ),
          Expanded(child: results),
        ],
      ),
    );
  }

  Widget _config(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget intField(
      String label,
      TextEditingController c,
      int min,
      int max,
      String tip,
    ) => SizedBox(
      width: 120,
      child: Tooltip(
        message: tip,
        child: TextFormField(
          controller: c,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: label,
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          validator: (v) => _intError(v, min, max),
        ),
      ),
    );
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('Standard suite'),
                  icon: Icon(Icons.speed),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Custom SELECT'),
                  icon: Icon(Icons.tune),
                ),
              ],
              selected: {_custom},
              onSelectionChanged: _running
                  ? null
                  : (s) => setState(() {
                      _custom = s.first;
                      _error = null;
                    }),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                if (!_custom)
                  intField(
                    'Rows',
                    _rowCount,
                    10,
                    100000,
                    'Rows in the benchmark tables',
                  ),
                intField(
                  'Warm-up',
                  _warmup,
                  0,
                  1000,
                  'Untimed runs before measuring',
                ),
                intField(
                  'Iterations',
                  _iterations,
                  1,
                  10000,
                  'Timed runs per operation',
                ),
              ],
            ),
            if (_custom) ...[
              const SizedBox(height: 10),
              TextFormField(
                controller: _label,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey('jdb-bench-sql'),
                controller: _query,
                minLines: 2,
                maxLines: 4,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                decoration: InputDecoration(
                  labelText: 'SELECT statement',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  filled: true,
                  fillColor: cs.surfaceContainerHighest,
                ),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Enter a SELECT statement'
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SuiteResultView extends StatelessWidget {
  const _SuiteResultView({required this.result});

  final BenchmarkSuiteResult result;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final maxThroughput = result.results.fold<double>(
      0.01,
      (m, s) => s.throughput.isFinite && s.throughput > m ? s.throughput : m,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        Row(
          children: [
            Icon(Icons.check_circle_outline, color: cs.primary, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                result.suiteName,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
            ),
            Text(
              plural(result.results.length, 'operation'),
              style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final s in result.results)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _StatCard(stats: s, maxThroughput: maxThroughput),
          ),
        _CopyButton(text: result.formatTable()),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({required this.stats, required this.maxThroughput});

  final QueryStats stats;
  final double maxThroughput;

  static String _ms(Duration d) =>
      '${(d.inMicroseconds / 1000.0).toStringAsFixed(2)} ms';

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fraction = stats.throughput.isFinite && maxThroughput > 0
        ? (stats.throughput / maxThroughput).clamp(0.04, 1.0)
        : 1.0;
    final ops = stats.throughput.isInfinite
        ? '∞'
        : stats.throughput >= 1000
        ? '${(stats.throughput / 1000).toStringAsFixed(1)}k'
        : stats.throughput.toStringAsFixed(0);
    Widget stat(String label, String value) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
        ),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
      ],
    );
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: cs.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    stats.label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    '$ops ops/s',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: cs.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 6,
                backgroundColor: cs.surfaceContainerHighest,
                color: cs.primary,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                stat('avg', _ms(stats.average)),
                stat('median', _ms(stats.median)),
                stat('min', _ms(stats.min)),
                stat('max', _ms(stats.max)),
                stat('p95', _ms(stats.p95)),
                stat('p99', _ms(stats.p99)),
                stat('n', '${stats.iterations}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CopyButton extends StatelessWidget {
  const _CopyButton({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: text));
          if (context.mounted) showAdminMessage(context, 'Results copied.');
        },
        icon: const Icon(Icons.copy, size: 16),
        label: const Text('Copy as text'),
      ),
    );
  }
}

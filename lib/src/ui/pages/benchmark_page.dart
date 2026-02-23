import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:just_database/just_database.dart';

class BenchmarkPage extends StatefulWidget {
  final DatabaseInfo info;
  const BenchmarkPage({super.key, required this.info});

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  // Config
  final _rowCountController = TextEditingController(text: '1000');
  final _warmupController = TextEditingController(text: '3');
  final _iterationsController = TextEditingController(text: '50');
  final _queryController = TextEditingController(
    text: 'SELECT * FROM users LIMIT 100',
  );
  final _queryLabelController = TextEditingController(text: 'My query');

  bool _useCustomQuery = false;
  bool _running = false;
  String? _error;
  BenchmarkSuiteResult? _suiteResult;
  QueryStats? _customResult;

  @override
  void dispose() {
    _rowCountController.dispose();
    _warmupController.dispose();
    _iterationsController.dispose();
    _queryController.dispose();
    _queryLabelController.dispose();
    super.dispose();
  }

  Future<void> _run(JustDatabase db) async {
    setState(() {
      _running = true;
      _error = null;
      _suiteResult = null;
      _customResult = null;
    });
    try {
      final warmup = int.tryParse(_warmupController.text.trim()) ?? 3;
      final iters = int.tryParse(_iterationsController.text.trim()) ?? 50;

      if (_useCustomQuery) {
        final sql = _queryController.text.trim();
        final label = _queryLabelController.text.trim().isNotEmpty
            ? _queryLabelController.text.trim()
            : 'Custom query';
        final result = await db.benchmarkQuery(
          label,
          sql,
          warmup: warmup,
          iterations: iters,
        );
        setState(() => _customResult = result);
      } else {
        final rowCount = int.tryParse(_rowCountController.text.trim()) ?? 1000;
        final result = await db.runStandardBenchmark(
          rowCount: rowCount,
          warmup: warmup,
          iterations: iters,
        );
        setState(() => _suiteResult = result);
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<DatabaseProvider>();
    final db = provider.currentDatabase;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          icon: Icon(Icons.arrow_back_ios_outlined, size: 18),
        ),
        title: Text('Benchmark — ${widget.info.name}'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ConfigCard(
            rowCountController: _rowCountController,
            warmupController: _warmupController,
            iterationsController: _iterationsController,
            queryController: _queryController,
            queryLabelController: _queryLabelController,
            useCustomQuery: _useCustomQuery,
            onModeChanged: (v) => setState(() {
              _useCustomQuery = v;
              _suiteResult = null;
              _customResult = null;
              _error = null;
            }),
          ),
          _RunBar(
            canRun: db != null && !_running,
            running: _running,
            noDatabaseSelected: db == null,
            onRun: db != null ? () => _run(db) : null,
            onClear: () => setState(() {
              _suiteResult = null;
              _customResult = null;
              _error = null;
            }),
          ),
          if (_error != null) _ErrorBanner(message: _error!),
          Expanded(
            child: _useCustomQuery
                ? (_customResult != null
                      ? _CustomResultPanel(stats: _customResult!)
                      : _EmptyState(
                          running: _running,
                          message: 'Configure a query above, then tap Run.',
                        ))
                : (_suiteResult != null
                      ? _SuiteResultPanel(result: _suiteResult!)
                      : _EmptyState(
                          running: _running,
                          message:
                              'Select a database and tap Run to start the standard benchmark suite.',
                        )),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Config card
// ─────────────────────────────────────────────────────────────────────────────

class _ConfigCard extends StatelessWidget {
  final TextEditingController rowCountController;
  final TextEditingController warmupController;
  final TextEditingController iterationsController;
  final TextEditingController queryController;
  final TextEditingController queryLabelController;
  final bool useCustomQuery;
  final ValueChanged<bool> onModeChanged;

  const _ConfigCard({
    required this.rowCountController,
    required this.warmupController,
    required this.iterationsController,
    required this.queryController,
    required this.queryLabelController,
    required this.useCustomQuery,
    required this.onModeChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Mode toggle
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: false,
                  label: Text('Standard Suite'),
                  icon: Icon(Icons.speed),
                ),
                ButtonSegment(
                  value: true,
                  label: Text('Custom Query'),
                  icon: Icon(Icons.tune),
                ),
              ],
              selected: {useCustomQuery},
              onSelectionChanged: (s) => onModeChanged(s.first),
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                textStyle: WidgetStatePropertyAll(
                  Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Parameters row
            _ParamRow(
              children: [
                if (!useCustomQuery)
                  _IntField(
                    label: 'Seed rows',
                    controller: rowCountController,
                    tooltip: 'Number of rows inserted before benchmarking',
                  ),
                _IntField(
                  label: 'Warm-up',
                  controller: warmupController,
                  tooltip: 'Iterations run before timing starts',
                ),
                _IntField(
                  label: 'Iterations',
                  controller: iterationsController,
                  tooltip: 'Timed iterations per operation',
                ),
              ],
            ),

            if (useCustomQuery) ...[
              const SizedBox(height: 10),
              TextField(
                controller: queryLabelController,
                decoration: const InputDecoration(
                  labelText: 'Label',
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: queryController,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: 'SQL',
                  isDense: true,
                  border: const OutlineInputBorder(),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  fillColor: cs.surfaceContainerHighest,
                  filled: true,
                ),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ParamRow extends StatelessWidget {
  final List<Widget> children;
  const _ParamRow({required this.children});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: children.map((c) => SizedBox(width: 110, child: c)).toList(),
    );
  }
}

class _IntField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? tooltip;

  const _IntField({
    required this.label,
    required this.controller,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      style: const TextStyle(fontSize: 13),
    );
    if (tooltip == null) return field;
    return Tooltip(message: tooltip!, child: field);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Run bar
// ─────────────────────────────────────────────────────────────────────────────

class _RunBar extends StatelessWidget {
  final bool canRun;
  final bool running;
  final bool noDatabaseSelected;
  final VoidCallback? onRun;
  final VoidCallback onClear;

  const _RunBar({
    required this.canRun,
    required this.running,
    required this.noDatabaseSelected,
    required this.onRun,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        spacing: 4,
        children: [
          Row(
            children: [
              FilledButton.icon(
                onPressed: canRun ? onRun : null,
                icon: running
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(running ? 'Running…' : 'Run Benchmark'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.clear),
                label: const Text('Clear'),
              ),
            ],
          ),
          if (noDatabaseSelected) ...[
            Row(
              spacing: 4,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
                Text(
                  'Select a database first',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Error banner
// ─────────────────────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.error_outline, size: 18, color: cs.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 13, color: cs.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Empty state
// ─────────────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  final bool running;
  final String message;
  const _EmptyState({required this.running, required this.message});

  @override
  Widget build(BuildContext context) {
    if (running) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Benchmarking…', style: TextStyle(fontSize: 14)),
          ],
        ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.speed,
              size: 56,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Suite results panel
// ─────────────────────────────────────────────────────────────────────────────

class _SuiteResultPanel extends StatelessWidget {
  final BenchmarkSuiteResult result;
  const _SuiteResultPanel({required this.result});

  @override
  Widget build(BuildContext context) {
    final maxThroughput = result.results.fold(
      0.01,
      (m, s) => s.throughput.isFinite && s.throughput > m ? s.throughput : m,
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        _ResultHeader(result: result),
        const SizedBox(height: 12),
        ...result.results.map(
          (s) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _StatCard(stats: s, maxThroughput: maxThroughput),
          ),
        ),
        const SizedBox(height: 8),
        _CopyButton(result: result),
      ],
    );
  }
}

class _ResultHeader extends StatelessWidget {
  final BenchmarkSuiteResult result;
  const _ResultHeader({required this.result});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(Icons.check_circle, color: cs.primary, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            result.suiteName,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        Text(
          '${result.results.length} operations',
          style: TextStyle(fontSize: 12, color: cs.outline),
        ),
      ],
    );
  }
}

class _StatCard extends StatelessWidget {
  final QueryStats stats;
  final double maxThroughput;
  const _StatCard({required this.stats, required this.maxThroughput});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fraction = (stats.throughput.isFinite && maxThroughput > 0)
        ? (stats.throughput / maxThroughput).clamp(0.04, 1.0)
        : 0.04;

    // Color based on relative throughput
    final barColor = fraction >= 0.7
        ? Colors.green.shade600
        : fraction >= 0.4
        ? Colors.orange.shade600
        : cs.primary;

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
            // Operation name + throughput badge
            Row(
              children: [
                Expanded(
                  child: Text(
                    stats.label,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _ThroughputBadge(throughput: stats.throughput),
              ],
            ),
            const SizedBox(height: 8),

            // Throughput bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 6,
                backgroundColor: cs.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation(barColor),
              ),
            ),
            const SizedBox(height: 10),

            // Stat row
            _StatRow(stats: stats),
          ],
        ),
      ),
    );
  }
}

class _ThroughputBadge extends StatelessWidget {
  final double throughput;
  const _ThroughputBadge({required this.throughput});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final label = throughput.isInfinite
        ? '∞'
        : throughput >= 1000
        ? '${(throughput / 1000).toStringAsFixed(1)}k'
        : throughput.toStringAsFixed(0);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        '$label ops/s',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: cs.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final QueryStats stats;
  const _StatRow({required this.stats});

  String _ms(Duration d) =>
      '${(d.inMicroseconds / 1000.0).toStringAsFixed(2)}ms';

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        _StatChip(label: 'avg', value: _ms(stats.average)),
        _StatChip(label: 'min', value: _ms(stats.min)),
        _StatChip(label: 'max', value: _ms(stats.max)),
        _StatChip(label: 'p95', value: _ms(stats.p95)),
        _StatChip(label: 'p99', value: _ms(stats.p99)),
        _StatChip(label: 'n', value: '${stats.iterations}'),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: TextStyle(fontSize: 11, color: cs.outline)),
        Text(
          value,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Custom query result panel
// ─────────────────────────────────────────────────────────────────────────────

class _CustomResultPanel extends StatelessWidget {
  final QueryStats stats;
  const _CustomResultPanel({required this.stats});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
      children: [_StatCard(stats: stats, maxThroughput: stats.throughput)],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Copy to clipboard button
// ─────────────────────────────────────────────────────────────────────────────

class _CopyButton extends StatelessWidget {
  final BenchmarkSuiteResult result;
  const _CopyButton({required this.result});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: TextButton.icon(
        onPressed: () {
          final text = DatabaseBenchmark.formatTable(result.results);
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Results copied to clipboard'),
              duration: Duration(seconds: 2),
            ),
          );
        },
        icon: const Icon(Icons.copy, size: 16),
        label: const Text('Copy as table'),
      ),
    );
  }
}

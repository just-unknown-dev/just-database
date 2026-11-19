/// The SQL console of one database.
@internal
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/just_database.dart';
import '../../core/query_result.dart';
import '../../sql/parser.dart';
import '../../sql/sql_exception.dart';
import '../../storage/values.dart';
import '../admin_preferences.dart';
import '../admin_selection.dart';
import '../admin_style.dart';
import '../admin_utils.dart';
import '../dialogs/backup_dialogs.dart';
import '../dialogs/value_inspector.dart';
import '../just_database_admin_controller.dart';
import '../sql_text.dart';
import '../widgets/admin_widgets.dart';
import '../widgets/result_grid.dart';

/// One statement's outcome in the console.
@internal
final class StatementOutcome {
  const StatementOutcome({
    required this.label,
    required this.sql,
    required this.result,
    required this.offset,
  });

  /// A short label (`SELECT`, `INSERT INTO notes`).
  final String label;

  /// The statement's text.
  final String sql;

  /// What it returned.
  final QueryResult result;

  /// Where the statement starts in the editor text it ran from.
  final int offset;

  /// A one-line summary.
  String get summary {
    final r = result;
    if (!r.success) return 'failed';
    if (r.columns.isNotEmpty) return plural(r.rowCount, 'row');
    return '${plural(r.affectedRows, 'row')} changed';
  }
}

/// What the console of one database keeps between visits.
@internal
final class SqlConsoleSession extends ChangeNotifier {
  /// The editor.
  final SqlEditingController editor = SqlEditingController();

  /// The values typed for parameters, by label (`?1`, `:name`).
  final Map<String, TextEditingController> params = {};

  /// The outcomes of the last run.
  List<StatementOutcome> outcomes = const [];

  /// How many statements the last run had.
  int statementCount = 0;

  /// The outcome shown.
  int shown = 0;

  /// The first row shown of the shown outcome.
  int offset = 0;

  /// Rows per page.
  int pageSize = 100;

  /// The editor's height on wide screens.
  double editorHeight = 200;

  /// The column the shown result is sorted by, and how.
  String? sortColumn;
  bool sortAscending = true;

  /// The text of a parameter field, created on first use.
  TextEditingController param(String label) =>
      params.putIfAbsent(label, TextEditingController.new);

  @override
  void dispose() {
    editor.dispose();
    for (final c in params.values) {
      c.dispose();
    }
    super.dispose();
  }
}

/// The console session of [database].
@internal
SqlConsoleSession consoleSession(
  JustDatabaseAdminController controller,
  String database,
) => controller.paneState(
  '${database.toLowerCase()}/console',
  SqlConsoleSession.new,
);

/// Puts [sql] in the console of [where]'s database and shows it.
@internal
Future<void> showInConsole(
  JustDatabaseAdminController controller,
  AdminSelection where,
  String sql,
) async {
  final session = consoleSession(controller, where.database);
  session.editor
    ..text = sql
    ..selection = TextSelection.collapsed(offset: sql.length);
  await controller.select(where.withPane(AdminPane.sql));
}

/// Statements runnable by a read-only screen.
bool _isRead(String sql) {
  try {
    final parsed = Parser.parseOne(sql);
    return parsed.sql.isNotEmpty &&
        RegExp(
          r'^\s*(SELECT|WITH|VALUES|PRAGMA\s+[A-Za-z_]+\s*(\(|;|$))',
          caseSensitive: false,
        ).hasMatch(sql);
  } on SqlException {
    return true; // let the database report the syntax error
  }
}

enum _SidePanel { none, history, snippets }

/// The SQL console: an editor with highlighting and completion, a
/// parameters panel, results per statement, history and snippets.
@internal
class SqlConsole extends StatefulWidget {
  const SqlConsole({
    super.key,
    required this.controller,
    required this.database,
  });

  final JustDatabaseAdminController controller;
  final JustDatabase database;

  @override
  State<SqlConsole> createState() => _SqlConsoleState();
}

class _SqlConsoleState extends State<SqlConsole> {
  late SqlConsoleSession _session;
  late final FocusNode _focus = FocusNode(onKeyEvent: _onKey);
  List<String> _completions = const [];
  WordAtCaret? _word;
  _SidePanel _panel = _SidePanel.none;
  bool _running = false;
  List<String> _paramLabels = const [];
  String? _paramProblem;
  String? _lastText;

  JustDatabase get _db => widget.database;
  JustDatabaseAdminController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(SqlConsole oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.database, widget.database)) {
      _session.editor.removeListener(_onEdit);
      _attach();
    }
  }

  void _attach() {
    _session = consoleSession(_c, _db.name);
    _session.editor.addListener(_onEdit);
    _updateNames();
    _onEdit();
  }

  @override
  void dispose() {
    _session.editor.removeListener(_onEdit);
    _focus.dispose();
    super.dispose();
  }

  void _updateNames() {
    _session.editor.tables = {
      for (final t in _db.tableNames) t.toLowerCase(),
      for (final v in _db.viewNames) v.toLowerCase(),
    };
  }

  /// Completions and parameters follow the text and caret.
  void _onEdit() {
    final value = _session.editor.value;
    final text = value.text;
    final caret = value.selection.isCollapsed ? value.selection.baseOffset : -1;
    var completions = const <String>[];
    WordAtCaret? word;
    if (_focus.hasFocus && caret >= 0) {
      word = wordAt(text, caret);
      if (word != null) {
        final range = statementAt(text, caret);
        final statement = range == null
            ? text
            : text.substring(
                range.start,
                caret.clamp(range.start, text.length),
              );
        completions = completionsFor(
          word: word,
          statement: statement,
          names: [..._db.tableNames, ..._db.viewNames],
          columns: _columns(),
        );
      }
    }
    if (text != _lastText) {
      _lastText = text;
      _updateParams(text);
    }
    if (!listEquals(completions, _completions) || word != _word) {
      setState(() {
        _completions = completions;
        _word = word;
      });
    }
  }

  Map<String, List<String>> _columns() => {
    for (final t in _db.tableNames)
      t.toLowerCase(): _db.getTableSchema(t)?.columnNames ?? const [],
  };

  void _updateParams(String text) {
    final ranges = splitStatements(text);
    var labels = const <String>[];
    String? problem;
    if (ranges.length == 1) {
      try {
        final parsed = Parser.parseOne(text);
        final byIndex = {for (final e in parsed.names.entries) e.value: e.key};
        labels = [
          for (var i = 1; i <= parsed.parameterCount; i++)
            byIndex[i] == null ? '?$i' : ':${byIndex[i]}',
        ];
      } on SqlException {
        // Not complete yet.
      }
    } else if (ranges.length > 1 && RegExp(r'[?:@$]').hasMatch(text)) {
      try {
        if (Parser.parseScript(text).any((s) => s.parameterCount > 0)) {
          problem =
              'Parameters work with one statement at a time: select it and '
              'run the selection.';
        }
      } on SqlException {
        // Not complete yet.
      }
    }
    if (!listEquals(labels, _paramLabels) || problem != _paramProblem) {
      setState(() {
        _paramLabels = labels;
        _paramProblem = problem;
      });
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    final mod = keys.isControlPressed || keys.isMetaPressed;
    final android = defaultTargetPlatform == TargetPlatform.android;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (mod && keys.isShiftPressed) {
        unawaited(_run(statementOnly: true));
        return KeyEventResult.handled;
      }
      if (mod || (android && keys.isShiftPressed)) {
        unawaited(_run());
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.tab && !keys.isShiftPressed) {
      if (_completions.isNotEmpty) {
        _accept(_completions.first);
      } else {
        _insert('  ');
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape &&
        _completions.isNotEmpty) {
      setState(() => _completions = const []);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _insert(String s) {
    final v = _session.editor.value;
    final sel = v.selection.isValid
        ? v.selection
        : TextSelection.collapsed(offset: v.text.length);
    final text = v.text.replaceRange(sel.start, sel.end, s);
    _session.editor.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: sel.start + s.length),
    );
  }

  void _accept(String candidate) {
    final word = _word;
    if (word == null) return;
    final v = _session.editor.value;
    final caret = v.selection.baseOffset;
    final keyword =
        sqlKeywords.contains(candidate.toUpperCase()) &&
        !_db.tableNames.any((t) => t.toLowerCase() == candidate.toLowerCase());
    final insert = keyword ? candidate : sqlName(candidate);
    final text = v.text.replaceRange(word.start, caret, insert);
    _session.editor.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: word.start + insert.length),
    );
    _focus.requestFocus();
  }

  // ---------------------------------------------------------------------------
  // Running
  // ---------------------------------------------------------------------------

  Future<void> _run({bool statementOnly = false}) async {
    if (_running || !_db.isOpen) return;
    final text = _session.editor.text;
    final sel = _session.editor.selection;
    String toRun;
    int base;
    if (statementOnly) {
      final at = sel.isValid ? sel.baseOffset : text.length;
      final range = statementAt(text, at);
      if (range == null) return;
      toRun = text.substring(range.start, range.end);
      base = range.start;
    } else if (sel.isValid && !sel.isCollapsed) {
      toRun = sel.textInside(text);
      base = sel.start;
    } else {
      toRun = text;
      base = 0;
    }
    if (toRun.trim().isEmpty) return;
    final ranges = splitStatements(toRun);
    setState(() => _running = true);
    final outcomes = <StatementOutcome>[];
    try {
      List<Object?>? params;
      final single = ranges.length <= 1;
      if (single) {
        try {
          final parsed = Parser.parseOne(toRun);
          if (parsed.parameterCount > 0) {
            final byIndex = {
              for (final e in parsed.names.entries) e.value: e.key,
            };
            params = [
              for (var i = 1; i <= parsed.parameterCount; i++)
                parseParameterText(
                  _session
                      .param(byIndex[i] == null ? '?$i' : ':${byIndex[i]}')
                      .text,
                ),
            ];
          }
        } on SqlException {
          // The run reports it.
        }
      }
      if (_c.readOnly) {
        for (final r in ranges) {
          final sql = toRun.substring(r.start, r.end);
          final result = _isRead(sql)
              ? await _db.query(sql, single ? params : null)
              : QueryResult.failure(
                  const SqlException(
                    'This screen is read-only: only SELECT and PRAGMA reads run.',
                    kind: SqlErrorKind.misuse,
                  ),
                );
          outcomes.add(_outcome(sql, result, base + r.start));
          if (!result.success) break;
        }
      } else if (single) {
        final sql = ranges.isEmpty
            ? toRun
            : toRun.substring(ranges.first.start, ranges.first.end);
        final result = await _db.execute(sql, params);
        outcomes.add(
          _outcome(
            sql,
            result,
            base + (ranges.isEmpty ? 0 : ranges.first.start),
          ),
        );
      } else {
        final results = await _db.executeScript(toRun);
        for (var i = 0; i < results.length; i++) {
          final r = i < ranges.length ? ranges[i] : null;
          final sql = r == null ? toRun : toRun.substring(r.start, r.end);
          outcomes.add(
            _outcome(
              sql,
              results[i],
              base + (r?.start ?? 0),
              script: toRun,
              scriptBase: base,
            ),
          );
        }
      }
    } catch (e) {
      outcomes.add(
        _outcome(
          toRun,
          QueryResult.failure(SqlException(describeError(e))),
          base,
        ),
      );
    }
    if (!mounted) return;
    final failed = outcomes.indexWhere((o) => !o.result.success);
    setState(() {
      _running = false;
      _session
        ..outcomes = outcomes
        ..statementCount = ranges.length
        ..shown = failed >= 0
            ? failed
            : outcomes.lastIndexWhere((o) => o.result.columns.isNotEmpty) < 0
            ? outcomes.length - 1
            : outcomes.lastIndexWhere((o) => o.result.columns.isNotEmpty)
        ..offset = 0
        ..sortColumn = null;
    });
    _updateNames();
    final ok = failed < 0;
    _c.addHistory(
      HistoryEntry(
        sql: toRun.trim(),
        database: _db.name,
        at: DateTime.now(),
        ok: ok,
        summary: ok
            ? (outcomes.isEmpty ? '' : outcomes.last.summary)
            : (outcomes[failed].result.errorMessage ?? 'failed'),
      ),
    );
  }

  StatementOutcome _outcome(
    String sql,
    QueryResult result,
    int offset, {
    String? script,
    int scriptBase = 0,
  }) {
    var at = offset;
    final e = result.error;
    // A parse error of the whole script points into the script.
    if (e != null && e.offset != null && script != null && e.sql == script) {
      at = scriptBase;
    }
    return StatementOutcome(
      label: statementLabel(sql),
      sql: e?.sql ?? sql,
      result: result,
      offset: at,
    );
  }

  /// Selects the error position of [outcome] in the editor.
  void _showError(StatementOutcome outcome) {
    final e = outcome.result.error;
    final o = e?.offset;
    if (o == null) return;
    final text = _session.editor.text;
    final at = (outcome.offset + o).clamp(0, text.length);
    var end = at;
    while (end < text.length && !RegExp(r'\s').hasMatch(text[end])) {
      end++;
    }
    _session.editor.selection = TextSelection(
      baseOffset: at,
      extentOffset: end,
    );
    _focus.requestFocus();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final wide = AdminStyle.isWide(context);
    final main = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(context, wide),
        _editor(context, wide),
        if (_completions.isNotEmpty) _completionBar(context),
        if (_paramLabels.isNotEmpty || _paramProblem != null)
          _paramsPanel(context),
        if (_db.inTransaction) _transactionBanner(context),
        const Divider(height: 1),
        Expanded(child: _results(context)),
      ],
    );
    if (!wide || _panel == _SidePanel.none) return main;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: main),
        const VerticalDivider(width: 1),
        SizedBox(width: 320, child: _sidePanel(context)),
      ],
    );
  }

  Widget _toolbar(BuildContext context, bool wide) {
    final shortcut = defaultTargetPlatform == TargetPlatform.macOS
        ? '⌘'
        : 'Ctrl';
    void togglePanel(_SidePanel p) {
      if (!wide) {
        unawaited(_showPanelSheet(context, p));
        return;
      }
      setState(() => _panel = _panel == p ? _SidePanel.none : p);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          Tooltip(
            message:
                'Run the selection, or everything ($shortcut+Enter). '
                '$shortcut+Shift+Enter runs the statement at the caret.',
            child: FilledButton.icon(
              key: const ValueKey('jdb-run'),
              onPressed: _running || !_db.isOpen ? null : () => _run(),
              icon: _running
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow, size: 18),
              label: const Text('Run'),
            ),
          ),
          const SizedBox(width: 4),
          IconButton(
            key: const ValueKey('jdb-run-statement'),
            tooltip: 'Run the statement at the caret ($shortcut+Shift+Enter)',
            onPressed: _running ? null : () => _run(statementOnly: true),
            icon: const Icon(Icons.playlist_play),
          ),
          IconButton(
            tooltip: 'Clear',
            onPressed: () {
              _session.editor.clear();
              setState(() => _session.outcomes = const []);
            },
            icon: const Icon(Icons.backspace_outlined),
          ),
          const Spacer(),
          if (_c.readOnly && wide)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: AdminTag.readOnly(context),
            ),
          IconButton(
            key: const ValueKey('jdb-history'),
            tooltip: 'History',
            isSelected: _panel == _SidePanel.history,
            onPressed: () => togglePanel(_SidePanel.history),
            icon: const Icon(Icons.history),
          ),
          IconButton(
            key: const ValueKey('jdb-snippets'),
            tooltip: 'Snippets and templates',
            isSelected: _panel == _SidePanel.snippets,
            onPressed: () => togglePanel(_SidePanel.snippets),
            icon: const Icon(Icons.bookmarks_outlined),
            selectedIcon: const Icon(Icons.bookmarks),
          ),
        ],
      ),
    );
  }

  Widget _editor(BuildContext context, bool wide) {
    final cs = Theme.of(context).colorScheme;
    final field = Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: cs.outlineVariant),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Focus(
        onFocusChange: (_) => _onEdit(),
        child: TextField(
          key: const ValueKey('jdb-sql'),
          controller: _session.editor,
          focusNode: _focus,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          style: AdminStyle.mono(context, fontSize: 13.5),
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          autocorrect: false,
          enableSuggestions: false,
          smartQuotesType: SmartQuotesType.disabled,
          smartDashesType: SmartDashesType.disabled,
          decoration: InputDecoration(
            hintText: _c.readOnly
                ? 'SELECT … (read-only: only reads run)'
                : 'SELECT * FROM … ;  several statements run as a script',
            hintStyle: AdminStyle.mono(
              context,
              fontSize: 13.5,
              color: cs.onSurfaceVariant,
            ),
            border: InputBorder.none,
            isDense: true,
          ),
        ),
      ),
    );
    if (!wide) return SizedBox(height: 150, child: field);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: _session.editorHeight, child: field),
        MouseRegion(
          cursor: SystemMouseCursors.resizeRow,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onVerticalDragUpdate: (d) => setState(() {
              _session.editorHeight = (_session.editorHeight + d.delta.dy)
                  .clamp(80.0, 640.0);
            }),
            child: SizedBox(
              height: 10,
              child: Center(
                child: Container(
                  width: 36,
                  height: 3,
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _completionBar(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        key: const ValueKey('jdb-completions'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: [
          for (var i = 0; i < _completions.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                key: ValueKey('jdb-completion-${_completions[i]}'),
                visualDensity: VisualDensity.compact,
                avatar: i == 0
                    ? const Icon(Icons.keyboard_tab, size: 14)
                    : null,
                label: Text(
                  _completions[i],
                  style: AdminStyle.mono(context, fontSize: 12.5),
                ),
                onPressed: () => _accept(_completions[i]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _paramsPanel(BuildContext context) {
    final problem = _paramProblem;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: problem != null
          ? MessageBanner(message: problem, tone: BannerTone.warning)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Parameters: NULL, a number, \'text\', X\'hex\' or true/false; '
                  'anything else is text.',
                  style: AdminStyle.caption(context),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final label in _paramLabels)
                      SizedBox(
                        width: 180,
                        child: TextField(
                          key: ValueKey('jdb-param-$label'),
                          controller: _session.param(label),
                          style: AdminStyle.mono(context, fontSize: 13),
                          onSubmitted: (_) => _run(),
                          decoration: InputDecoration(
                            labelText: label,
                            isDense: true,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _transactionBanner(BuildContext context) {
    return MessageBanner(
      tone: BannerTone.warning,
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      message:
          'A transaction is open: its changes are saved at COMMIT and undone '
          'by ROLLBACK.',
      actions: _c.readOnly
          ? const []
          : [
              TextButton(
                onPressed: () async {
                  await _db.execute('COMMIT');
                  if (mounted) setState(() {});
                },
                child: const Text('Commit'),
              ),
              TextButton(
                onPressed: () async {
                  await _db.execute('ROLLBACK');
                  if (mounted) setState(() {});
                },
                child: const Text('Roll back'),
              ),
            ],
    );
  }

  // ---------------------------------------------------------------------------
  // Results
  // ---------------------------------------------------------------------------

  Widget _results(BuildContext context) {
    final outcomes = _session.outcomes;
    if (outcomes.isEmpty) {
      final shortcut = defaultTargetPlatform == TargetPlatform.macOS
          ? '⌘'
          : 'Ctrl';
      return EmptyState(
        icon: Icons.terminal,
        title: 'Run SQL on "${_db.name}"',
        message:
            '$shortcut+Enter runs the selection or everything; '
            '$shortcut+Shift+Enter runs the statement at the caret. Tab '
            'takes the first suggestion. Templates are under the bookmark '
            'button.',
      );
    }
    final shown = _session.shown.clamp(0, outcomes.length - 1);
    final outcome = outcomes[shown];
    final notRun = _session.statementCount - outcomes.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (outcomes.length > 1 || notRun > 0)
          SizedBox(
            height: 44,
            child: ListView(
              key: const ValueKey('jdb-outcomes'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              children: [
                for (var i = 0; i < outcomes.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      key: ValueKey('jdb-outcome-$i'),
                      visualDensity: VisualDensity.compact,
                      avatar: Icon(
                        outcomes[i].result.success
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 16,
                        color: outcomes[i].result.success
                            ? null
                            : Theme.of(context).colorScheme.error,
                      ),
                      label: Text(
                        '${i + 1} · ${outcomes[i].label} · ${outcomes[i].summary}',
                      ),
                      selected: i == shown,
                      onSelected: (_) => setState(() {
                        _session
                          ..shown = i
                          ..offset = 0
                          ..sortColumn = null;
                      }),
                    ),
                  ),
                if (notRun > 0)
                  Center(
                    child: Text(
                      '${plural(notRun, 'statement')} after it did not run',
                      style: AdminStyle.caption(context),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(child: _outcomeView(context, outcome, shown)),
      ],
    );
  }

  String _time(Duration d) {
    final ms = d.inMicroseconds / 1000;
    return ms < 10
        ? '${ms.toStringAsFixed(2)} ms'
        : '${ms.toStringAsFixed(1)} ms';
  }

  Widget _outcomeView(BuildContext context, StatementOutcome o, int index) {
    final r = o.result;
    if (!r.success) {
      final e = r.error!;
      final at = e.offset;
      final pos = at == null
          ? null
          : lineAndColumn(_session.editor.text, o.offset + at);
      final count = _session.outcomes.length;
      return ListView(
        padding: const EdgeInsets.all(8),
        children: [
          MessageBanner(
            key: const ValueKey('jdb-query-error'),
            tone: BannerTone.error,
            message: [
              if (count > 1 || _session.statementCount > 1)
                'Statement ${index + 1} failed'
                    '${index > 0 ? ' (the ${plural(index, 'statement')} before it ran)' : ''}:',
              e.message,
              if (pos != null) '(line ${pos.line}, column ${pos.column})',
            ].join(' '),
            actions: [
              if (pos != null)
                TextButton(
                  onPressed: () => _showError(o),
                  child: const Text('Show'),
                ),
            ],
          ),
        ],
      );
    }
    if (r.columns.isEmpty) {
      return EmptyState(
        icon: Icons.check_circle_outline,
        title: '${plural(r.affectedRows, 'row')} changed',
        message: [
          o.label,
          if (r.lastInsertRowId != null) 'last rowid ${r.lastInsertRowId}',
          _time(r.elapsed),
        ].join(' · '),
      );
    }
    var values = r.values;
    final sort = _session.sortColumn;
    final sortIndex = sort == null ? -1 : r.columns.indexOf(sort);
    if (sortIndex >= 0) {
      values = List.of(values)
        ..sort((a, b) {
          final c = compareValues(a[sortIndex], b[sortIndex]);
          return _session.sortAscending ? c : -c;
        });
    }
    final total = values.length;
    final start = _session.offset.clamp(0, total);
    final end = (start + _session.pageSize).clamp(0, total);
    final summary = Text(
      '${plural(total, 'row')} · ${_time(r.elapsed)}',
      style: AdminStyle.caption(context),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 4, 2),
          child: Row(
            children: [
              Expanded(child: summary),
              IconButton(
                tooltip: 'Copy as CSV',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () => copyText(
                  context,
                  rowsToCsv(r.columns, values),
                  what: 'Rows',
                ),
              ),
              IconButton(
                tooltip: 'Export rows…',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.upload_outlined, size: 18),
                onPressed: () => showTextExportDialog(
                  context,
                  title: 'Export the result',
                  baseName: '${_db.name}-result',
                  options: [
                    TextExportOption(
                      'CSV',
                      'csv',
                      () async => rowsToCsv(r.columns, values),
                    ),
                    TextExportOption(
                      'JSON',
                      'json',
                      () async => rowsToJson(r.columns, values),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ResultGrid(
            key: ValueKey('jdb-console-grid-$index'),
            columns: r.columns,
            rows: values.sublist(start, end),
            dense: AdminStyle.isWide(context),
            sortColumn: sort,
            sortAscending: _session.sortAscending,
            onSort: (column) => setState(() {
              if (_session.sortColumn != column) {
                _session
                  ..sortColumn = column
                  ..sortAscending = true;
              } else if (_session.sortAscending) {
                _session.sortAscending = false;
              } else {
                _session.sortColumn = null;
              }
            }),
            onCellDoubleTap: (cell) =>
                _inspect(context, r, values, start, cell),
            onCellMenu: (cell, _) => _inspect(context, r, values, start, cell),
          ),
        ),
        PageBar(
          offset: start,
          pageSize: _session.pageSize,
          total: total,
          pageSizes: const [50, 100, 250, 1000],
          onOffsetChanged: (o) => setState(() => _session.offset = o),
          onPageSizeChanged: (s) => setState(() {
            _session
              ..pageSize = s
              ..offset = (_session.offset ~/ s) * s;
          }),
        ),
      ],
    );
  }

  void _inspect(
    BuildContext context,
    QueryResult r,
    List<List<Object?>> values,
    int start,
    GridCell cell,
  ) {
    final row = values[start + cell.row];
    unawaited(
      showValueInspector(
        context,
        title: r.columns[cell.column],
        value: cell.column < row.length ? row[cell.column] : null,
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // History and snippets
  // ---------------------------------------------------------------------------

  Future<void> _showPanelSheet(BuildContext context, _SidePanel panel) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheet) => SizedBox(
          height: MediaQuery.sizeOf(sheet).height * 0.7,
          child: ListenableBuilder(
            listenable: _c,
            builder: (context, _) => panel == _SidePanel.history
                ? _historyList(context, closeOnPick: true)
                : _snippetList(context, closeOnPick: true),
          ),
        ),
      );

  Widget _sidePanel(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _panel == _SidePanel.history ? 'History' : 'Snippets',
                style: AdminStyle.heading(context),
              ),
            ),
            IconButton(
              tooltip: 'Close',
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => _panel = _SidePanel.none),
            ),
          ],
        ),
      ),
      Expanded(
        child: _panel == _SidePanel.history
            ? _historyList(context)
            : _snippetList(context),
      ),
    ],
  );

  void _load(String sql, {bool close = false}) {
    _session.editor
      ..text = sql
      ..selection = TextSelection.collapsed(offset: sql.length);
    if (close) Navigator.of(context).maybePop();
    _focus.requestFocus();
  }

  Widget _historyList(BuildContext context, {bool closeOnPick = false}) {
    final all = _c.history;
    final here = [
      for (final h in all)
        if (h.database.toLowerCase() == _db.name.toLowerCase()) h,
    ];
    final cs = Theme.of(context).colorScheme;
    if (here.isEmpty) {
      return const EmptyState(
        icon: Icons.history,
        title: 'No history yet',
        message: 'Statements you run here are listed (and kept).',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView.separated(
            itemCount: here.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final h = here[i];
              return ListTile(
                key: ValueKey('jdb-history-$i'),
                dense: true,
                leading: Icon(
                  h.ok ? Icons.check_circle_outline : Icons.error_outline,
                  size: 18,
                  color: h.ok ? cs.primary : cs.error,
                ),
                title: Text(
                  h.sql,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AdminStyle.mono(context, fontSize: 12),
                ),
                subtitle: Text(
                  '${_ago(h.at)}${h.summary.isEmpty ? '' : ' · ${h.summary}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => _load(h.sql, close: closeOnPick),
              );
            },
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () async {
              if (await confirmAction(
                context,
                title: 'Clear the history?',
                message: 'Every database\'s console history is cleared.',
                confirmLabel: 'Clear',
              )) {
                _c.clearHistory();
              }
            },
            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
            label: const Text('Clear history'),
          ),
        ),
      ],
    );
  }

  String _ago(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    return at.toLocal().toString().substring(0, 16);
  }

  List<(String, String)> _templates() {
    final out = <(String, String)>[];
    for (final t in _db.tableNames.take(8)) {
      final q = sqlName(t);
      out.add(('Rows of $t', 'SELECT * FROM $q LIMIT 100;'));
      out.add(('Count $t', 'SELECT COUNT(*) FROM $q;'));
      final schema = _db.getTableSchema(t);
      if (!_c.readOnly && schema != null) {
        final cols = [
          for (final c in schema.columns)
            if (!c.hidden &&
                !(schema.rowidAlias != null &&
                    schema.columns[schema.rowidAlias!] == c))
              c.name,
        ];
        if (cols.isNotEmpty) {
          out.add((
            'Insert into $t',
            'INSERT INTO $q (${cols.map(sqlName).join(', ')})\n'
                'VALUES (${cols.map((c) => ':${c.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_')}').join(', ')});',
          ));
        }
      }
      out.add(('Columns of $t', 'PRAGMA table_info($q);'));
    }
    for (final v in _db.viewNames.take(4)) {
      out.add(('Rows of view $v', 'SELECT * FROM ${sqlName(v)} LIMIT 100;'));
    }
    out.add(('user_version', 'PRAGMA user_version;'));
    if (!_c.readOnly && _db.tableNames.isEmpty) {
      out.add((
        'Create a table',
        'CREATE TABLE notes (\n  id INTEGER PRIMARY KEY,\n  body TEXT NOT NULL,\n'
            '  created_at DATETIME DEFAULT CURRENT_TIMESTAMP\n);',
      ));
    }
    return out;
  }

  Widget _snippetList(BuildContext context, {bool closeOnPick = false}) {
    final snippets = _c.snippets;
    final templates = _templates();
    Widget header(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: AdminStyle.caption(context)),
    );
    return ListView(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: OutlinedButton.icon(
            key: const ValueKey('jdb-save-snippet'),
            onPressed: _session.editor.text.trim().isEmpty
                ? null
                : () async {
                    final name = await promptText(
                      context,
                      title: 'Save as snippet',
                      label: 'Name',
                      initial: statementLabel(_session.editor.text),
                      confirmLabel: 'Save',
                      validate: (t) =>
                          t.trim().isEmpty ? 'Enter a name.' : null,
                    );
                    if (name != null) {
                      _c.saveSnippet(name.trim(), _session.editor.text);
                    }
                  },
            icon: const Icon(Icons.bookmark_add_outlined, size: 18),
            label: const Text('Save the editor as a snippet'),
          ),
        ),
        header('SAVED'),
        if (snippets.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'None yet. Snippets are kept for every database.',
              style: AdminStyle.caption(context),
            ),
          ),
        for (final s in snippets)
          ListTile(
            key: ValueKey('jdb-snippet-${s.name}'),
            dense: true,
            leading: const Icon(Icons.bookmark_outline, size: 18),
            title: Text(s.name),
            subtitle: Text(
              s.sql,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AdminStyle.mono(context, fontSize: 11.5),
            ),
            trailing: IconButton(
              tooltip: 'Delete snippet',
              icon: const Icon(Icons.delete_outline, size: 18),
              onPressed: () => _c.deleteSnippet(s.name),
            ),
            onTap: () => _load(s.sql, close: closeOnPick),
          ),
        header('TEMPLATES FOR "${_db.name.toUpperCase()}"'),
        for (final (label, sql) in templates)
          ListTile(
            dense: true,
            leading: const Icon(Icons.lightbulb_outline, size: 18),
            title: Text(label),
            subtitle: Text(
              sql,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AdminStyle.mono(context, fontSize: 11.5),
            ),
            onTap: () => _load(sql, close: closeOnPick),
          ),
      ],
    );
  }
}

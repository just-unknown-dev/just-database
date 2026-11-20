/// One column's input in the insert form and the edit dialog.
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../storage/schema.dart';
import '../admin_utils.dart';

/// Where a column's value comes from.
@internal
enum ColumnInputMode {
  /// What the user typed (or toggled).
  value,

  /// SQL NULL.
  nullValue,

  /// Left out of the INSERT, so the column's DEFAULT (or the next rowid)
  /// applies.
  defaultValue,
}

/// How a column's text is read.
@internal
enum ColumnInputKind {
  /// Text, stored exactly as typed (never trimmed).
  text,

  /// A whole number (INTEGER affinity).
  integer,

  /// A number (REAL affinity).
  real,

  /// NUMERIC affinity: a number when the text is one, else the text.
  number,

  /// BOOLEAN: a switch that stores 1 or 0.
  boolean,

  /// DATE / DATETIME / TIMESTAMP: text, normally ISO-8601 UTC.
  dateTime,

  /// BLOB: hex digits.
  blob,

  /// No declared type: a number when the text is exactly one, else text.
  any,
}

/// The value read from a [ColumnInput].
@internal
final class ParsedInput {
  const ParsedInput.value(this.value) : omit = false, error = null;
  const ParsedInput.omit() : value = null, omit = true, error = null;
  const ParsedInput.error(String this.error) : value = null, omit = false;

  /// The value to bind.
  final Object? value;

  /// Whether to leave the column out (its DEFAULT applies).
  final bool omit;

  /// Why the text is not a valid value.
  final String? error;
}

/// The state of one column's input.
@internal
final class ColumnInput extends ChangeNotifier {
  /// An input for a new row.
  ColumnInput.forInsert(this.column, {required this.isRowidAlias})
    : forInsert = true,
      kind = kindOf(column),
      text = TextEditingController(),
      initialText = '',
      initialBool = false,
      initialMode = (column.hasDefault || isRowidAlias)
          ? ColumnInputMode.defaultValue
          : (column.notNull
                ? ColumnInputMode.value
                : ColumnInputMode.nullValue) {
    mode = initialMode;
    boolValue = initialBool;
    text.addListener(_onTextChanged);
  }

  /// An input for an existing value [original].
  ColumnInput.forEdit(
    this.column,
    Object? original, {
    required this.isRowidAlias,
  }) : forInsert = false,
       kind = kindOf(column, original),
       text = TextEditingController(text: _initialEditText(column, original)),
       initialText = _initialEditText(column, original),
       initialBool = original == 1,
       initialMode = original == null
           ? ColumnInputMode.nullValue
           : ColumnInputMode.value {
    mode = initialMode;
    boolValue = initialBool;
    text.addListener(_onTextChanged);
  }

  static String _initialEditText(ColumnDefinition column, Object? original) =>
      kindOf(column, original) == ColumnInputKind.boolean
      ? ''
      : editableText(original);

  /// The column.
  final ColumnDefinition column;

  /// Whether this column aliases the rowid (`INTEGER PRIMARY KEY`).
  final bool isRowidAlias;

  /// Whether this is part of an insert form (DEFAULT is then possible).
  final bool forInsert;

  /// How the text is read.
  final ColumnInputKind kind;

  /// The text field's controller.
  final TextEditingController text;

  final String initialText;
  final bool initialBool;
  final ColumnInputMode initialMode;

  /// Where the value comes from.
  late ColumnInputMode mode;

  /// The switch of a [ColumnInputKind.boolean] column.
  late bool boolValue;

  bool _settingText = false;

  /// Whether NULL may be chosen.
  bool get canBeNull => !column.notNull || (forInsert && isRowidAlias);

  /// Whether DEFAULT may be chosen.
  bool get canUseDefault => forInsert && (column.hasDefault || isRowidAlias);

  /// The modes the user can pick from.
  List<ColumnInputMode> get modes => [
    ColumnInputMode.value,
    if (canBeNull) ColumnInputMode.nullValue,
    if (canUseDefault) ColumnInputMode.defaultValue,
  ];

  /// Whether the user changed this input.
  bool get isChanged {
    if (mode != initialMode) return true;
    if (mode != ColumnInputMode.value) return false;
    return kind == ColumnInputKind.boolean
        ? boolValue != initialBool
        : text.text != initialText;
  }

  /// The kind of input for [column], holding [original] (when editing).
  static ColumnInputKind kindOf(ColumnDefinition column, [Object? original]) {
    if (original is Uint8List) return ColumnInputKind.blob;
    final type = column.type.toUpperCase();
    if (type.contains('BOOL') &&
        (original == null || original == 0 || original == 1)) {
      return ColumnInputKind.boolean;
    }
    if (type.contains('DATE') || type.contains('TIME')) {
      return ColumnInputKind.dateTime;
    }
    return switch (column.affinity) {
      Affinity.integer => ColumnInputKind.integer,
      Affinity.real => ColumnInputKind.real,
      Affinity.text => ColumnInputKind.text,
      Affinity.numeric => ColumnInputKind.number,
      Affinity.blob =>
        type.contains('BLOB') ? ColumnInputKind.blob : ColumnInputKind.any,
    };
  }

  void _onTextChanged() {
    if (_settingText) return;
    if (mode != ColumnInputMode.value && text.text.isNotEmpty) {
      mode = ColumnInputMode.value;
      notifyListeners();
    }
  }

  /// Picks where the value comes from. NULL and DEFAULT clear the text.
  void setMode(ColumnInputMode value) {
    if (mode == value) return;
    mode = value;
    if (value != ColumnInputMode.value) _setTextSilently('');
    notifyListeners();
  }

  /// Sets the switch of a boolean column (and picks [ColumnInputMode.value]).
  void setBool(bool value) {
    boolValue = value;
    mode = ColumnInputMode.value;
    notifyListeners();
  }

  /// Replaces the text (and picks [ColumnInputMode.value]).
  void setText(String value) {
    mode = ColumnInputMode.value;
    _setTextSilently(value);
    notifyListeners();
  }

  /// Puts the input back to how it started.
  void reset() {
    mode = initialMode;
    boolValue = initialBool;
    _setTextSilently(initialText);
    notifyListeners();
  }

  void _setTextSilently(String value) {
    _settingText = true;
    try {
      text.text = value;
    } finally {
      _settingText = false;
    }
  }

  /// Reads the value.
  ParsedInput parse() {
    switch (mode) {
      case ColumnInputMode.nullValue:
        return const ParsedInput.value(null);
      case ColumnInputMode.defaultValue:
        return const ParsedInput.omit();
      case ColumnInputMode.value:
        break;
    }
    final t = text.text;
    final orNull = canBeNull ? ', or choose NULL' : '';
    switch (kind) {
      case ColumnInputKind.boolean:
        return ParsedInput.value(boolValue ? 1 : 0);
      case ColumnInputKind.text:
      case ColumnInputKind.dateTime:
        return ParsedInput.value(t);
      case ColumnInputKind.integer:
        final v = int.tryParse(t.trim());
        return v == null
            ? ParsedInput.error('Enter a whole number$orNull.')
            : ParsedInput.value(v);
      case ColumnInputKind.real:
        final v = double.tryParse(t.trim());
        return v == null || v.isNaN
            ? ParsedInput.error('Enter a number$orNull.')
            : ParsedInput.value(v);
      case ColumnInputKind.number:
        final trimmed = t.trim();
        final v = int.tryParse(trimmed) ?? double.tryParse(trimmed);
        if (v != null && !(v is double && v.isNaN)) return ParsedInput.value(v);
        return ParsedInput.value(t);
      case ColumnInputKind.blob:
        final bytes = parseHexBytes(t);
        return bytes == null
            ? ParsedInput.error('Enter hex bytes, such as 48656C6C6F$orNull.')
            : ParsedInput.value(bytes);
      case ColumnInputKind.any:
        final v = int.tryParse(t) ?? double.tryParse(t);
        if (v != null && !(v is double && v.isNaN)) return ParsedInput.value(v);
        return ParsedInput.value(t);
    }
  }

  @override
  void dispose() {
    text.removeListener(_onTextChanged);
    text.dispose();
    super.dispose();
  }
}

/// The label, type, flags and input of one column.
@internal
class ColumnInputField extends StatelessWidget {
  const ColumnInputField({super.key, required this.input});

  final ColumnInput input;

  String get _name => input.column.name;

  String _modeLabel(ColumnInputMode mode) => switch (mode) {
    ColumnInputMode.value => 'Value',
    ColumnInputMode.nullValue => 'NULL',
    ColumnInputMode.defaultValue =>
      input.isRowidAlias && !input.column.hasDefault
          ? 'Automatic rowid'
          : 'DEFAULT',
  };

  String? _hint() {
    final c = input.column;
    switch (input.mode) {
      case ColumnInputMode.nullValue:
        return 'NULL';
      case ColumnInputMode.defaultValue:
        if (c.hasDefault) return 'DEFAULT ${c.defaultSql}';
        return 'Next rowid';
      case ColumnInputMode.value:
        return switch (input.kind) {
          ColumnInputKind.integer => 'Whole number, e.g. 42',
          ColumnInputKind.real => 'Number, e.g. 3.14',
          ColumnInputKind.number => 'Number or text',
          ColumnInputKind.dateTime => 'ISO-8601 UTC, e.g. 2026-02-20T10:00:00Z',
          ColumnInputKind.blob => 'Hex bytes, e.g. 48656C6C6F',
          ColumnInputKind.text ||
          ColumnInputKind.any ||
          ColumnInputKind.boolean => null,
        };
    }
  }

  Widget? _modeMenu(BuildContext context) {
    final modes = input.modes;
    if (modes.length < 2) return null;
    return PopupMenuButton<ColumnInputMode>(
      key: ValueKey('jdb-mode-$_name'),
      tooltip: 'Value, NULL or DEFAULT for $_name',
      icon: const Icon(Icons.more_vert, size: 20),
      initialValue: input.mode,
      onSelected: input.setMode,
      itemBuilder: (_) => [
        for (final m in modes)
          CheckedPopupMenuItem(
            value: m,
            checked: input.mode == m,
            child: Text(_modeLabel(m)),
          ),
      ],
    );
  }

  Future<void> _pickDateTime(BuildContext context) async {
    final now = DateTime.now().toUtc();
    final current = DateTime.tryParse(input.text.text.trim())?.toUtc() ?? now;
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime(current.year, current.month, current.day),
      firstDate: DateTime(1900),
      lastDate: DateTime(2200),
      helpText: 'Select date (UTC)',
    );
    if (date == null || !context.mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
      helpText: 'Select time (UTC)',
    );
    final picked = DateTime.utc(
      date.year,
      date.month,
      date.day,
      time?.hour ?? 0,
      time?.minute ?? 0,
    );
    input.setText(picked.toIso8601String());
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: input,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _ColumnHeading(input: input),
            const SizedBox(height: 6),
            if (input.kind == ColumnInputKind.boolean)
              _boolRow(context)
            else
              _textField(context),
          ],
        ),
      ),
    );
  }

  Widget _boolRow(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isValue = input.mode == ColumnInputMode.value;
    final menu = _modeMenu(context);
    return Row(
      children: [
        Switch(
          key: ValueKey('jdb-field-$_name'),
          value: input.boolValue && isValue,
          onChanged: input.setBool,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            isValue
                ? (input.boolValue ? 'true (1)' : 'false (0)')
                : _hint() ?? '',
            style: TextStyle(
              fontSize: 13,
              color: isValue ? cs.onSurface : cs.onSurfaceVariant,
              fontStyle: isValue ? null : FontStyle.italic,
            ),
          ),
        ),
        ?menu,
      ],
    );
  }

  Widget _textField(BuildContext context) {
    final menu = _modeMenu(context);
    final isDate = input.kind == ColumnInputKind.dateTime;
    final numeric =
        input.kind == ColumnInputKind.integer ||
        input.kind == ColumnInputKind.real;
    final suffix = <Widget>[
      if (isDate)
        IconButton(
          tooltip: 'Pick a date and time (UTC) for $_name',
          icon: const Icon(Icons.calendar_today, size: 18),
          onPressed: () => _pickDateTime(context),
        ),
      ?menu,
    ];
    return TextFormField(
      key: ValueKey('jdb-field-$_name'),
      controller: input.text,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(signed: true, decimal: true)
          : (input.kind == ColumnInputKind.text
                ? TextInputType.multiline
                : TextInputType.text),
      inputFormatters: input.kind == ColumnInputKind.blob
          ? [FilteringTextInputFormatter.allow(RegExp(r"[0-9A-Fa-fxX'\s]"))]
          : null,
      minLines: 1,
      maxLines: input.kind == ColumnInputKind.text ? 4 : 1,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        hintText: _hint(),
        hintStyle: input.mode == ColumnInputMode.value
            ? null
            : const TextStyle(fontStyle: FontStyle.italic),
        border: const OutlineInputBorder(),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        suffixIcon: suffix.isEmpty
            ? null
            : Row(mainAxisSize: MainAxisSize.min, children: suffix),
      ),
      validator: (_) => input.parse().error,
    );
  }
}

class _ColumnHeading extends StatelessWidget {
  const _ColumnHeading({required this.input});

  final ColumnInput input;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = input.column;
    final flags = [
      if (c.primaryKey || input.isRowidAlias) 'PRIMARY KEY',
      if (c.autoIncrement) 'AUTOINCREMENT',
      if (c.notNull) 'NOT NULL',
      if (c.unique) 'UNIQUE',
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (c.primaryKey || input.isRowidAlias)
          Icon(Icons.key, size: 14, color: cs.primary),
        Text(
          c.name,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: cs.onSurface,
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: cs.secondaryContainer,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            c.type.isEmpty ? 'ANY' : c.type.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: cs.onSecondaryContainer,
            ),
          ),
        ),
        if (flags.isNotEmpty)
          Text(
            flags.join(' · '),
            style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
          ),
      ],
    );
  }
}

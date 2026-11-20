/// Shows one value in full: text (as JSON when it is JSON), numbers, and
/// BLOBs as a hex dump.
@internal
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../admin_style.dart';
import '../admin_utils.dart';
import '../widgets/admin_widgets.dart';

/// Shows [value] in full. With [onSaveText], text (and NULL) can be edited:
/// it returns why saving failed, or null.
@internal
Future<void> showValueInspector(
  BuildContext context, {
  required String title,
  required Object? value,
  Future<String?> Function(String text)? onSaveText,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _ValueInspector(title: title, value: value, onSaveText: onSaveText),
);

/// A description of [value]'s storage class and size.
@internal
String describeValue(Object? value) => switch (value) {
  null => 'NULL',
  int() => 'INTEGER',
  double() => 'REAL',
  String() => 'TEXT · ${plural(value.length, 'character')}',
  Uint8List() => 'BLOB · ${formatBytes(value.length)}',
  _ => value.runtimeType.toString(),
};

/// [bytes] as hex-dump lines of 16 bytes: offset, hex, ASCII. At most
/// [maxBytes] are shown.
@internal
String hexDump(Uint8List bytes, {int maxBytes = 65536}) {
  final b = StringBuffer();
  final n = bytes.length < maxBytes ? bytes.length : maxBytes;
  for (var o = 0; o < n; o += 16) {
    b.write(o.toRadixString(16).padLeft(8, '0'));
    b.write('  ');
    final ascii = StringBuffer();
    for (var i = 0; i < 16; i++) {
      if (o + i < n) {
        final x = bytes[o + i];
        b.write(x.toRadixString(16).padLeft(2, '0'));
        ascii.writeCharCode(x >= 0x20 && x < 0x7F ? x : 0x2E);
      } else {
        b.write('  ');
      }
      b.write(i == 7 ? '  ' : ' ');
    }
    b
      ..write(' ')
      ..writeln(ascii);
  }
  if (n < bytes.length) {
    b.write('… ${formatBytes(bytes.length - n)} more');
  }
  return b.toString();
}

class _ValueInspector extends StatefulWidget {
  const _ValueInspector({
    required this.title,
    required this.value,
    required this.onSaveText,
  });

  final String title;
  final Object? value;
  final Future<String?> Function(String text)? onSaveText;

  @override
  State<_ValueInspector> createState() => _ValueInspectorState();
}

class _ValueInspectorState extends State<_ValueInspector> {
  late final Object? _json = _parseJson(widget.value);
  bool _pretty = true;
  bool _editing = false;
  bool _saving = false;
  String? _error;
  late final TextEditingController _text = TextEditingController(
    text: widget.value is String ? widget.value as String : '',
  );

  static Object? _parseJson(Object? value) {
    if (value is! String) return null;
    final t = value.trimLeft();
    if (!(t.startsWith('{') || t.startsWith('['))) return null;
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _canEdit =>
      widget.onSaveText != null &&
      (widget.value == null || widget.value is String);

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final error = await widget.onSaveText!(_text.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.pop(context);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  String get _shown {
    final v = widget.value;
    if (v is Uint8List) return hexDump(v);
    if (_json != null && _pretty) {
      return const JsonEncoder.withIndent('  ').convert(_json);
    }
    return v == null ? 'NULL' : editableText(v);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final mono = AdminStyle.mono(context, fontSize: 13);
    return AdminDialog(
      title: widget.title,
      width: 640,
      actions: [
        if (_editing) ...[
          TextButton(
            onPressed: _saving ? null : () => setState(() => _editing = false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('jdb-inspector-save'),
            onPressed: _saving ? null : _save,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ] else ...[
          if (_canEdit)
            OutlinedButton.icon(
              key: const ValueKey('jdb-inspector-edit'),
              onPressed: () => setState(() => _editing = true),
              icon: const Icon(Icons.edit_outlined, size: 18),
              label: const Text('Edit'),
            ),
          OutlinedButton.icon(
            onPressed: () =>
                copyText(context, clipboardText(widget.value), what: 'Value'),
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AdminTag.neutral(context, describeValue(widget.value)),
              const Spacer(),
              if (_json != null && !_editing)
                SegmentedButton<bool>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: const [
                    ButtonSegment(value: false, label: Text('Raw')),
                    ButtonSegment(value: true, label: Text('JSON')),
                  ],
                  selected: {_pretty},
                  onSelectionChanged: (s) => setState(() => _pretty = s.first),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_error != null)
            MessageBanner(
              message: _error!,
              tone: BannerTone.error,
              margin: const EdgeInsets.only(bottom: 8),
            ),
          Flexible(
            child: _editing
                ? TextField(
                    key: const ValueKey('jdb-inspector-text'),
                    controller: _text,
                    autofocus: true,
                    maxLines: null,
                    minLines: 8,
                    style: mono,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  )
                : Container(
                    constraints: const BoxConstraints(maxHeight: 460),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.all(12),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        _shown,
                        key: const ValueKey('jdb-inspector-value'),
                        style: widget.value == null
                            ? mono.copyWith(
                                color: cs.onSurfaceVariant,
                                fontStyle: FontStyle.italic,
                              )
                            : mono,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

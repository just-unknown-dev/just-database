/// Export (copy or save a file) and import (paste, pick a file, or read a
/// saved export) dialogs.
@internal
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../../io/exports.dart'
    if (dart.library.js_interop) '../../web/exports.dart'
    as exports;
import '../../persistence/export_file.dart';
import '../admin_style.dart';
import '../admin_utils.dart';
import '../just_database_admin_controller.dart';
import '../widgets/admin_widgets.dart';

/// One way to export: a label, a file extension and how to make the text
/// (null when making it failed; [TextExportOption.error] then says why).
@internal
final class TextExportOption {
  const TextExportOption(this.label, this.extension, this.build, {this.error});

  final String label;
  final String extension;
  final Future<String?> Function() build;
  final String? Function()? error;
}

/// Exports the database [name] as a SQL script or JSON.
@internal
Future<void> showDatabaseExportDialog(
  BuildContext context,
  JustDatabaseAdminController controller,
  String name,
) => showTextExportDialog(
  context,
  title: 'Export "$name"',
  baseName: name,
  options: [
    TextExportOption(
      'SQL script: recreates every table, row, index, view and trigger',
      BackupFormat.sql.extension,
      () => controller.exportText(name, BackupFormat.sql),
      error: () => controller.lastError,
    ),
    TextExportOption(
      'JSON: the file format, AUTOINCREMENT counters included',
      BackupFormat.json.extension,
      () => controller.exportText(name, BackupFormat.json),
      error: () => controller.lastError,
    ),
  ],
);

/// Lets the user pick one of [options], then copy the text or save it as a
/// file named after [baseName].
@internal
Future<void> showTextExportDialog(
  BuildContext context, {
  required String title,
  required String baseName,
  required List<TextExportOption> options,
}) => showDialog<void>(
  context: context,
  builder: (_) =>
      _TextExportDialog(title: title, baseName: baseName, options: options),
);

class _TextExportDialog extends StatefulWidget {
  const _TextExportDialog({
    required this.title,
    required this.baseName,
    required this.options,
  });

  final String title;
  final String baseName;
  final List<TextExportOption> options;

  @override
  State<_TextExportDialog> createState() => _TextExportDialogState();
}

class _TextExportDialogState extends State<_TextExportDialog> {
  int _choice = 0;
  int? _builtFor;
  String? _text;
  bool _working = false;
  String? _error;
  String? _savedTo;

  Future<String?> _build() async {
    if (_builtFor == _choice && _text != null) return _text;
    final option = widget.options[_choice];
    setState(() {
      _working = true;
      _error = null;
    });
    String? text;
    try {
      text = await option.build();
    } catch (e) {
      _error = describeError(e);
    }
    if (!mounted) return null;
    setState(() {
      _working = false;
      if (text == null) {
        _error ??= option.error?.call() ?? 'The export failed.';
      } else {
        _text = text;
        _builtFor = _choice;
      }
    });
    return text;
  }

  Future<void> _copy() async {
    final text = await _build();
    if (text == null || !mounted) return;
    await copyText(context, text, what: 'Export');
  }

  Future<void> _save() async {
    final text = await _build();
    if (text == null || !mounted) return;
    final option = widget.options[_choice];
    setState(() => _working = true);
    try {
      final where = await exports.saveExport(
        exportFileName(widget.baseName, option.extension),
        text,
      );
      if (!mounted) return;
      setState(() {
        _working = false;
        _savedTo = where;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _working = false;
        _error = 'Could not save the file: ${describeError(e)}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = _builtFor == _choice ? _text : null;
    return AdminDialog(
      title: widget.title,
      width: 520,
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        OutlinedButton.icon(
          key: const ValueKey('jdb-export-copy'),
          onPressed: _working ? null : _copy,
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy'),
        ),
        FilledButton.icon(
          key: const ValueKey('jdb-export-save'),
          onPressed: _working ? null : _save,
          icon: const Icon(Icons.save_alt, size: 18),
          label: Text(exports.canPickFiles ? 'Download' : 'Save file'),
        ),
      ],
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            RadioGroup<int>(
              groupValue: _choice,
              onChanged: (v) => setState(() {
                _choice = v ?? _choice;
                _savedTo = null;
                _error = null;
              }),
              child: Column(
                children: [
                  for (var i = 0; i < widget.options.length; i++)
                    RadioListTile<int>(
                      key: ValueKey('jdb-export-option-$i'),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: i,
                      title: Text(widget.options[i].label),
                    ),
                ],
              ),
            ),
            if (_working) const LinearProgressIndicator(),
            if (text != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${formatBytes(text.length)} of text.',
                  style: AdminStyle.caption(context),
                ),
              ),
            if (_error != null)
              MessageBanner(
                message: _error!,
                tone: BannerTone.error,
                margin: const EdgeInsets.only(top: 8),
              ),
            if (_savedTo != null)
              MessageBanner(
                key: const ValueKey('jdb-export-saved'),
                message: 'Saved to $_savedTo',
                tone: BannerTone.success,
                margin: const EdgeInsets.only(top: 8),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Import
// ---------------------------------------------------------------------------

/// Imports a SQL script or JSON export, into [into] (replacing it) or as a
/// new database.
@internal
Future<void> showImportDialog(
  BuildContext context,
  JustDatabaseAdminController controller, {
  String? into,
}) => showDialog<void>(
  context: context,
  builder: (_) => _ImportDialog(controller: controller, into: into),
);

enum _Source { paste, file }

class _ImportDialog extends StatefulWidget {
  const _ImportDialog({required this.controller, required this.into});

  final JustDatabaseAdminController controller;
  final String? into;

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  _Source _source = _Source.paste;
  late bool _replace = widget.into != null;
  final _pasted = TextEditingController();
  final _path = TextEditingController();
  final _name = TextEditingController();
  String? _fileText;
  String? _fileName;
  Future<List<ExportFile>>? _files;
  String? _folder;
  bool _working = false;
  bool _showErrors = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.text = widget.into == null ? '' : '${widget.into}_imported';
  }

  @override
  void dispose() {
    _pasted.dispose();
    _path.dispose();
    _name.dispose();
    super.dispose();
  }

  String? get _text => _source == _Source.paste
      ? (_pasted.text.trim().isEmpty ? null : _pasted.text)
      : _fileText;

  void _useFile(String name, String text) {
    setState(() {
      _fileName = name;
      _fileText = text;
      _error = null;
      if (!_replace) _name.text = _suggestName(name);
    });
  }

  String _suggestName(String fileName) {
    var base = fileName.replaceAll(RegExp(r'\.(sql|json|txt)$'), '');
    base = base.replaceAll(RegExp(r'-\d{8}-\d{6}$'), '');
    base = base.replaceAll(RegExp(r'[^A-Za-z0-9_.\-]'), '_');
    if (base.isEmpty || base.startsWith('.') || base.startsWith('-')) {
      base = 'imported';
    }
    var name = base;
    var n = 2;
    while (widget.controller.checkNewName(name) != null && n < 100) {
      name = '${base}_${n++}';
    }
    return name;
  }

  void _loadFolder() {
    _files ??= exports.listExports();
    if (_folder == null) {
      exports.exportsLocation().then((f) {
        if (mounted) setState(() => _folder = f);
      }, onError: (Object _) {});
    }
  }

  Future<void> _pick() async {
    try {
      final picked = await exports.pickTextFile();
      if (picked != null) _useFile(picked.name, picked.content);
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  Future<void> _readPath(String path) async {
    if (path.trim().isEmpty) return;
    try {
      final text = await exports.readExport(path.trim());
      _useFile(path.trim().split(RegExp(r'[\\/]')).last, text);
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Could not read the file: ${describeError(e)}');
      }
    }
  }

  Future<void> _import() async {
    final text = _text;
    final nameProblem = _replace
        ? null
        : widget.controller.checkNewName(_name.text);
    if (text == null || nameProblem != null) {
      setState(() {
        _showErrors = true;
        _error = text == null ? 'Paste or choose something to import.' : null;
      });
      return;
    }
    final into = widget.into;
    if (_replace && into != null) {
      final ok = await confirmAction(
        context,
        title: 'Replace "$into"?',
        message:
            'Every table, row, view and trigger of "$into" is replaced by '
            'the import. Export it first to keep a copy.',
        confirmLabel: 'Replace',
      );
      if (!ok || !mounted) return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    final ok = _replace && into != null
        ? await widget.controller.importInto(into, text)
        : await widget.controller.importAsNew(_name.text, text);
    if (!mounted) return;
    if (ok) {
      final target = _replace && into != null ? into : _name.text;
      Navigator.pop(context);
      showAdminMessage(context, 'Imported into "$target".');
    } else {
      setState(() {
        _working = false;
        _error = widget.controller.lastError;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final into = widget.into;
    final text = _text;
    final fileSource = _source == _Source.file;
    if (fileSource && !exports.canPickFiles) _loadFolder();
    return AdminDialog(
      title: into == null ? 'Import a database' : 'Import into "$into"',
      width: 600,
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('jdb-import'),
          onPressed: _working ? null : _import,
          child: Text(_working ? 'Importing…' : 'Import'),
        ),
      ],
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              MessageBanner(
                message: _error!,
                tone: BannerTone.error,
                margin: const EdgeInsets.only(bottom: 12),
              ),
            SegmentedButton<_Source>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: _Source.paste,
                  label: Text('Paste'),
                  icon: Icon(Icons.content_paste),
                ),
                ButtonSegment(
                  value: _Source.file,
                  label: Text('File'),
                  icon: Icon(Icons.insert_drive_file_outlined),
                ),
              ],
              selected: {_source},
              onSelectionChanged: (s) => setState(() => _source = s.first),
            ),
            const SizedBox(height: 12),
            if (!fileSource)
              TextField(
                key: const ValueKey('jdb-import-text'),
                controller: _pasted,
                minLines: 6,
                maxLines: 12,
                style: AdminStyle.mono(context, fontSize: 12.5),
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText:
                      'A SQL script (as Export writes it) or a JSON export',
                  border: OutlineInputBorder(),
                ),
              )
            else
              _fileChooser(context),
            if (text != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '${_fileName ?? 'Pasted text'}: ${formatBytes(text.length)}, '
                  'read as ${BackupFormat.detect(text).label}.',
                  style: AdminStyle.caption(context),
                ),
              ),
            const SizedBox(height: 16),
            if (into != null)
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: true, label: Text('Replace "$into"')),
                  const ButtonSegment(
                    value: false,
                    label: Text('New database'),
                  ),
                ],
                selected: {_replace},
                onSelectionChanged: (s) => setState(() => _replace = s.first),
              ),
            if (!_replace) ...[
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('jdb-import-name'),
                controller: _name,
                onChanged: (_) {
                  if (_showErrors) setState(() {});
                },
                decoration: InputDecoration(
                  labelText: 'New database name',
                  border: const OutlineInputBorder(),
                  errorText: _showErrors
                      ? widget.controller.checkNewName(_name.text)
                      : null,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Created in the default mode and saved (not encrypted).',
                style: AdminStyle.caption(context),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _fileChooser(BuildContext context) {
    if (exports.canPickFiles) {
      return Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          key: const ValueKey('jdb-import-pick'),
          onPressed: _pick,
          icon: const Icon(Icons.folder_open),
          label: Text(_fileName == null ? 'Choose a file…' : 'Choose another…'),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          _folder == null ? 'Saved exports' : 'Saved exports in $_folder',
          style: AdminStyle.caption(context),
        ),
        const SizedBox(height: 4),
        SizedBox(
          height: 180,
          child: FutureBuilder<List<ExportFile>>(
            future: _files,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final files = snap.data ?? const <ExportFile>[];
              if (snap.hasError || files.isEmpty) {
                return Center(
                  child: Text(
                    snap.hasError
                        ? 'The folder could not be read.'
                        : 'No saved exports yet.',
                    style: AdminStyle.caption(context),
                  ),
                );
              }
              return Card(
                margin: EdgeInsets.zero,
                child: ListView(
                  children: [
                    for (final f in files)
                      ListTile(
                        dense: true,
                        selected: f.name == _fileName,
                        leading: Icon(
                          f.name.endsWith('.json')
                              ? Icons.data_object
                              : Icons.description_outlined,
                        ),
                        title: Text(f.name, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          '${formatBytes(f.sizeBytes)} · '
                          '${f.modified.toLocal().toString().substring(0, 16)}',
                        ),
                        onTap: () => _readPath(f.path),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        if (exports.canReadTypedPaths) ...[
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('jdb-import-path'),
            controller: _path,
            onSubmitted: _readPath,
            decoration: InputDecoration(
              labelText: 'Or a file path',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                tooltip: 'Read',
                icon: const Icon(Icons.arrow_forward),
                onPressed: () => _readPath(_path.text),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

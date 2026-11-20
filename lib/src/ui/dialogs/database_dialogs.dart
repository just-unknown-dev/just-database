/// Dialogs and menus for whole databases: create, open (with a passphrase
/// or a mode), duplicate, encryption, delete.
@internal
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../../core/workbench_service.dart' show AdminEncryption;
import '../../core/database_mode.dart';
import '../admin_selection.dart';
import '../admin_style.dart';
import '../admin_utils.dart';
import '../just_database_admin_controller.dart';
import '../pages/benchmark_page.dart';
import '../widgets/admin_widgets.dart';
import 'backup_dialogs.dart';
import 'schema_dialogs.dart';

/// What can be done to a database from its menu.
@internal
enum DatabaseAction {
  open,
  openInMode,
  close,
  changeMode,
  newTable,
  export,
  import,
  encryption,
  duplicate,
  flush,
  benchmark,
  seed,
  delete,
}

/// The menu entries for the database [name].
@internal
List<PopupMenuEntry<DatabaseAction>> databaseMenuItems(
  BuildContext context,
  JustDatabaseAdminController controller,
  String name, {
  required bool canSeed,
}) {
  final db = controller.findOpen(name);
  final info = controller.infoFor(name);
  final writable = !controller.readOnly;
  final persisted = db?.persist ?? info?.isPersisted ?? false;
  final open = db != null;
  final item = menuItem<DatabaseAction>;
  return [
    if (!open) ...[
      item(context, DatabaseAction.open, Icons.folder_open_outlined, 'Open'),
      item(context, DatabaseAction.openInMode, Icons.tune, 'Open in mode…'),
    ],
    if (open && writable)
      item(
        context,
        DatabaseAction.newTable,
        Icons.add_box_outlined,
        'New table…',
      ),
    if (open) ...[
      item(context, DatabaseAction.export, Icons.upload_outlined, 'Export…'),
      if (writable)
        item(
          context,
          DatabaseAction.import,
          Icons.download_outlined,
          'Import (replace)…',
        ),
      if (writable)
        item(context, DatabaseAction.duplicate, Icons.copy_all, 'Duplicate…'),
      if (writable && persisted)
        item(
          context,
          DatabaseAction.encryption,
          Icons.lock_outline,
          'Encryption…',
        ),
      if (persisted)
        item(context, DatabaseAction.flush, Icons.save_outlined, 'Save now'),
      if (controller.canChangeMode(name))
        item(context, DatabaseAction.changeMode, Icons.tune, 'Change mode…'),
      item(context, DatabaseAction.benchmark, Icons.speed, 'Benchmark'),
    ],
    if (canSeed && writable)
      item(
        context,
        DatabaseAction.seed,
        Icons.auto_awesome_outlined,
        'Seed sample data',
      ),
    if (open && controller.opened(name))
      item(context, DatabaseAction.close, Icons.close, 'Close'),
    if (writable) ...[
      const PopupMenuDivider(),
      item(
        context,
        DatabaseAction.delete,
        Icons.delete_outline,
        'Delete…',
        destructive: true,
      ),
    ],
  ];
}

/// Runs [action] on the database [name].
@internal
Future<void> runDatabaseAction(
  BuildContext context,
  JustDatabaseAdminController controller,
  String name,
  DatabaseAction action, {
  SeedDatabaseCallback? onSeed,
}) async {
  switch (action) {
    case DatabaseAction.open:
      await selectWithPrompt(context, controller, AdminSelection(name));
    case DatabaseAction.openInMode:
      final mode = await showModeDialog(
        context,
        title: 'Open "$name" in mode',
        initial: controller.defaultMode,
      );
      if (mode == null || !context.mounted) return;
      if (await openWithPrompt(context, controller, name, mode: mode) &&
          context.mounted) {
        await controller.select(AdminSelection(name));
      }
    case DatabaseAction.close:
      final ok = await controller.close(name);
      if (context.mounted) {
        reportOutcome(
          context,
          ok,
          success: 'Closed "$name".',
          error: controller.lastError,
        );
      }
    case DatabaseAction.changeMode:
      final db = controller.findOpen(name);
      final mode = await showModeDialog(
        context,
        title: 'Mode of "$name"',
        initial: db?.mode ?? controller.defaultMode,
      );
      if (mode == null || mode == db?.mode || !context.mounted) return;
      final ok = await controller.reopen(name, mode);
      if (context.mounted) {
        reportOutcome(
          context,
          ok,
          success: '"$name" is now in ${modeLabel(mode)} mode.',
          error: controller.lastError,
        );
      }
    case DatabaseAction.newTable:
      final db = controller.findOpen(name);
      if (db == null) return;
      final table = await showCreateTableDialog(context, db);
      if (table != null && context.mounted) {
        await controller.select(
          AdminSelection(
            name,
            kind: AdminObjectKind.table,
            object: table,
            pane: AdminPane.structure,
          ),
        );
      }
    case DatabaseAction.export:
      await showDatabaseExportDialog(context, controller, name);
    case DatabaseAction.import:
      await showImportDialog(context, controller, into: name);
    case DatabaseAction.encryption:
      await showDialog<void>(
        context: context,
        builder: (_) => _EncryptionDialog(controller: controller, name: name),
      );
    case DatabaseAction.duplicate:
      await showDialog<void>(
        context: context,
        builder: (_) => _DuplicateDialog(controller: controller, source: name),
      );
    case DatabaseAction.flush:
      final ok = await controller.flush(name);
      if (context.mounted) {
        reportOutcome(
          context,
          ok,
          success: 'Saved "$name".',
          error: controller.lastError,
        );
      }
    case DatabaseAction.benchmark:
      await pushAdminPage<void>(
        context,
        BenchmarkPage(
          host: controller.host,
          database: controller.findOpen(name),
        ),
      );
    case DatabaseAction.seed:
      final seed = onSeed;
      if (seed == null) return;
      final ok = await controller.seed(name, seed);
      if (context.mounted) {
        reportOutcome(
          context,
          ok,
          success: 'Added sample data to "$name".',
          error: controller.lastError,
        );
      }
    case DatabaseAction.delete:
      await confirmAndDelete(context, controller, name);
  }
}

/// Asks, then deletes [name].
@internal
Future<void> confirmAndDelete(
  BuildContext context,
  JustDatabaseAdminController controller,
  String name,
) async {
  final open = controller.findOpen(name) != null;
  final mine = controller.opened(name);
  final confirmed = await confirmAction(
    context,
    title: 'Delete "$name"?',
    message:
        'All of its data is removed for good.'
        '${open && !mine ? ' The app has it open: it is closed for the app too.' : ''}'
        '${controller.isEncrypted(name) ? ' A random key stored for it is deleted too.' : ''}',
  );
  if (!confirmed || !context.mounted) return;
  final ok = await controller.delete(name);
  if (context.mounted) {
    reportOutcome(
      context,
      ok,
      success: 'Deleted "$name".',
      error: controller.lastError,
    );
  }
}

/// Opens [name], asking for its passphrase when it needs one. Returns
/// whether it is open.
@internal
Future<bool> openWithPrompt(
  BuildContext context,
  JustDatabaseAdminController controller,
  String name, {
  DatabaseMode? mode,
}) async {
  if (await controller.open(name, mode: mode)) return true;
  if (!context.mounted) return false;
  if (controller.passphraseNeededFor?.toLowerCase() == name.toLowerCase()) {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) =>
          _PassphraseDialog(controller: controller, name: name, mode: mode),
    );
    return ok == true;
  }
  showAdminError(context, controller.lastError ?? 'Could not open "$name".');
  return false;
}

/// Shows [selection], opening its database first (asking for a passphrase
/// when needed). Returns whether it is shown.
@internal
Future<bool> selectWithPrompt(
  BuildContext context,
  JustDatabaseAdminController controller,
  AdminSelection selection,
) async {
  if (controller.findOpen(selection.database) == null &&
      !await openWithPrompt(context, controller, selection.database)) {
    return false;
  }
  final ok = await controller.select(selection);
  if (!ok && context.mounted) {
    showAdminError(context, controller.lastError ?? 'Could not open it.');
  }
  return ok;
}

/// Asks for a mode.
@internal
Future<DatabaseMode?> showModeDialog(
  BuildContext context, {
  required String title,
  required DatabaseMode initial,
}) => showDialog<DatabaseMode>(
  context: context,
  builder: (context) {
    var mode = initial;
    return StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: RadioGroup<DatabaseMode>(
            groupValue: mode,
            onChanged: (v) => setState(() => mode = v ?? mode),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final m in DatabaseMode.values)
                  RadioListTile<DatabaseMode>(
                    contentPadding: EdgeInsets.zero,
                    value: m,
                    secondary: Icon(modeIcon(m)),
                    title: Text(modeLabel(m)),
                    subtitle: Text(modeDescription(m)),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, mode),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  },
);

/// Asks for a new database and creates it. Returns its name.
@internal
Future<String?> showCreateDatabaseDialog(
  BuildContext context,
  JustDatabaseAdminController controller,
) => showDialog<String>(
  context: context,
  builder: (_) => _CreateDatabaseDialog(controller: controller),
);

// ---------------------------------------------------------------------------
// Encryption choice
// ---------------------------------------------------------------------------

/// Pick none / random key / passphrase, with passphrase fields.
class _EncryptionChoice extends StatelessWidget {
  const _EncryptionChoice({
    required this.value,
    required this.onChanged,
    required this.passphrase,
    required this.confirm,
    required this.showErrors,
    this.onChangedText,
  });

  final AdminEncryption value;
  final ValueChanged<AdminEncryption> onChanged;
  final TextEditingController passphrase;
  final TextEditingController confirm;
  final bool showErrors;
  final VoidCallback? onChangedText;

  static String? problem(
    AdminEncryption value,
    TextEditingController passphrase,
    TextEditingController confirm,
  ) {
    if (value != AdminEncryption.passphrase) return null;
    if (passphrase.text.isEmpty) return 'Enter a passphrase.';
    if (passphrase.text != confirm.text) return 'The passphrases differ.';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final error = showErrors ? problem(value, passphrase, confirm) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<AdminEncryption>(
          key: const ValueKey('jdb-encryption'),
          showSelectedIcon: false,
          segments: [
            const ButtonSegment(
              value: AdminEncryption.none,
              label: Text('None'),
              icon: Icon(Icons.lock_open_outlined),
            ),
            const ButtonSegment(
              value: AdminEncryption.randomKey,
              label: Text('Random key'),
              icon: Icon(Icons.key_outlined),
            ),
            const ButtonSegment(
              value: AdminEncryption.passphrase,
              label: Text('Passphrase'),
              icon: Icon(Icons.password),
            ),
          ],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
        ),
        const SizedBox(height: 8),
        Text(switch (value) {
          AdminEncryption.none => 'Saved as plain JSON.',
          AdminEncryption.randomKey =>
            'AES-256-GCM with a random key that SecureKeyManager keeps in '
                "this app's private storage. Protects a copied file, not a "
                "device where someone can read all of the app's data.",
          AdminEncryption.passphrase =>
            'AES-256-GCM with a key derived from the passphrase (PBKDF2, '
                '600 000 iterations). The passphrase is not stored: the app '
                'must open the database with it.',
        }, style: AdminStyle.caption(context)),
        if (value == AdminEncryption.passphrase) ...[
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('jdb-passphrase'),
            controller: passphrase,
            obscureText: true,
            onChanged: (_) => onChangedText?.call(),
            decoration: const InputDecoration(
              labelText: 'Passphrase',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey('jdb-passphrase-confirm'),
            controller: confirm,
            obscureText: true,
            onChanged: (_) => onChangedText?.call(),
            decoration: InputDecoration(
              labelText: 'Repeat the passphrase',
              border: const OutlineInputBorder(),
              isDense: true,
              errorText: error,
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Create
// ---------------------------------------------------------------------------

class _CreateDatabaseDialog extends StatefulWidget {
  const _CreateDatabaseDialog({required this.controller});

  final JustDatabaseAdminController controller;

  @override
  State<_CreateDatabaseDialog> createState() => _CreateDatabaseDialogState();
}

class _CreateDatabaseDialogState extends State<_CreateDatabaseDialog> {
  final _name = TextEditingController();
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  late DatabaseMode _mode = widget.controller.defaultMode;
  late bool _persist = widget.controller.persistByDefault;
  AdminEncryption _encryption = AdminEncryption.none;
  bool _showErrors = false;
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  String? get _nameError => widget.controller.checkNewName(_name.text);

  Future<void> _submit() async {
    if (_working) return;
    final problem =
        _nameError ??
        _EncryptionChoice.problem(_encryption, _passphrase, _confirm);
    if (problem != null) {
      setState(() => _showErrors = true);
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    final name = _name.text;
    final ok = await widget.controller.create(
      name,
      mode: _mode,
      persist: _persist,
      encryption: _encryption,
      passphrase: _passphrase.text,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, name);
      showAdminMessage(context, 'Created "$name".');
    } else {
      setState(() {
        _working = false;
        _error = widget.controller.lastError;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final encrypted = _encryption != AdminEncryption.none;
    return AdminDialog(
      title: 'New database',
      width: 480,
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('jdb-create'),
          onPressed: _working ? null : _submit,
          child: Text(_working ? 'Creating…' : 'Create'),
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
            TextField(
              key: const ValueKey('jdb-new-name'),
              controller: _name,
              autofocus: true,
              onChanged: (_) {
                if (_showErrors) setState(() {});
              },
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. saves',
                helperText: 'Letters, digits, "_", "." and "-"',
                errorText: _showErrors ? _nameError : null,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<DatabaseMode>(
              key: const ValueKey('jdb-new-mode'),
              initialValue: _mode,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: 'Mode',
                helperText: modeDescription(_mode),
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final m in DatabaseMode.values)
                  DropdownMenuItem(value: m, child: Text(modeLabel(m))),
              ],
              onChanged: (v) => setState(() => _mode = v ?? _mode),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const ValueKey('jdb-new-persist'),
              contentPadding: EdgeInsets.zero,
              title: const Text('Save to storage'),
              subtitle: Text(
                encrypted
                    ? 'Encrypted databases are always saved.'
                    : _persist
                    ? 'Saved after every change.'
                    : 'In memory only: gone when the app (or this screen) closes it.',
              ),
              value: encrypted || _persist,
              onChanged: encrypted ? null : (v) => setState(() => _persist = v),
            ),
            const SizedBox(height: 8),
            Text('Encryption', style: AdminStyle.heading(context)),
            const SizedBox(height: 8),
            _EncryptionChoice(
              value: _encryption,
              onChanged: (v) => setState(() => _encryption = v),
              passphrase: _passphrase,
              confirm: _confirm,
              showErrors: _showErrors,
              onChangedText: () {
                if (_showErrors) setState(() {});
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Passphrase
// ---------------------------------------------------------------------------

class _PassphraseDialog extends StatefulWidget {
  const _PassphraseDialog({
    required this.controller,
    required this.name,
    required this.mode,
  });

  final JustDatabaseAdminController controller;
  final String name;
  final DatabaseMode? mode;

  @override
  State<_PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<_PassphraseDialog> {
  final _passphrase = TextEditingController();
  bool _working = false;
  bool _show = false;
  String? _error;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (_working || _passphrase.text.isEmpty) return;
    setState(() {
      _working = true;
      _error = null;
    });
    final ok = await widget.controller.open(
      widget.name,
      mode: widget.mode,
      passphrase: _passphrase.text,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context, true);
    } else {
      setState(() {
        _working = false;
        _error = widget.controller.lastError;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Open "${widget.name}"'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'This database is encrypted with a passphrase this screen does '
              'not know. It is used for this session only.',
            ),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('jdb-open-passphrase'),
              controller: _passphrase,
              autofocus: true,
              obscureText: !_show,
              onSubmitted: (_) => _open(),
              decoration: InputDecoration(
                labelText: 'Passphrase',
                border: const OutlineInputBorder(),
                errorText: _error,
                errorMaxLines: 4,
                suffixIcon: IconButton(
                  tooltip: _show ? 'Hide' : 'Show',
                  icon: Icon(_show ? Icons.visibility_off : Icons.visibility),
                  onPressed: () => setState(() => _show = !_show),
                ),
              ),
            ),
            if (_working) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 4),
              Text(
                'Deriving the key (this takes a moment)…',
                style: AdminStyle.caption(context),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('jdb-open-passphrase-ok'),
          onPressed: _working ? null : _open,
          child: const Text('Open'),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Duplicate
// ---------------------------------------------------------------------------

class _DuplicateDialog extends StatefulWidget {
  const _DuplicateDialog({required this.controller, required this.source});

  final JustDatabaseAdminController controller;
  final String source;

  @override
  State<_DuplicateDialog> createState() => _DuplicateDialogState();
}

class _DuplicateDialogState extends State<_DuplicateDialog> {
  late final _name = TextEditingController(text: '${widget.source}_copy');
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  AdminEncryption _encryption = AdminEncryption.none;
  bool _showErrors = false;
  bool _working = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final problem =
        widget.controller.checkNewName(_name.text) ??
        _EncryptionChoice.problem(_encryption, _passphrase, _confirm);
    if (problem != null) {
      setState(() => _showErrors = true);
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    final name = _name.text;
    final ok = await widget.controller.duplicate(
      widget.source,
      name,
      encryption: _encryption,
      passphrase: _passphrase.text,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
      showAdminMessage(context, 'Copied "${widget.source}" to "$name".');
    } else {
      setState(() {
        _working = false;
        _error = widget.controller.lastError;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final db = widget.controller.findOpen(widget.source);
    final inMemory = db != null && !db.persist;
    return AdminDialog(
      title: 'Duplicate "${widget.source}"',
      width: 480,
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('jdb-duplicate'),
          onPressed: _working ? null : _submit,
          child: Text(_working ? 'Copying…' : 'Duplicate'),
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
            TextField(
              key: const ValueKey('jdb-duplicate-name'),
              controller: _name,
              autofocus: true,
              onChanged: (_) {
                if (_showErrors) setState(() {});
              },
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: 'Name of the copy',
                errorText: _showErrors
                    ? widget.controller.checkNewName(_name.text)
                    : null,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              inMemory
                  ? 'The copy is in memory too (same mode).'
                  : 'The copy is saved, in the same mode.',
              style: AdminStyle.caption(context),
            ),
            if (!inMemory) ...[
              const SizedBox(height: 16),
              Text(
                'Encryption of the copy',
                style: AdminStyle.heading(context),
              ),
              const SizedBox(height: 8),
              _EncryptionChoice(
                value: _encryption,
                onChanged: (v) => setState(() => _encryption = v),
                passphrase: _passphrase,
                confirm: _confirm,
                showErrors: _showErrors,
                onChangedText: () {
                  if (_showErrors) setState(() {});
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Encryption
// ---------------------------------------------------------------------------

class _EncryptionDialog extends StatefulWidget {
  const _EncryptionDialog({required this.controller, required this.name});

  final JustDatabaseAdminController controller;
  final String name;

  @override
  State<_EncryptionDialog> createState() => _EncryptionDialogState();
}

class _EncryptionDialogState extends State<_EncryptionDialog> {
  final _passphrase = TextEditingController();
  final _confirm = TextEditingController();
  AdminEncryption? _current;
  late AdminEncryption _choice;
  bool _showErrors = false;
  bool _working = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _choice = widget.controller.isEncrypted(widget.name)
        ? AdminEncryption.passphrase
        : AdminEncryption.randomKey;
    _loadCurrent();
  }

  Future<void> _loadCurrent() async {
    final encrypted = widget.controller.isEncrypted(widget.name);
    var current = AdminEncryption.none;
    if (encrypted) {
      var auto = false;
      try {
        auto = await widget.controller.host.hasStoredKey(widget.name);
      } catch (_) {}
      current = auto ? AdminEncryption.randomKey : AdminEncryption.passphrase;
    }
    if (!mounted) return;
    setState(() {
      _current = current;
      _choice = switch (current) {
        AdminEncryption.none => AdminEncryption.randomKey,
        AdminEncryption.randomKey => AdminEncryption.passphrase,
        AdminEncryption.passphrase => AdminEncryption.passphrase,
      };
    });
  }

  @override
  void dispose() {
    _passphrase.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final problem = _EncryptionChoice.problem(_choice, _passphrase, _confirm);
    if (problem != null) {
      setState(() => _showErrors = true);
      return;
    }
    if (_choice == AdminEncryption.none &&
        !await confirmAction(
          context,
          title: 'Remove encryption?',
          message:
              '"${widget.name}" is saved as plain JSON from now on; anyone '
              'with the file can read it.',
          confirmLabel: 'Remove',
        )) {
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    final ok = await widget.controller.setEncryption(
      widget.name,
      _choice,
      passphrase: _passphrase.text,
    );
    if (!mounted) return;
    if (ok) {
      Navigator.pop(context);
      showAdminMessage(context, switch (_choice) {
        AdminEncryption.none => '"${widget.name}" is no longer encrypted.',
        AdminEncryption.randomKey =>
          '"${widget.name}" is encrypted with a random key.',
        AdminEncryption.passphrase =>
          '"${widget.name}" is encrypted with the new passphrase.',
      });
    } else {
      setState(() {
        _working = false;
        _error = widget.controller.lastError;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = _current;
    final status = switch (current) {
      null => 'Checking…',
      AdminEncryption.none => 'Not encrypted.',
      AdminEncryption.randomKey =>
        "Encrypted with a random key kept in this app's private storage.",
      AdminEncryption.passphrase => 'Encrypted with a passphrase.',
    };
    return AdminDialog(
      title: 'Encryption of "${widget.name}"',
      width: 500,
      actions: [
        TextButton(
          onPressed: _working ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('jdb-encryption-apply'),
          onPressed: _working || current == null ? null : _apply,
          child: Text(_working ? 'Saving…' : 'Apply'),
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
            Text(status, style: AdminStyle.label(context)),
            const SizedBox(height: 16),
            _EncryptionChoice(
              value: _choice,
              onChanged: (v) => setState(() => _choice = v),
              passphrase: _passphrase,
              confirm: _confirm,
              showErrors: _showErrors,
              onChangedText: () {
                if (_showErrors) setState(() {});
              },
            ),
            const SizedBox(height: 12),
            const MessageBanner(
              tone: BannerTone.warning,
              message:
                  'The file is rewritten at once. Code that opens this '
                  'database with JustDatabase.open must pass the new '
                  'encryptionKey (or none) from now on.',
            ),
          ],
        ),
      ),
    );
  }
}

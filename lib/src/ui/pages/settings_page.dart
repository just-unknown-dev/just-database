/// The admin screen's settings, "delete everything", and about.
@internal
library;

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter/material.dart';

import '../../core/database_mode.dart';
import '../../core/version.dart';
import '../../io/exports.dart'
    if (dart.library.js_interop) '../../web/exports.dart'
    as exports;
import '../admin_preferences.dart';
import '../admin_style.dart';
import '../admin_utils.dart';
import '../just_database_admin_controller.dart';
import '../widgets/admin_widgets.dart';

const String _repository = 'https://github.com/just-unknown-dev/just-database';

/// The choices of the Appearance setting.
enum _Appearance {
  dark(
    'Dark',
    'Always dark (the default).',
    Icons.dark_mode_outlined,
    ThemeMode.dark,
  ),
  light('Light', 'Always light.', Icons.light_mode_outlined, ThemeMode.light),
  device(
    'Match the device',
    "Follows the device's light or dark setting.",
    Icons.brightness_auto_outlined,
    ThemeMode.system,
  );

  const _Appearance(this.label, this.description, this.icon, this.mode);

  final String label;
  final String description;
  final IconData icon;
  final ThemeMode mode;

  static _Appearance of(ThemeMode mode) =>
      values.firstWhere((a) => a.mode == mode);
}

/// Appearance; settings for new databases, the data browser and the
/// console; delete every database; about.
@internal
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key, required this.controller});

  final JustDatabaseAdminController controller;

  Future<void> _deleteAll(BuildContext context) async {
    final count = controller.databases.length;
    final ok = await confirmAction(
      context,
      title: 'Delete every database?',
      message:
          'This closes and deletes ${plural(count, 'database')} (open ones '
          'too, for the app as well) and the random keys stored for them. '
          'It cannot be undone.',
      confirmLabel: 'Delete all',
      typeToConfirm: 'DELETE',
    );
    if (!ok || !context.mounted) return;
    final done = await controller.deleteAll();
    if (!context.mounted) return;
    reportOutcome(
      context,
      done,
      success: 'Deleted every database.',
      error: controller.lastError,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final cs = Theme.of(context).colorScheme;
        final c = controller;
        const gap = SizedBox(height: 12);
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  SectionCard(
                    title: 'Appearance',
                    children: [
                      RadioGroup<_Appearance>(
                        groupValue: _Appearance.of(c.themeMode),
                        onChanged: (v) {
                          if (v != null) c.setThemeMode(v.mode);
                        },
                        child: Column(
                          children: [
                            for (final a in _Appearance.values)
                              RadioListTile<_Appearance>(
                                key: ValueKey('jdb-setting-theme-${a.name}'),
                                value: a,
                                title: Text(a.label),
                                subtitle: Text(a.description),
                                secondary: Icon(a.icon),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  gap,
                  SectionCard(
                    title: 'New databases',
                    children: [
                      SwitchListTile(
                        key: const ValueKey('jdb-setting-persist'),
                        title: const Text('Save new databases'),
                        subtitle: const Text(
                          'The default in the New database dialog. Saved '
                          'databases always open from storage.',
                        ),
                        value: c.persistByDefault,
                        onChanged: c.readOnly ? null : c.setPersistByDefault,
                      ),
                      const Divider(height: 1),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Text(
                          'Default mode (also used to open saved databases)',
                          style: AdminStyle.heading(context),
                        ),
                      ),
                      RadioGroup<DatabaseMode>(
                        groupValue: c.defaultMode,
                        onChanged: (v) {
                          if (v != null) c.setDefaultMode(v);
                        },
                        child: Column(
                          children: [
                            for (final mode in DatabaseMode.values)
                              RadioListTile<DatabaseMode>(
                                key: ValueKey('jdb-setting-mode-${mode.name}'),
                                value: mode,
                                title: Text(modeLabel(mode)),
                                subtitle: Text(modeDescription(mode)),
                                secondary: Icon(modeIcon(mode)),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  gap,
                  SectionCard(
                    title: 'Data browser and SQL console',
                    children: [
                      ListTile(
                        title: const Text('Rows per page'),
                        trailing: DropdownButton<int>(
                          key: const ValueKey('jdb-setting-page-size'),
                          value: c.pageSize,
                          underline: const SizedBox.shrink(),
                          items: [
                            for (final s in AdminPreferences.pageSizes)
                              DropdownMenuItem(value: s, child: Text('$s')),
                          ],
                          onChanged: (v) {
                            if (v != null) c.setPageSize(v);
                          },
                        ),
                      ),
                      ListTile(
                        title: const Text('SQL history'),
                        subtitle: Text(
                          '${plural(c.history.length, 'statement')} · '
                          '${plural(c.snippets.length, 'snippet')} saved',
                        ),
                        trailing: TextButton(
                          onPressed: c.history.isEmpty ? null : c.clearHistory,
                          child: const Text('Clear history'),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: Text(
                          c.rememberSettings
                              ? 'These settings, the history and the snippets '
                                    'are kept between runs (just_storage).'
                              : 'These settings, the history and the snippets '
                                    'last until the screen closes.',
                          style: AdminStyle.caption(context),
                        ),
                      ),
                    ],
                  ),
                  gap,
                  SectionCard(
                    title: 'Exports',
                    children: [
                      FutureBuilder<String?>(
                        future: exports.exportsLocation(),
                        builder: (context, snap) => ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: const Text('Saved exports go to'),
                          subtitle: SelectableText(
                            snap.connectionState != ConnectionState.done
                                ? '…'
                                : (snap.data ?? "the browser's downloads"),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (!c.readOnly) ...[
                    gap,
                    SectionCard(
                      title: 'Danger zone',
                      titleColor: cs.error,
                      children: [
                        ListTile(
                          key: const ValueKey('jdb-delete-all'),
                          leading: Icon(Icons.delete_forever, color: cs.error),
                          title: Text(
                            'Delete every database',
                            style: TextStyle(color: cs.error),
                          ),
                          subtitle: const Text(
                            'Closes and deletes every database of this app, '
                            'open or saved, and their stored random keys.',
                          ),
                          onTap: () => _deleteAll(context),
                        ),
                      ],
                    ),
                  ],
                  gap,
                  const SectionCard(
                    title: 'About',
                    children: [
                      ListTile(
                        leading: Icon(Icons.info_outline),
                        title: Text('Just Database $kJustDatabaseVersion'),
                        subtitle: Text(
                          'A pure-Dart SQL database with SQLite semantics: '
                          'saved to a file (IndexedDB on the web), optional '
                          'AES-256-GCM encryption, migrations, an ORM.',
                        ),
                      ),
                      ListTile(
                        leading: Icon(Icons.gavel_outlined),
                        title: Text('License'),
                        subtitle: Text('BSD 3-Clause'),
                      ),
                      ListTile(
                        leading: Icon(Icons.hub_outlined),
                        title: Text('Repository'),
                        subtitle: SelectableText(_repository),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

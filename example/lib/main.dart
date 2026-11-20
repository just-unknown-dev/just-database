// Opens a sample database (saved, so it is there on the next run) and
// shows the just_database workbench. The bar above it runs the API tour
// (lib/tour.dart) and switches the workbench to read-only.
import 'package:flutter/material.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/ui.dart';

import 'tour.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final db = await JustDatabase.open('sample');
  await seedSample(db);
  runApp(const ExampleApp());
}

/// Creates and fills the sample tables the first time.
Future<void> seedSample(JustDatabase db) async {
  if (db.tableNames.contains('people')) return;
  await db.transaction((tx) async {
    await tx.execute('''
      CREATE TABLE people (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT UNIQUE,
        active BOOLEAN DEFAULT 1,
        joined DATETIME DEFAULT CURRENT_TIMESTAMP
      )''');
    await tx.execute('''
      CREATE TABLE notes (
        id INTEGER PRIMARY KEY,
        person_id INTEGER REFERENCES people (id) ON DELETE CASCADE,
        body TEXT NOT NULL
      )''');
    await tx.execute('CREATE INDEX notes_person ON notes (person_id)');
    await tx.execute('''
      CREATE VIEW active_people AS
        SELECT id, name, email FROM people WHERE active = 1''');
    for (final (name, email) in [
      ('Ann', 'ann@example.com'),
      ("Bob O'Neil", 'bob@example.com'),
      ('Cy', null),
    ]) {
      final r = await tx.execute(
        'INSERT INTO people (name, email) VALUES (?, ?)',
        [name, email],
      );
      await tx.execute('INSERT INTO notes (person_id, body) VALUES (?, ?)', [
        r.lastInsertRowId,
        'First note of $name',
      ]);
    }
  });
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Just Database example',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.dark,
    ),
    home: const _Home(),
  );
}

class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  bool _readOnly = false;

  Future<void> _tour() async {
    final log = await runTour();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('API tour'),
        content: SingleChildScrollView(child: Text(log.join('\n'))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Material(
          color: cs.surfaceContainerHighest,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: _tour,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Run the API tour'),
                  ),
                  const Spacer(),
                  const Text('Read-only'),
                  Switch(
                    value: _readOnly,
                    onChanged: (v) => setState(() => _readOnly = v),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: JustDatabaseAdminScreen(
              readOnly: _readOnly,
              onSeedDatabase: seedSample,
            ),
          ),
        ),
      ],
    );
  }
}

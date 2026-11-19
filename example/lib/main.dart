// Opens a sample database (saved, so it is there on the next run) and
// shows the just_database admin UI. The "Run the tour" button runs
// example/example.dart and shows what it printed.
import 'package:flutter/material.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/ui.dart';

import '../example.dart';

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
    title: 'just_database example',
    theme: ThemeData(colorSchemeSeed: Colors.indigo),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.indigo,
      brightness: Brightness.dark,
    ),
    home: const _Home(),
  );
}

class _Home extends StatelessWidget {
  const _Home();

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      JustDatabaseAdminScreen(onSeedDatabase: seedSample),
      Positioned(
        right: 16,
        bottom: 16,
        child: FloatingActionButton.extended(
          onPressed: () async {
            final log = await runTour();
            if (!context.mounted) return;
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
          },
          icon: const Icon(Icons.play_arrow),
          label: const Text('Run the tour'),
        ),
      ),
    ],
  );
}

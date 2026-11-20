// A tour of just_database: tables, bound parameters, joins, a
// transaction, a migration, the ORM and a backup. Every result is checked
// with orThrow(), so a mistake stops the tour with a SqlException.
//
// The example app (lib/main.dart) runs it from its "Run the API tour"
// button; example.dart runs it on its own.
import 'package:flutter/foundation.dart';
import 'package:just_database/just_database.dart';

/// A record for the ORM part of the tour.
class Task extends DbRecord {
  const Task({super.id, required this.title, this.done = false, this.due});

  final String title;
  final bool done;
  final DateTime? due;

  @override
  Map<String, Object?> toMap() => {'title': title, 'done': done, 'due': due};
}

/// The `tasks` table, typed.
class Tasks extends DbTable<Task> {
  @override
  String get tableName => 'tasks';

  @override
  List<DbColumn> get columns => [
    DbColumn.text('title', notNull: true),
    DbColumn.boolean('done', defaultValue: false),
    DbColumn.datetime('due'),
  ];

  @override
  Task fromRow(Map<String, Object?> row) => Task(
    id: row.intValue('id'),
    title: row.stringValue('title')!,
    done: row.boolValue('done') ?? false,
    due: row.dateTimeValue('due'),
  );
}

/// Runs the tour on an in-memory database and returns what it printed.
Future<List<String>> runTour() async {
  final log = <String>[];
  void say(Object line) {
    log.add('$line');
    debugPrint('$line');
  }

  final db = await JustDatabase.open('tour', persist: false);
  try {
    // Tables and bound parameters.
    (await db.execute('''
      CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE)
    ''')).orThrow();
    (await db.execute('''
      CREATE TABLE books (
        id INTEGER PRIMARY KEY,
        author_id INTEGER REFERENCES authors (id) ON DELETE CASCADE,
        title TEXT NOT NULL,
        year INTEGER CHECK (year > 0)
      )''')).orThrow();
    for (final name in ['Austen', "O'Brien"]) {
      (await db.execute('INSERT INTO authors (name) VALUES (?)', [
        name,
      ])).orThrow();
    }
    (await db.execute(
      'INSERT INTO books (author_id, title, year) VALUES (?, ?, ?), (?, ?, ?)',
      [1, 'Emma', 1815, 2, 'At Swim-Two-Birds', 1939],
    )).orThrow();

    // A join with an aggregate.
    final perAuthor = (await db.query('''
      SELECT a.name, COUNT(b.id) AS books, MIN(b.year) AS first
      FROM authors a LEFT JOIN books b ON b.author_id = a.id
      GROUP BY a.id ORDER BY a.name
    ''')).orThrow();
    for (final row in perAuthor.rows) {
      say('${row['name']}: ${row['books']} book(s), first in ${row['first']}');
    }

    // A transaction: either both statements happen or neither.
    try {
      await db.transaction((tx) async {
        await tx.execute(
          "INSERT INTO books (author_id, title, year) VALUES (1, 'Persuasion', 1817)",
        );
        await tx.execute(
          "INSERT INTO books (author_id, title, year) VALUES (1, 'Broken', 0)",
        );
      });
    } on SqlException catch (e) {
      say('rolled back: ${e.message}');
    }
    say('books: ${(await db.query('SELECT COUNT(*) FROM books')).scalar}');

    // A migration.
    final results = await db.migrate([
      SqlMigration(
        version: 1,
        name: 'add isbn',
        upSql: 'ALTER TABLE books ADD COLUMN isbn TEXT',
      ),
    ]);
    say('migration: ${results.single.status.name}');

    // The ORM.
    final tasks = Tasks();
    await tasks.createTable(db);
    final saved = await tasks.insert(
      db,
      Task(title: 'Read Emma', due: DateTime.utc(2030, 1, 1)),
    );
    await tasks.update(
      db,
      Task(id: saved.id, title: saved.title, done: true, due: saved.due),
    );
    final done = await tasks.findAll(db, where: 'done = ?', whereArgs: [true]);
    say(
      'done: ${done.single.title}, due ${done.single.due!.toIso8601String()}',
    );

    // A backup into another database.
    final copy = await JustDatabase.open('tour_copy', persist: false);
    await copy.importSql(await db.exportSql());
    say('copy has ${copy.totalRows} rows in ${copy.tableNames.join(', ')}');
    await copy.close();
  } finally {
    await db.close();
  }
  return log;
}

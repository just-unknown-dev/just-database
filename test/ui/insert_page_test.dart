// Widget tests for InsertPage: bound parameters, validation, NULL and
// DEFAULT, the UTC date picker and switching tables.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/ui.dart';

import 'ui_test_support.dart';

// In-memory databases only: everything runs in the test's fake-async zone
// (see `drive` in ui_test_support.dart), and each test closes its database.
Future<JustDatabase> _openDb(
  WidgetTester tester,
  String prefix,
  List<String> sql,
) async {
  final db = await JustDatabase.open(uniqueName(prefix), persist: false);
  for (final s in sql) {
    await exec(db, s);
  }
  return db;
}

Future<List<List<Object?>>> _rows(
  WidgetTester tester,
  JustDatabase db,
  String sql,
) async {
  final r = await db.query(sql);
  expect(r.success, isTrue, reason: r.errorMessage);
  return r.values;
}

Future<void> _pumpInsert(
  WidgetTester tester,
  JustDatabase db,
  String table,
) async {
  useLargeWindow(tester, size: const Size(1200, 1600));
  await tester.pumpWidget(
    MaterialApp(
      home: InsertPage(database: db, initialTable: table),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _submit(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('jdb-insert-submit')));
  await tester.pumpAndSettle();
}

void main() {
  late FakePaths paths;
  setUpAll(() async => paths = await FakePaths.install());
  tearDownAll(() => paths.dispose());

  testWidgets('stores values with quotes exactly as typed (bound parameters)', (
    tester,
  ) async {
    final db = await _openDb(tester, 'quotes', [
      'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, at DATETIME, n INTEGER, r REAL)',
    ]);
    await _pumpInsert(tester, db, 't');

    const name = 'O\'Brien "x"); DROP TABLE t; --';
    const at = "2026-01-01', 'a'), ('2026-01-02";
    await tester.enterText(fieldOf('name'), name);
    await tester.enterText(fieldOf('at'), at);
    await tester.enterText(fieldOf('n'), '42');
    await tester.enterText(fieldOf('r'), '-1.5');
    await _submit(tester);

    expect(find.text('Inserted a row into t (rowid 1).'), findsOneWidget);
    expect(await _rows(tester, db, 'SELECT id, name, at, n, r FROM t'), [
      [1, name, at, 42, -1.5],
    ]);
    // The form is ready for the next row.
    expect(
      tester.widget<TextFormField>(fieldOf('name')).controller!.text,
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('INTEGER and REAL input is validated before anything runs', (
    tester,
  ) async {
    final db = await _openDb(tester, 'validate', [
      'CREATE TABLE v (n INTEGER, r REAL NOT NULL)',
    ]);
    await _pumpInsert(tester, db, 'v');

    await tester.enterText(fieldOf('n'), '-');
    await tester.enterText(fieldOf('r'), 'abc');
    await _submit(tester);

    expect(find.text('Enter a whole number, or choose NULL.'), findsOneWidget);
    expect(find.text('Enter a number.'), findsOneWidget);
    expect(await _rows(tester, db, 'SELECT COUNT(*) FROM v'), [
      [0],
    ]);

    await tester.enterText(fieldOf('n'), '7');
    await tester.enterText(fieldOf('r'), '2.5e3');
    await _submit(tester);
    expect(await _rows(tester, db, 'SELECT n, r FROM v'), [
      [7, 2500.0],
    ]);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('untouched columns get their DEFAULT, NULL or the next rowid; '
      "an empty NOT NULL text is ''", (tester) async {
    final db = await _openDb(tester, 'defaults', [
      "CREATE TABLE d (id INTEGER PRIMARY KEY, s TEXT DEFAULT 'dflt', t TEXT, u TEXT NOT NULL, b BOOLEAN)",
    ]);
    await _pumpInsert(tester, db, 'd');

    expect(find.text('DEFAULT \'dflt\''), findsOneWidget); // the hint of s
    await _submit(tester);
    expect(await _rows(tester, db, 'SELECT id, s, t, u, b FROM d'), [
      [1, 'dflt', null, '', null],
    ]);

    // A switch stores 1/0; a column can be set to NULL explicitly.
    await tester.tap(fieldOf('b'));
    await tester.enterText(fieldOf('s'), 'x');
    await tester.tap(modeMenuOf('s'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NULL').last);
    await tester.pumpAndSettle();
    await _submit(tester);
    expect(
      await _rows(tester, db, 'SELECT id, s, t, u, b FROM d WHERE id = 2'),
      [
        [2, null, null, '', 1],
      ],
    );
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('the date picker writes ISO-8601 UTC text', (tester) async {
    final db = await _openDb(tester, 'picker', [
      'CREATE TABLE e (at DATETIME)',
    ]);
    await _pumpInsert(tester, db, 'e');

    await tester.tap(find.byTooltip('Pick a date and time (UTC) for at'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final text = tester.widget<TextFormField>(fieldOf('at')).controller!.text;
    expect(text, matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:00\.000Z$')));
    await _submit(tester);
    expect(await _rows(tester, db, 'SELECT at FROM e'), [
      [text],
    ]);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('switching tables swaps the form without errors', (tester) async {
    final db = await _openDb(tester, 'switch', [
      'CREATE TABLE t1 (a TEXT)',
      'CREATE TABLE t2 (b TEXT)',
    ]);
    await _pumpInsert(tester, db, 't1');

    await tester.enterText(fieldOf('a'), 'typed');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('t2').last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(fieldOf('a'), findsNothing);
    expect(fieldOf('b'), findsOneWidget);
    expect(find.text('Insert into t2'), findsOneWidget);

    await tester.enterText(fieldOf('b'), 'second');
    await _submit(tester);
    expect(await _rows(tester, db, 'SELECT b FROM t2'), [
      ['second'],
    ]);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
}

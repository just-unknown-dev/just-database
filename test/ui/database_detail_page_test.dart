// Widget tests for DatabaseDetailPage: rowid-based edit and delete, edits
// that only touch changed columns, NULL, and LIMIT/OFFSET paging.
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

Future<void> _pumpPage(
  WidgetTester tester,
  JustDatabase db, {
  String? table,
}) async {
  useLargeWindow(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: DatabaseDetailPage(database: db, initialTable: table),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  late FakePaths paths;
  setUpAll(() async => paths = await FakePaths.install());
  tearDownAll(() => paths.dispose());

  testWidgets(
    'deletes one of two identical rows of a table without a primary key',
    (tester) async {
      final db = await _openDb(tester, 'dup_delete', [
        'CREATE TABLE d (a TEXT, b INTEGER)',
        "INSERT INTO d VALUES ('same', 1), ('same', 1)",
      ]);
      await _pumpPage(tester, db);

      expect(find.byTooltip('Delete row'), findsNWidgets(2));
      await tester.tap(find.byTooltip('Delete row').first);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(await _rows(tester, db, 'SELECT rowid, a, b FROM d'), [
        [2, 'same', 1],
      ]);
      expect(find.text('Row deleted.'), findsOneWidget);
      expect(find.byTooltip('Delete row'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets(
    'edits one of two identical rows by rowid, setting only the changed column',
    (tester) async {
      final db = await _openDb(tester, 'dup_edit', [
        'CREATE TABLE d (a TEXT, b INTEGER)',
        "INSERT INTO d VALUES ('same', 1), ('same', 1)",
      ]);
      await _pumpPage(tester, db);

      await tester.tap(find.byTooltip('Edit row').last);
      await tester.pumpAndSettle();
      expect(find.text('Edit row 2 of d'), findsOneWidget);
      await tester.enterText(fieldOf('b'), '5');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(await _rows(tester, db, 'SELECT rowid, a, b FROM d'), [
        [1, 'same', 1],
        [2, 'same', 5],
      ]);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets("saving an edit keeps untouched '' and padded text exactly", (
    tester,
  ) async {
    final db = await _openDb(tester, 'untouched', [
      'CREATE TABLE p (s TEXT NOT NULL, t TEXT, n INTEGER)',
      "INSERT INTO p VALUES ('', '  padded ', 1)",
    ]);
    await _pumpPage(tester, db);

    await tester.tap(find.byTooltip('Edit row'));
    await tester.pumpAndSettle();
    await tester.enterText(fieldOf('n'), '2');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(
      find.byType(AlertDialog),
      findsNothing,
      reason: 'no "required" error for an untouched empty NOT NULL value',
    );
    expect(await _rows(tester, db, 'SELECT s, t, n FROM p'), [
      ['', '  padded ', 2],
    ]);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('NULL has its own toggle and numbers are validated', (
    tester,
  ) async {
    final db = await _openDb(tester, 'nulls', [
      'CREATE TABLE q (t TEXT, n INTEGER)',
      "INSERT INTO q VALUES ('keep', 3)",
    ]);
    await _pumpPage(tester, db);

    await tester.tap(find.byTooltip('Edit row'));
    await tester.pumpAndSettle();

    // An empty INTEGER is not a number: the dialog says so and saves nothing.
    await tester.enterText(fieldOf('n'), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a whole number, or choose NULL.'), findsOneWidget);
    expect(await _rows(tester, db, 'SELECT t, n FROM q'), [
      ['keep', 3],
    ]);

    // NULL comes from the column's menu, not from an empty field.
    await tester.tap(modeMenuOf('n'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('NULL').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(await _rows(tester, db, 'SELECT t, n FROM q'), [
      ['keep', null],
    ]);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets(
    'rows with BOOLEAN and DATETIME values (no primary key) show as stored and delete',
    (tester) async {
      final db = await _openDb(tester, 'booldate', [
        'CREATE TABLE f (flag BOOLEAN, at DATETIME)',
        "INSERT INTO f VALUES (1, '2026-02-20T10:00:00.000Z')",
      ]);
      await _pumpPage(tester, db);

      expect(find.text('2026-02-20T10:00:00.000Z'), findsOneWidget);
      await tester.tap(find.byTooltip('Delete row'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(await _rows(tester, db, 'SELECT COUNT(*) FROM f'), [
        [0],
      ]);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets(
    'an update that changes no row shows an error instead of closing',
    (tester) async {
      final db = await _openDb(tester, 'gone', [
        'CREATE TABLE g (v TEXT)',
        "INSERT INTO g VALUES ('a')",
      ]);
      await _pumpPage(tester, db);

      await tester.tap(find.byTooltip('Edit row'));
      await tester.pumpAndSettle();
      // Someone else deletes the row while the dialog is open.
      await exec(db, 'DELETE FROM g');
      await tester.enterText(fieldOf('v'), 'b');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        find.textContaining('Expected to update 1 row but 0 changed'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets(
    'pages through a large table with LIMIT/OFFSET and builds only visible rows',
    (tester) async {
      final db = await _openDb(tester, 'big', [
        'CREATE TABLE big (id INTEGER PRIMARY KEY, v TEXT)',
      ]);
      await db.transaction((tx) async {
        for (var i = 1; i <= 1234; i++) {
          await tx.execute('INSERT INTO big (v) VALUES (?)', ['row $i']);
        }
      });
      await _pumpPage(tester, db);

      expect(find.text('1–50 of 1234'), findsOneWidget);
      expect(find.text('row 1'), findsOneWidget);
      // Lazy: far fewer than the 50 rows of the page are built.
      expect(find.byTooltip('Edit row').evaluate().length, lessThan(50));

      await tester.tap(find.byTooltip('Next page'));
      await tester.pumpAndSettle();
      expect(find.text('51–100 of 1234'), findsOneWidget);
      expect(find.text('row 51'), findsOneWidget);
      expect(find.text('row 1'), findsNothing);

      await tester.tap(find.byTooltip('Last page'));
      await tester.pumpAndSettle();
      expect(find.text('1201–1234 of 1234'), findsOneWidget);
      expect(find.text('row 1201'), findsOneWidget);

      // Rows past the first page can be edited (the old page stopped at 500).
      await tester.tap(find.byTooltip('Edit row').first);
      await tester.pumpAndSettle();
      await tester.enterText(fieldOf('v'), 'edited');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(await _rows(tester, db, 'SELECT v FROM big WHERE id = 1201'), [
        ['edited'],
      ]);
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets('deletes the selected rows together', (tester) async {
    final db = await _openDb(tester, 'bulk', [
      'CREATE TABLE b (v TEXT)',
      "INSERT INTO b VALUES ('x'), ('x'), ('y')",
    ]);
    await _pumpPage(tester, db);

    final boxes = find.byType(Checkbox);
    await tester.tap(boxes.at(0));
    await tester.tap(boxes.at(1));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.text('Delete selected'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(await _rows(tester, db, 'SELECT v FROM b'), [
      ['y'],
    ]);
    expect(find.text('Deleted 2 rows.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
}

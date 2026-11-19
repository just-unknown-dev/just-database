// The workbench on a phone, with in-memory databases: the database list,
// the database page (tables, SQL, overview), the object page (data and
// structure), the row sheet and editor, selection, creating a database,
// and growing into the wide layout.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/ui.dart';

import 'ui_test_support.dart';

const _phone = Size(400, 820);

Future<JustDatabase> _people(String prefix) async {
  final db = await JustDatabase.open(uniqueName(prefix), persist: false);
  await exec(
    db,
    'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, age INTEGER)',
  );
  for (final (name, age) in [('Cy', 30), ('Ann', 41), ('Bob', 25)]) {
    await exec(db, 'INSERT INTO people (name, age) VALUES (?, ?)', [name, age]);
  }
  return db;
}

Future<JustDatabaseAdminController> _pump(WidgetTester tester) async {
  useLargeWindow(tester, size: _phone);
  final c = JustDatabaseAdminController(
    rememberSettings: false,
    persistByDefault: false,
  );
  await tester.pumpWidget(
    MaterialApp(home: JustDatabaseAdminScreen(controller: c)),
  );
  await tester.pumpAndSettle();
  return c;
}

Future<void> _finish(
  WidgetTester tester,
  JustDatabaseAdminController c,
  List<JustDatabase> dbs,
) async {
  await tester.pumpWidget(const SizedBox());
  c.dispose();
  for (final db in dbs) {
    await db.close();
  }
}

Future<void> _openPeople(WidgetTester tester, JustDatabase db) async {
  await tester.tap(find.byKey(ValueKey('jdb-db-${db.name}')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('jdb-object-table-people')));
  await tester.pumpAndSettle();
}

void main() {
  late FakePaths paths;
  setUpAll(() async => paths = await FakePaths.install());
  tearDownAll(() => paths.dispose());

  testWidgets('list → database → table; a row opens a sheet; Edit opens a '
      'full-screen editor that saves', (tester) async {
    final db = await _people('phone');
    final c = await _pump(tester);
    expect(find.byKey(const ValueKey('jdb-new-database')), findsOneWidget);
    await _openPeople(tester, db);
    expect(find.byKey(const ValueKey('jdb-tab-data')), findsOneWidget);
    expect(find.byKey(const ValueKey('jdb-tab-structure')), findsOneWidget);
    expect(find.text('Ann'), findsOneWidget);

    await tester.tap(find.text('Ann'));
    await tester.pumpAndSettle();
    expect(find.text('Row 2'), findsOneWidget);
    expect(find.text('41'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('jdb-sheet-edit')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    await tester.enterText(fieldOf('name'), 'Anna');
    await tester.tap(find.byKey(const ValueKey('jdb-row-save')));
    await tester.pumpAndSettle();
    expect(
      (await db.query('SELECT name FROM people WHERE id = 2')).scalar,
      'Anna',
    );
    expect(find.text('Anna'), findsOneWidget);
    await _finish(tester, c, [db]);
  });

  testWidgets('a long press starts selecting; taps add rows; Delete removes '
      'them', (tester) async {
    final db = await _people('select');
    final c = await _pump(tester);
    await _openPeople(tester, db);
    await tester.longPress(find.text('Cy'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.text('Bob'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('jdb-delete-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-confirm')));
    await tester.pumpAndSettle();
    expect((await db.query('SELECT name FROM people')).values, [
      ['Ann'],
    ]);
    await _finish(tester, c, [db]);
  });

  testWidgets('the structure tab has an actions menu; the database page has '
      'SQL and Overview tabs', (tester) async {
    final db = await _people('tabs');
    final c = await _pump(tester);
    await _openPeople(tester, db);
    await tester.tap(find.byKey(const ValueKey('jdb-tab-structure')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Table actions'), findsOneWidget);
    expect(find.byKey(const ValueKey('jdb-column-age')), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('jdb-nav-sql')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jdb-sql')),
      'SELECT name FROM people ORDER BY name LIMIT 1',
    );
    await tester.tap(find.byKey(const ValueKey('jdb-run')));
    await tester.pumpAndSettle();
    expect(find.text('Ann'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('jdb-nav-overview')));
    await tester.pumpAndSettle();
    expect(find.text('Opened by the app'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('jdb-overview-table-people')),
      findsOneWidget,
    );
    await _finish(tester, c, [db]);
  });

  testWidgets('New database creates it full screen and opens its page', (
    tester,
  ) async {
    final c = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('jdb-new-database')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    final name = uniqueName('made');
    await tester.enterText(find.byKey(const ValueKey('jdb-new-name')), name);
    await tester.tap(find.byKey(const ValueKey('jdb-create')));
    await tester.pumpAndSettle();
    final db = JustDatabase.findOpen(name)!;
    expect(db.persist, isFalse);
    expect(find.text('No tables yet'), findsOneWidget);
    expect(find.byKey(const ValueKey('jdb-new-table')), findsOneWidget);
    await _finish(tester, c, [db]);
  });

  testWidgets('pages pop when the window grows wide; the wide layout shows '
      'the same table', (tester) async {
    final db = await _people('grow');
    final c = await _pump(tester);
    await _openPeople(tester, db);
    expect(find.byKey(const ValueKey('jdb-tab-data')), findsOneWidget);

    tester.view.physicalSize = const Size(1400, 900);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('jdb-tab-data')), findsNothing);
    expect(find.byKey(const ValueKey('jdb-pane-tab-data')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('jdb-object-table-people')),
      findsOneWidget,
    );
    expect(c.selection?.object, 'people');
    await _finish(tester, c, [db]);
  });
}

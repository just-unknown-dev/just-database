// The workbench on a wide screen, with in-memory databases: the sidebar,
// the data pane (sort, filter, edit in place, side-panel editor, delete,
// live reload), structure editing, the create-table designer, the SQL
// console, export/import and read-only mode.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/ui.dart';

import 'ui_test_support.dart';

Future<JustDatabase> _people(String prefix) async {
  final db = await JustDatabase.open(uniqueName(prefix), persist: false);
  await exec(
    db,
    'CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, '
    'age INTEGER, bio TEXT)',
  );
  for (final (name, age) in [('Cy', 30), ('Ann', 41), ('Bob', 25)]) {
    await exec(db, 'INSERT INTO people (name, age) VALUES (?, ?)', [name, age]);
  }
  return db;
}

Future<JustDatabaseAdminController> _pump(
  WidgetTester tester, {
  bool readOnly = false,
}) async {
  useLargeWindow(tester, size: const Size(1400, 900));
  final c = testController(readOnly: readOnly, persistByDefault: false);
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

Future<void> _openTable(WidgetTester tester, JustDatabase db, String t) async {
  await tester.tap(find.byKey(ValueKey('jdb-db-${db.name}')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('jdb-object-table-$t')));
  await tester.pumpAndSettle();
}

/// The text of the grid cells in column [column], top to bottom.
List<String> _column(WidgetTester tester, int column, int rows) => [
  for (var r = 0; r < rows; r++)
    tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(ValueKey('jdb-cell-$r-$column')),
            matching: find.byType(Text),
          ),
        )
        .data!,
];

Future<void> _runSql(WidgetTester tester, String sql) async {
  await tester.enterText(find.byKey(const ValueKey('jdb-sql')), sql);
  await tester.tap(find.byKey(const ValueKey('jdb-run')));
  await tester.pumpAndSettle();
}

void main() {
  late FakePaths paths;
  setUpAll(() async => paths = await FakePaths.install());
  tearDownAll(() => paths.dispose());

  testWidgets('the sidebar lists the app databases; a database shows its '
      'overview and tree; a table shows its rows', (tester) async {
    final db = await _people('side');
    final c = await _pump(tester);
    expect(find.byKey(ValueKey('jdb-db-${db.name}')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('jdb-db-${db.name}')));
    await tester.pumpAndSettle();
    expect(find.text('Opened by the app'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('jdb-overview-table-people')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('jdb-object-table-people')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('jdb-object-table-people')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('jdb-pane-tab-data')), findsOneWidget);
    expect(_column(tester, 1, 3), ['Cy', 'Ann', 'Bob']);
    expect(find.text('3 rows'), findsOneWidget);
    await _finish(tester, c, [db]);
  });

  testWidgets('headers sort; search and WHERE filter; a bad WHERE says why', (
    tester,
  ) async {
    final db = await _people('sort');
    final c = await _pump(tester);
    await _openTable(tester, db, 'people');

    await tester.tap(find.byKey(const ValueKey('jdb-header-name')));
    await tester.pumpAndSettle();
    expect(_column(tester, 1, 3), ['Ann', 'Bob', 'Cy']);
    await tester.tap(find.byKey(const ValueKey('jdb-header-name')));
    await tester.pumpAndSettle();
    expect(_column(tester, 1, 3), ['Cy', 'Bob', 'Ann']);
    await tester.tap(find.byKey(const ValueKey('jdb-header-name')));
    await tester.pumpAndSettle();
    expect(_column(tester, 1, 3), ['Cy', 'Ann', 'Bob']);

    await tester.enterText(find.byKey(const ValueKey('jdb-filter')), 'n');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('1 matching row'), findsOneWidget);
    expect(_column(tester, 1, 1), ['Ann']);

    await tester.tap(find.byKey(const ValueKey('jdb-filter-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckedPopupMenuItem<bool>).last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jdb-filter')),
      'age > 28',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('2 matching rows'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('jdb-filter')),
      'nope = 1',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('jdb-data-error')), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('jdb-filter')),
      '1); DELETE FROM people; --',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(db.rowCount('people'), 3, reason: 'a filter never writes');
    await _finish(tester, c, [db]);
  });

  testWidgets('a cell is edited in place; Escape cancels; a bad number is '
      'refused', (tester) async {
    final db = await _people('edit');
    final c = await _pump(tester);
    await _openTable(tester, db, 'people');

    final cell = find.byKey(const ValueKey('jdb-cell-1-1'));
    await tester.tap(cell);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('jdb-cell-editor')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('jdb-cell-editor')),
      "Ann O'Hara",
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(
      (await db.query('SELECT name FROM people WHERE id = 2')).scalar,
      "Ann O'Hara",
    );

    final age = find.byKey(const ValueKey('jdb-cell-0-2'));
    await tester.tap(age);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(age);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jdb-cell-editor')),
      'old',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a whole number'), findsOneWidget);
    expect((await db.query('SELECT age FROM people WHERE id = 1')).scalar, 30);
    await _finish(tester, c, [db]);
  });

  testWidgets('new rows go through the side panel; selected rows are '
      'deleted together; app writes show up', (tester) async {
    final db = await _people('rows');
    final c = await _pump(tester);
    await _openTable(tester, db, 'people');

    await tester.tap(find.byKey(const ValueKey('jdb-new-row')));
    await tester.pumpAndSettle();
    await tester.enterText(fieldOf('name'), 'Dee');
    await tester.tap(find.byKey(const ValueKey('jdb-row-save')));
    await tester.pumpAndSettle();
    expect(db.rowCount('people'), 4);
    expect(find.text('4 rows'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Select row 1'));
    await tester.tap(find.bySemanticsLabel('Select row 3'));
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('jdb-delete-selected')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-confirm')));
    await tester.pumpAndSettle();
    expect((await db.query('SELECT name FROM people ORDER BY id')).values, [
      ['Ann'],
      ['Dee'],
    ]);

    await exec(db, "INSERT INTO people (name) VALUES ('From the app')");
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(find.text('From the app'), findsOneWidget);
    await _finish(tester, c, [db]);
  });

  testWidgets('a right click opens the cell menu; View value shows JSON', (
    tester,
  ) async {
    final db = await _people('menu');
    await exec(
      db,
      '''UPDATE people SET bio = '{"likes":["tea"]}' WHERE id = 1''',
    );
    final c = await _pump(tester);
    await _openTable(tester, db, 'people');
    await tester.tap(
      find.byKey(const ValueKey('jdb-cell-0-3')),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Set to NULL'), findsOneWidget);
    await tester.tap(find.text('View value'));
    await tester.pumpAndSettle();
    final shown = tester.widget<SelectableText>(
      find.byKey(const ValueKey('jdb-inspector-value')),
    );
    expect(shown.data, contains('"likes": ['));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await _finish(tester, c, [db]);
  });

  testWidgets('structure: add a column, create an index, rename and drop the '
      'table', (tester) async {
    final db = await _people('struct');
    final c = await _pump(tester);
    await _openTable(tester, db, 'people');
    await tester.tap(find.byKey(const ValueKey('jdb-pane-tab-structure')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('jdb-column-name')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('jdb-action-addColumn')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jdb-col-name-0')),
      'email',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-add-column')));
    await tester.pumpAndSettle();
    expect(db.getTableSchema('people')!.columnNames, contains('email'));

    await tester.tap(find.byKey(const ValueKey('jdb-action-createIndex')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-index-col-age')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-create-index')));
    await tester.pumpAndSettle();
    expect(db.indexNamesForTable('people'), contains('idx_people_age'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('jdb-index-idx_people_age')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey('jdb-action-rename')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('jdb-prompt')), 'persons');
    await tester.tap(find.byKey(const ValueKey('jdb-prompt-ok')));
    await tester.pumpAndSettle();
    expect(db.tableNames, ['persons']);
    expect(
      find.byKey(const ValueKey('jdb-object-table-persons')),
      findsOneWidget,
    );
    expect(c.selection?.object, 'persons');

    await tester.tap(find.byKey(const ValueKey('jdb-action-drop')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-confirm')));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(db.tableNames, isEmpty);
    expect(c.selection?.kind, isNull, reason: 'back to the database');
    await _finish(tester, c, [db]);
  });

  testWidgets('the designer creates a table with a key and a reference', (
    tester,
  ) async {
    final db = await _people('design');
    final c = await _pump(tester);
    await tester.tap(find.byKey(ValueKey('jdb-db-${db.name}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-tree-add-tables')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jdb-table-name')),
      'notes',
    );
    await tester.enterText(
      find.byKey(const ValueKey('jdb-col-name-1')),
      'body',
    );
    await tester.pumpAndSettle();
    final preview = find.textContaining('id INTEGER PRIMARY KEY');
    await tester.scrollUntilVisible(
      preview,
      200,
      scrollable: find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(preview, findsWidgets);
    await tester.tap(find.byKey(const ValueKey('jdb-create-table')));
    await tester.pumpAndSettle();
    final schema = db.getTableSchema('notes')!;
    expect(schema.columnNames, ['id', 'body']);
    expect(schema.rowidAlias, 0);
    expect(c.selection?.object, 'notes');

    await tester.tap(find.byKey(const ValueKey('jdb-tree-add-tables')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jdb-table-name')),
      'notes',
    );
    await tester.tap(find.byKey(const ValueKey('jdb-create-table')));
    await tester.pumpAndSettle();
    expect(find.textContaining('A table has that name'), findsWidgets);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await _finish(tester, c, [db]);
  });

  testWidgets('the SQL console runs scripts, shows each result, points at '
      'errors, binds parameters and completes names', (tester) async {
    final db = await _people('sql');
    final c = await _pump(tester);
    await tester.tap(find.byKey(ValueKey('jdb-db-${db.name}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-tree-sql')));
    await tester.pumpAndSettle();

    await _runSql(
      tester,
      'CREATE TABLE x (a); INSERT INTO x VALUES (7); SELECT a FROM x',
    );
    expect(find.byKey(const ValueKey('jdb-outcome-2')), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('jdb-outcome-1')));
    await tester.pumpAndSettle();
    expect(find.text('1 row changed'), findsOneWidget);

    await _runSql(tester, 'SELECT *\nFROM nowhere');
    expect(find.byKey(const ValueKey('jdb-query-error')), findsOneWidget);
    expect(find.textContaining('no such table'), findsOneWidget);

    await _runSql(tester, 'SELECT 1;\nSELECT FROM;');
    expect(find.textContaining('line 2'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('jdb-sql')),
      'SELECT :n + 1 AS r',
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('jdb-param-:n')), '41');
    await tester.tap(find.byKey(const ValueKey('jdb-run')));
    await tester.pumpAndSettle();
    expect(find.text('42'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('jdb-sql')),
      'SELECT * FROM peo',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-completion-people')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('jdb-sql')))
          .controller!
          .text,
      'SELECT * FROM people',
    );

    await tester.tap(find.byKey(const ValueKey('jdb-history')));
    await tester.pumpAndSettle();
    expect(c.history.first.sql, 'SELECT :n + 1 AS r');
    await tester.tap(find.byKey(const ValueKey('jdb-history-0')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('jdb-sql')))
          .controller!
          .text,
      'SELECT :n + 1 AS r',
    );
    await _finish(tester, c, [db]);
  });

  testWidgets('export copies SQL; a pasted export becomes a new database', (
    tester,
  ) async {
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final db = await _people('export');
    final c = await _pump(tester);
    await tester.tap(find.byKey(ValueKey('jdb-db-${db.name}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-db-action-export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-export-copy')));
    await tester.pumpAndSettle();
    expect(clipboard, contains('CREATE TABLE'));
    expect(clipboard, contains("'Bob'"));
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('jdb-sidebar-import')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('jdb-import-text')),
      clipboard!,
    );
    final copy = uniqueName('pasted');
    await tester.enterText(find.byKey(const ValueKey('jdb-import-name')), copy);
    await tester.tap(find.byKey(const ValueKey('jdb-import')));
    await tester.pumpAndSettle();
    final imported = JustDatabase.findOpen(copy)!;
    expect(imported.rowCount('people'), 3);
    expect(c.selection?.database, copy);
    await _finish(tester, c, [db]);
  });

  testWidgets('read-only: nothing that writes is offered, and the console '
      'only reads', (tester) async {
    final db = await _people('ro');
    final c = await _pump(tester, readOnly: true);
    expect(find.text('Read-only'), findsWidgets);
    expect(find.byKey(const ValueKey('jdb-new-database')), findsNothing);
    await _openTable(tester, db, 'people');
    expect(find.byKey(const ValueKey('jdb-new-row')), findsNothing);
    expect(find.bySemanticsLabel('Select row 1'), findsNothing);
    final cell = find.byKey(const ValueKey('jdb-cell-0-1'));
    await tester.tap(cell);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(cell);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('jdb-cell-editor')), findsNothing);
    expect(find.byKey(const ValueKey('jdb-inspector-value')), findsOneWidget);
    expect(find.byKey(const ValueKey('jdb-inspector-edit')), findsNothing);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('jdb-pane-tab-sql')));
    await tester.pumpAndSettle();
    await _runSql(tester, 'DELETE FROM people');
    expect(find.textContaining('read-only'), findsWidgets);
    expect(db.rowCount('people'), 3);
    await _runSql(tester, 'SELECT COUNT(*) AS n FROM people');
    expect(_column(tester, 0, 1), ['3']);
    await _finish(tester, c, [db]);
  });

  testWidgets('settings change the page size and defaults', (tester) async {
    final c = await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('jdb-settings')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('jdb-setting-page-size')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('250').last);
    await tester.pumpAndSettle();
    expect(c.pageSize, 250);
    await tester.tap(find.byKey(const ValueKey('jdb-setting-mode-writeFast')));
    await tester.pumpAndSettle();
    expect(c.defaultMode, DatabaseMode.writeFast);
    await tester.tap(find.byKey(const ValueKey('jdb-setting-persist')));
    await tester.pumpAndSettle();
    expect(c.persistByDefault, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await _finish(tester, c, const []);
  });

  testWidgets('light and dark: dark by default; the app bar toggles it; '
      'Settings picks dark, light or the device; open pages change with it', (
    tester,
  ) async {
    Brightness brightnessAt(Finder f) =>
        Theme.of(tester.element(f.first)).brightness;
    final toggle = find.byKey(const ValueKey('jdb-theme-toggle'));
    final settingsTitle = find.text('Appearance');

    final c = await _pump(tester);
    expect(c.themeMode, ThemeMode.dark);
    expect(brightnessAt(toggle), Brightness.dark);
    expect(find.byTooltip('Light mode'), findsOneWidget);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(c.themeMode, ThemeMode.light);
    expect(brightnessAt(toggle), Brightness.light);
    expect(find.byTooltip('Dark mode'), findsOneWidget);

    // A pushed page has the screen's appearance and follows its changes.
    await tester.tap(find.byKey(const ValueKey('jdb-settings')));
    await tester.pumpAndSettle();
    expect(brightnessAt(settingsTitle), Brightness.light);
    await tester.tap(find.byKey(const ValueKey('jdb-setting-theme-dark')));
    await tester.pumpAndSettle();
    expect(c.themeMode, ThemeMode.dark);
    expect(brightnessAt(settingsTitle), Brightness.dark);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await tester.tap(find.byKey(const ValueKey('jdb-setting-theme-device')));
    await tester.pumpAndSettle();
    expect(c.themeMode, ThemeMode.system);
    expect(brightnessAt(settingsTitle), Brightness.light);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(brightnessAt(settingsTitle), Brightness.dark);

    await tester.tap(find.byKey(const ValueKey('jdb-setting-theme-light')));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(brightnessAt(toggle), Brightness.light);
    await _finish(tester, c, const []);
  });

  testWidgets("the workbench's own colours are black and grey with the "
      "logo's coral as the accent, not the app's", (tester) async {
    const coral = Color(0xFFF5746F);
    void expectGrey(Color c, String role) {
      expect(
        (c.r - c.g).abs() + (c.g - c.b).abs(),
        lessThan(0.01),
        reason: '$role is $c',
      );
    }

    void expectNeutral(ColorScheme cs) {
      expectGrey(cs.surface, 'surface');
      expectGrey(cs.surfaceContainerLow, 'surfaceContainerLow');
      expectGrey(cs.surfaceContainerHighest, 'surfaceContainerHighest');
      expectGrey(cs.onSurface, 'onSurface');
      expectGrey(cs.outlineVariant, 'outlineVariant');
      expectGrey(cs.secondaryContainer, 'secondaryContainer');
    }

    final c = await _pump(tester);
    final toggle = find.byKey(const ValueKey('jdb-theme-toggle'));
    ColorScheme coloursAt() => Theme.of(tester.element(toggle)).colorScheme;
    final app = Theme.of(tester.element(find.byType(Navigator).first));
    expect(app.colorScheme.primary, isNot(coral));

    expect(coloursAt().brightness, Brightness.dark);
    expect(coloursAt().primary, coral);
    expect(coloursAt().primaryContainer, coral);
    expect(coloursAt().surface.computeLuminance(), lessThan(0.01));
    expectNeutral(coloursAt());

    // On light surfaces the coral is the container and a deeper shade of
    // it the primary, which text and icons can be drawn in.
    c.setThemeMode(ThemeMode.light);
    await tester.pumpAndSettle();
    final light = coloursAt();
    expect(light.brightness, Brightness.light);
    expect(light.primaryContainer, coral);
    expectNeutral(light);
    expect(
      HSVColor.fromColor(light.primary).hue,
      closeTo(HSVColor.fromColor(coral).hue, 5),
    );
    expect(
      light.primary.computeLuminance(),
      lessThan(coral.computeLuminance() / 2),
    );
    await _finish(tester, c, const []);
  });

  testWidgets('a given theme is kept as it is, and made light from its '
      'colours when asked', (tester) async {
    useLargeWindow(tester, size: const Size(1400, 900));
    final c = testController(persistByDefault: false);
    final given = ThemeData(
      colorSchemeSeed: Colors.teal,
      brightness: Brightness.dark,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: JustDatabaseAdminScreen(controller: c, theme: given),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('jdb-theme-toggle'));
    ThemeData themeAt() => Theme.of(tester.element(toggle));
    expect(themeAt().colorScheme.primary, given.colorScheme.primary);

    c.setThemeMode(ThemeMode.light);
    await tester.pumpAndSettle();
    final light = themeAt();
    expect(light.brightness, Brightness.light);
    expect(
      light.colorScheme.primary,
      ColorScheme.fromSeed(seedColor: given.colorScheme.primary).primary,
    );
    c.setThemeMode(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(themeAt().colorScheme.primary, given.colorScheme.primary);
    await _finish(tester, c, const []);
  });
}

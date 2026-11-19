// Admin UI tests with saved databases (real files in a temporary folder):
// opening a saved database, a failed selection, deleting files, and the
// provider's checks.
//
// Widget tests do all database work in the test's fake-async zone through
// `drive` (see ui_test_support.dart), which lets the real file I/O run.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/ui.dart';

import 'ui_test_support.dart';

/// Creates a saved database [name] with a table of [rows] and closes it.
/// (No `expect` here: it also runs inside `drive`, beside a pump.)
Future<void> _saveDb(String name, List<String> rows) async {
  final db = await JustDatabase.open(name);
  (await db.execute('CREATE TABLE notes (body TEXT)')).orThrow();
  for (final r in rows) {
    (await db.execute('INSERT INTO notes VALUES (?)', [r])).orThrow();
  }
  await db.close();
}

Future<void> _pumpScreen(
  WidgetTester tester,
  DatabaseProvider provider,
  Finder ready,
) async {
  useLargeWindow(tester);
  await tester.pumpWidget(
    MaterialApp(home: JustDatabaseAdminScreen(provider: provider)),
  );
  await pumpUntil(
    tester,
    () => ready.evaluate().isNotEmpty && !provider.isLoading,
    reason: 'the databases are listed',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePaths paths;
  setUpAll(() async => paths = await FakePaths.install());
  tearDownAll(() => paths.dispose());

  group('DatabaseProvider', () {
    test('selecting an unknown name fails and creates nothing', () async {
      final provider = DatabaseProvider();
      final name = uniqueName('unknown');
      expect(await provider.selectDatabase(name), isFalse);
      expect(provider.lastError, contains('There is no database named'));
      expect(provider.currentDatabase, isNull);
      expect(JustDatabase.findOpen(name), isNull);
      expect(paths.file(name).existsSync(), isFalse);
      await provider.dispose();
    });

    test('an existing name cannot be created again', () async {
      final name = uniqueName('exists');
      await _saveDb(name, ['a']);
      final provider = DatabaseProvider();
      expect(await provider.createDatabase(name), isFalse);
      expect(provider.lastError, contains('already exists'));
      await provider.dispose();
      await DatabaseManager.deleteDatabase(name);
    });

    test(
      "dispose closes what the provider opened, never the app's databases",
      () async {
        final saved = uniqueName('held');
        await _saveDb(saved, ['x']);
        final app = await JustDatabase.open(uniqueName('apps'), persist: false);
        final provider = DatabaseProvider();
        expect(await provider.selectDatabase(saved), isTrue);
        final held = provider.currentDatabase!;
        expect(held.persist, isTrue);
        expect(await provider.selectDatabase(app.name), isTrue);
        expect(provider.currentDatabase, same(app));
        await provider.dispose();
        expect(held.isOpen, isFalse);
        expect(app.isOpen, isTrue);
        await app.close();
        await DatabaseManager.deleteDatabase(saved);
      },
    );
  });

  testWidgets('a saved database opens from storage with its data, even with '
      '"save new databases" off', (tester) async {
    final name = uniqueName('saved');
    await drive(tester, () => _saveDb(name, ['first note', 'second note']));
    final provider = DatabaseProvider(persistByDefault: false);
    final card = find.byKey(ValueKey('jdb-db-$name'));
    await _pumpScreen(tester, provider, card);
    expect(
      find.descendant(of: card, matching: find.text('Closed')),
      findsOneWidget,
    );

    await tester.tap(card);
    await pumpUntil(
      tester,
      () => provider.currentDatabase != null && !provider.isLoading,
    );
    final db = provider.currentDatabase!;
    expect(db.name, name);
    expect(
      db.persist,
      isTrue,
      reason: 'a saved database is never opened in memory',
    );
    expect(db.tableNames, ['notes']);
    expect(db.rowCount('notes'), 2);

    await tester.tap(find.byTooltip('Actions for $name'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browse data'));
    await pumpUntil(
      tester,
      () => find.text('second note').evaluate().isNotEmpty,
    );
    expect(find.byType(DatabaseDetailPage), findsOneWidget);
    expect(find.text('first note'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await drive(tester, provider.dispose);
    expect(db.isOpen, isFalse);
    await drive(tester, () => DatabaseManager.deleteDatabase(name));
  });

  testWidgets(
    'a database that fails to open keeps the current one and opens no page',
    (tester) async {
      final good = uniqueName('good');
      final broken = uniqueName('broken');
      final app = await drive(
        tester,
        () => JustDatabase.open(good, persist: false),
      );
      await drive(
        tester,
        () async => (await app.execute('CREATE TABLE t (a TEXT)')).orThrow(),
      );
      paths.file(broken).writeAsStringSync('this is not a database');

      final provider = DatabaseProvider();
      await _pumpScreen(
        tester,
        provider,
        find.byKey(ValueKey('jdb-db-$broken')),
      );
      await tester.tap(find.byKey(ValueKey('jdb-db-$good')));
      await pumpUntil(
        tester,
        () => provider.currentDatabase != null && !provider.isLoading,
      );
      expect(provider.currentDatabase, same(app));

      for (final action in ['Browse data', 'Insert row', 'Benchmark']) {
        await tester.tap(find.byTooltip('Actions for $broken'));
        await tester.pumpAndSettle();
        await tester.tap(find.text(action));
        await pumpUntil(
          tester,
          () =>
              find.byType(SnackBar).evaluate().isNotEmpty &&
              !provider.isLoading,
          reason: '$action reports the failure',
        );
        expect(find.textContaining('Could not open "$broken"'), findsOneWidget);
        expect(find.byType(DatabaseDetailPage), findsNothing);
        expect(find.byType(InsertPage), findsNothing);
        expect(find.byType(BenchmarkPage), findsNothing);
        expect(
          provider.currentDatabase,
          same(app),
          reason: 'still on the database that opened',
        );
        ScaffoldMessenger.of(
          tester.element(find.byType(DatabasesTab)),
        ).removeCurrentSnackBar();
        await tester.pumpAndSettle();
      }
      expect(
        paths.file(broken).readAsStringSync(),
        'this is not a database',
        reason: 'left untouched',
      );

      await tester.pumpWidget(const SizedBox());
      await drive(tester, provider.dispose);
      await drive(tester, app.close);
      paths.file(broken).deleteSync();
    },
  );

  testWidgets(
    'deleting a saved database deletes its file; delete all removes the rest',
    (tester) async {
      final one = uniqueName('del_one');
      final two = uniqueName('del_two');
      await drive(tester, () => _saveDb(one, ['x']));
      await drive(tester, () => _saveDb(two, ['y']));
      final memory = await drive(
        tester,
        () => JustDatabase.open(uniqueName('del_mem'), persist: false),
      );
      expect(paths.file(one).existsSync(), isTrue);

      final provider = DatabaseProvider();
      await _pumpScreen(tester, provider, find.byKey(ValueKey('jdb-db-$two')));

      await tester.tap(find.byTooltip('Actions for $one'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await pumpUntil(
        tester,
        () => find.text('Deleted "$one".').evaluate().isNotEmpty,
      );
      expect(paths.file(one).existsSync(), isFalse);
      expect(find.byKey(ValueKey('jdb-db-$one')), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.byType(TabBar),
          matching: find.text('Settings'),
        ),
      );
      await tester.pumpAndSettle();
      final list = find
          .descendant(
            of: find.byType(SettingsTab),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('jdb-clear-all')),
        200,
        scrollable: list,
      );
      await tester.tap(find.byKey(const ValueKey('jdb-clear-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete all'));
      await pumpUntil(
        tester,
        () => find.text('Deleted every database.').evaluate().isNotEmpty,
      );

      expect(paths.file(two).existsSync(), isFalse);
      expect(memory.isOpen, isFalse);
      expect(provider.databases, isEmpty);
      final left = Directory(
        paths.databases,
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.jdb'));
      expect(left, isEmpty);

      await tester.pumpWidget(const SizedBox());
      await drive(tester, provider.dispose);
    },
  );
}

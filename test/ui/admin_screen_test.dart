// Widget tests for JustDatabaseAdminScreen with in-memory databases: the
// app's own instances, navigation, the Query tab, theming, new names and
// readable text.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/ui.dart';

import 'ui_test_support.dart';

/// Opens an in-memory database the way an app does. Database work stays in
/// the test's fake-async zone (see `drive` in ui_test_support.dart); tests
/// close what they open at the end of their body.
Future<JustDatabase> _appDb(
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

Future<Object?> _scalar(
  WidgetTester tester,
  JustDatabase db,
  String sql,
) async {
  final r = await db.query(sql);
  expect(r.success, isTrue, reason: r.errorMessage);
  return r.scalar;
}

/// Unmounts the screen, then disposes [provider] and closes [dbs].
Future<void> _finish(
  WidgetTester tester,
  DatabaseProvider? provider, [
  List<JustDatabase> dbs = const [],
]) async {
  await tester.pumpWidget(const SizedBox());
  await provider?.dispose();
  for (final db in dbs) {
    await db.close();
  }
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  DatabaseProvider? provider,
  ThemeData? appTheme,
  ThemeData? screenTheme,
}) async {
  useLargeWindow(tester);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme,
      home: JustDatabaseAdminScreen(provider: provider, theme: screenTheme),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openTab(WidgetTester tester, String tab) async {
  await tester.tap(
    find.descendant(of: find.byType(TabBar), matching: find.text(tab)),
  );
  await tester.pumpAndSettle();
}

Future<void> _runSql(WidgetTester tester, String sql) async {
  await tester.enterText(find.byKey(const ValueKey('jdb-sql')), sql);
  await tester.tap(find.byKey(const ValueKey('jdb-run')));
  await tester.pumpAndSettle();
}

void main() {
  late FakePaths paths;
  setUpAll(() async => paths = await FakePaths.install());
  tearDownAll(() => paths.dispose());

  testWidgets(
    'as home, the screen has no back button that could pop the only route',
    (tester) async {
      await _pumpScreen(tester);
      expect(find.byType(BackButton), findsNothing);
      expect(find.byIcon(Icons.arrow_back_ios_outlined), findsNothing);
      expect(find.byType(JustDatabaseAdminScreen), findsOneWidget);
    },
  );

  testWidgets('when pushed, the back button returns to the page below', (
    tester,
  ) async {
    useLargeWindow(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const JustDatabaseAdminScreen(),
                  ),
                ),
                child: const Text('open admin'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open admin'));
    await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('open admin'), findsOneWidget);
    expect(find.byType(JustDatabaseAdminScreen), findsNothing);
  });

  testWidgets(
    'shows a database the app opened as open and uses that very instance',
    (tester) async {
      final db = await _appDb(tester, 'app_owned', [
        'CREATE TABLE t (a TEXT)',
        "INSERT INTO t VALUES ('from app')",
      ]);
      final provider = DatabaseProvider();
      await _pumpScreen(tester, provider: provider);

      final card = find.byKey(ValueKey('jdb-db-${db.name}'));
      expect(card, findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.text('Open')),
        findsOneWidget,
      );

      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(provider.currentDatabase, same(db));

      await _openTab(tester, 'Query');
      await _runSql(tester, "INSERT INTO t VALUES ('from admin')");
      expect(await _scalar(tester, db, 'SELECT COUNT(*) FROM t'), 2);
      expect(
        JustDatabase.openDatabases.where((d) => d.name == db.name),
        hasLength(1),
        reason: 'the admin screen must not open a second instance',
      );
      await _finish(tester, provider, [db]);
    },
  );

  testWidgets(
    'the Query tab reports affected rows, runs scripts and reports the failing statement',
    (tester) async {
      final db = await _appDb(tester, 'query_tab', ['CREATE TABLE t (a TEXT)']);
      final provider = DatabaseProvider();
      await _pumpScreen(tester, provider: provider);
      await tester.tap(find.byKey(ValueKey('jdb-db-${db.name}')));
      await tester.pumpAndSettle();
      await _openTab(tester, 'Query');

      await _runSql(tester, "INSERT INTO t VALUES ('x'), ('y')");
      expect(find.text('2 row(s) affected.'), findsOneWidget);
      expect(find.textContaining('Last inserted rowid: 2'), findsOneWidget);

      await _runSql(
        tester,
        "-- a comment first\nSELECT * FROM t WHERE a = 'x'",
      );
      expect(find.text('1 row'), findsOneWidget);

      await _runSql(
        tester,
        "UPDATE t SET a = 'z' WHERE a = 'y'; SELECT a FROM t ORDER BY a",
      );
      expect(find.textContaining('Ran 2 statements'), findsOneWidget);
      expect(find.text('z'), findsOneWidget);

      await _runSql(
        tester,
        "INSERT INTO t VALUES ('w'); INSERT INTO missing VALUES (1)",
      );
      expect(find.byKey(const ValueKey('jdb-query-error')), findsOneWidget);
      expect(find.textContaining('Statement 2 failed'), findsOneWidget);
      expect(await _scalar(tester, db, 'SELECT COUNT(*) FROM t'), 3);
      await _finish(tester, provider, [db]);
    },
  );

  testWidgets('query results are paged and only visible rows are built', (
    tester,
  ) async {
    final db = await _appDb(tester, 'paged', [
      'CREATE TABLE big (id INTEGER PRIMARY KEY, v TEXT)',
    ]);
    await db.transaction((tx) async {
      for (var i = 1; i <= 3000; i++) {
        await tx.execute('INSERT INTO big (v) VALUES (?)', ['v$i']);
      }
    });
    final provider = DatabaseProvider();
    await _pumpScreen(tester, provider: provider);
    await tester.tap(find.byKey(ValueKey('jdb-db-${db.name}')));
    await tester.pumpAndSettle();
    await _openTab(tester, 'Query');

    await _runSql(tester, 'SELECT * FROM big');
    expect(find.text('3000 rows'), findsOneWidget);
    expect(find.text('1–100 of 3000'), findsOneWidget);
    expect(find.text('v1'), findsOneWidget);
    // Lazy: a few dozen cells at most, not 6000.
    expect(
      find.textContaining(RegExp(r'^v\d+$')).evaluate().length,
      lessThan(100),
    );

    await tester.tap(find.byTooltip('Next page'));
    await tester.pumpAndSettle();
    expect(find.text('101–200 of 3000'), findsOneWidget);
    expect(find.text('v101'), findsOneWidget);
    expect(find.text('v1'), findsNothing);
    await _finish(tester, provider, [db]);
  });

  testWidgets('pages opened from a themed screen keep its theme', (
    tester,
  ) async {
    final db = await _appDb(tester, 'themed', ['CREATE TABLE t (a TEXT)']);
    final screenTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.red),
    );
    final appTheme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
    );
    final provider = DatabaseProvider();
    await _pumpScreen(
      tester,
      provider: provider,
      appTheme: appTheme,
      screenTheme: screenTheme,
    );

    final screenCs = Theme.of(tester.element(find.byType(TabBar))).colorScheme;
    expect(screenCs.primary, screenTheme.colorScheme.primary);

    await tester.tap(find.byTooltip('Actions for ${db.name}'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Browse data'));
    await tester.pumpAndSettle();

    expect(find.byType(DatabaseDetailPage), findsOneWidget);
    final pageCs = Theme.of(
      tester.element(find.byType(DatabaseDetailPage)),
    ).colorScheme;
    expect(pageCs.primary, screenTheme.colorScheme.primary);
    expect(pageCs.primary, isNot(appTheme.colorScheme.primary));
    await _finish(tester, provider, [db]);
  });

  testWidgets(
    'new database names are validated, and an existing name is refused',
    (tester) async {
      final existing = await _appDb(tester, 'taken', const []);
      final provider = DatabaseProvider(persistByDefault: false);
      await _pumpScreen(tester, provider: provider);

      await tester.tap(find.text('New database'));
      await tester.pumpAndSettle();
      final nameField = find.byKey(const ValueKey('jdb-new-name'));

      Future<void> tryName(String name) async {
        await tester.enterText(nameField, name);
        await tester.tap(find.widgetWithText(FilledButton, 'Create'));
        await tester.pumpAndSettle();
      }

      await tryName('../x');
      expect(
        find.text('Use only letters, digits, "_", "." and "-".'),
        findsOneWidget,
      );
      await tryName('.hidden');
      expect(
        find.text('The name must not start with "." or "-".'),
        findsOneWidget,
      );
      await tryName('a..b');
      expect(find.text('The name must not contain "..".'), findsOneWidget);
      await tryName(existing.name);
      expect(
        find.text('A database named "${existing.name}" already exists.'),
        findsOneWidget,
      );
      expect(
        find.byType(AlertDialog),
        findsOneWidget,
        reason: 'the dialog stays open',
      );

      final fresh = uniqueName('fresh');
      await tryName(fresh);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Created "$fresh".'), findsOneWidget);
      final created = JustDatabase.findOpen(fresh);
      expect(created, isNotNull);
      expect(created!.persist, isFalse);
      expect(provider.currentDatabase, same(created));

      // The provider checks names too.
      expect(provider.checkNewDatabaseName('CON'), contains('reserved'));
      expect(
        provider.checkNewDatabaseName('a' * 129),
        'Use at most 128 characters.',
      );
      expect(provider.checkNewDatabaseName('ok_name-1.2'), isNull);
      expect(await provider.createDatabase('bad/name'), isFalse);
      expect(provider.lastError, contains('Invalid database name'));
      await _finish(tester, provider, [existing]);
      expect(
        created.isOpen,
        isFalse,
        reason: 'dispose closes what the provider opened',
      );
    },
  );

  testWidgets('deleting a database from its menu closes it and says so', (
    tester,
  ) async {
    final db = await JustDatabase.open(uniqueName('doomed'), persist: false);
    final provider = DatabaseProvider();
    await _pumpScreen(tester, provider: provider);

    await tester.tap(find.byTooltip('Actions for ${db.name}'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('it will be closed for everyone'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('Deleted "${db.name}".'), findsOneWidget);
    expect(db.isOpen, isFalse);
    expect(find.byKey(ValueKey('jdb-db-${db.name}')), findsNothing);
    await _finish(tester, provider);
  });

  testWidgets(
    'Settings shows the real version, repository and encryption scheme',
    (tester) async {
      await _pumpScreen(tester);
      await _openTab(tester, 'Settings');

      final list = find
          .descendant(
            of: find.byType(SettingsTab),
            matching: find.byType(Scrollable),
          )
          .first;
      final encryption = find.textContaining(
        'PBKDF2-HMAC-SHA256 (600 000 iterations',
      );
      await tester.scrollUntilVisible(encryption, 300, scrollable: list);
      expect(encryption, findsOneWidget);
      expect(find.textContaining('12-byte random nonce'), findsOneWidget);
      expect(find.textContaining('resolveAutoKey'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('https://github.com/just-unknown-dev/just-database'),
        300,
        scrollable: list,
      );
      expect(
        find.textContaining('Version $kJustDatabaseVersion'),
        findsOneWidget,
      );
      expect(kJustDatabaseVersion, '2.0.0');
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'text stays readable (at least 11 px) in ${brightness.name} mode',
      (tester) async {
        final db = await _appDb(tester, 'readable_${brightness.name}', [
          'CREATE TABLE t (a TEXT, b INTEGER)',
          "INSERT INTO t VALUES ('x', 1)",
        ]);
        final theme = ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.purple,
            brightness: brightness,
          ),
        );
        final provider = DatabaseProvider();
        await _pumpScreen(tester, provider: provider, screenTheme: theme);
        await tester.tap(find.byKey(ValueKey('jdb-db-${db.name}')));
        await tester.pumpAndSettle();

        void checkText(String where) {
          final small = <String>[];
          for (final p
              in tester.allRenderObjects.whereType<RenderParagraph>()) {
            p.text.visitChildren((span) {
              final size = span.style?.fontSize ?? p.text.style?.fontSize ?? 14;
              if (span is TextSpan &&
                  (span.text ?? '').trim().isNotEmpty &&
                  size < 11) {
                small.add('"${span.text}" ($size px)');
              }
              return true;
            });
          }
          expect(small, isEmpty, reason: 'text under 11 px on $where');
        }

        checkText('the Databases tab');
        // The open database's avatar uses the scheme's on-colour.
        final avatar = tester.widget<CircleAvatar>(
          find.descendant(
            of: find.byKey(ValueKey('jdb-db-${db.name}')),
            matching: find.byType(CircleAvatar),
          ),
        );
        expect(avatar.backgroundColor, theme.colorScheme.primary);
        expect(avatar.foregroundColor, theme.colorScheme.onPrimary);

        await _openTab(tester, 'Schema');
        checkText('the Schema tab');
        await _openTab(tester, 'Settings');
        checkText('the Settings tab');
        await _finish(tester, provider, [db]);
      },
    );
  }
}

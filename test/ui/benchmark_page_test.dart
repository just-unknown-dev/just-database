// Widget tests for BenchmarkPage: the standard suite on a private database,
// SELECT-only custom queries, and errors.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/src/ui/backend/local_host.dart';
import 'package:just_database/src/ui/pages/benchmark_page.dart';

import 'ui_test_support.dart';

// In-memory only, all in the test's fake-async zone; each test closes it.
Future<JustDatabase> _openDb(WidgetTester tester) async {
  final db = await JustDatabase.open(uniqueName('bench'), persist: false);
  await exec(db, 'CREATE TABLE t (a INTEGER)');
  await exec(db, 'INSERT INTO t VALUES (1), (2), (3)');
  return db;
}

Future<void> _pumpPage(WidgetTester tester, JustDatabase db) async {
  useLargeWindow(tester);
  await tester.pumpWidget(
    MaterialApp(
      home: BenchmarkPage(
        host: LocalAdminHost(),
        database: LocalAdminDatabase.of(db),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _setField(WidgetTester tester, String label, String value) async {
  await tester.enterText(find.widgetWithText(TextFormField, label), value);
}

Future<void> _run(WidgetTester tester) async {
  await tester.tap(find.text('Run benchmark'));
  for (
    var i = 0;
    i < 50 && find.text('Benchmarking…').evaluate().isNotEmpty;
    i++
  ) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

void main() {
  late FakePaths paths;
  setUpAll(() async => paths = await FakePaths.install());
  tearDownAll(() => paths.dispose());

  testWidgets(
    'the standard suite runs on a private database and leaves this one alone',
    (tester) async {
      final db = await _openDb(tester);
      await _pumpPage(tester, db);

      await _setField(tester, 'Rows', '10');
      await _setField(tester, 'Warm-up', '0');
      await _setField(tester, 'Iterations', '2');
      await _run(tester);

      expect(find.text('Just Database, 10 rows'), findsOneWidget);
      expect(find.text('SELECT by primary key'), findsOneWidget);
      expect(db.tableNames, ['t']);
      expect(
        JustDatabase.openDatabases.where((d) => d.name.startsWith('__bench')),
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      await db.close();
    },
  );

  testWidgets('a custom query must be a SELECT; the error is shown', (
    tester,
  ) async {
    final db = await _openDb(tester);
    await _pumpPage(tester, db);

    await tester.tap(find.text('Custom SELECT'));
    await tester.pumpAndSettle();
    await _setField(tester, 'Warm-up', '0');
    await _setField(tester, 'Iterations', '1');
    await tester.enterText(
      find.byKey(const ValueKey('jdb-bench-sql')),
      'DELETE FROM t',
    );
    await _run(tester);

    expect(
      find.textContaining('The query failed: query() only runs SELECT'),
      findsOneWidget,
    );
    expect(db.rowCount('t'), 3);

    await tester.enterText(
      find.byKey(const ValueKey('jdb-bench-sql')),
      'SELECT * FROM t',
    );
    await _run(tester);
    final results = find.byType(ListView);
    expect(
      find.descendant(of: results, matching: find.text('My query')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: results, matching: find.textContaining('ops/s')),
      findsOneWidget,
    );
    expect(find.textContaining('The query failed'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });

  testWidgets('settings are validated before running', (tester) async {
    final db = await _openDb(tester);
    await _pumpPage(tester, db);

    await _setField(tester, 'Iterations', '0');
    await _setField(tester, 'Rows', '');
    await tester.tap(find.text('Run benchmark'));
    await tester.pumpAndSettle();
    expect(find.text('Use 1 to 10000'), findsOneWidget);
    expect(find.text('Enter a whole number'), findsOneWidget);
    expect(find.text('Benchmarking…'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await db.close();
  });
}

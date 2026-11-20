// JustDatabase.changes, DatabaseManager.listChanges, QueryResult.elapsed
// and the view/trigger introspection the admin UI relies on.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';

import '../helpers/temp_paths.dart';

int _n = 0;
String _name() => 'changes_${DateTime.now().microsecondsSinceEpoch}_${_n++}';

/// Collects [db]'s change events.
List<DatabaseChange> _record(JustDatabase db) {
  final events = <DatabaseChange>[];
  db.changes.listen(events.add);
  return events;
}

/// Lets queued microtasks and events run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late TempPaths paths;

  setUp(() async => paths = await TempPaths.install());
  tearDown(() async {
    for (final db in List.of(JustDatabase.openDatabases)) {
      await db.closeAll();
    }
    await paths.dispose();
  });

  group('changes', () {
    test('a write names its table; a schema change says so', () async {
      final db = await JustDatabase.open(_name(), persist: false);
      final events = _record(db);
      await db.execute('CREATE TABLE t (a INTEGER)');
      await _settle();
      expect(events, hasLength(1));
      expect(events.single.schemaChanged, isTrue);
      expect(events.single.touches('T'), isTrue);

      await db.execute('INSERT INTO t VALUES (1)');
      await _settle();
      expect(events, hasLength(2));
      expect(events.last.schemaChanged, isFalse);
      expect(events.last.tables, {'t'});
    });

    test('reads and failed statements send nothing', () async {
      final db = await JustDatabase.open(_name(), persist: false);
      await db.execute('CREATE TABLE t (a INTEGER NOT NULL)');
      await _settle();
      final events = _record(db);
      await db.query('SELECT * FROM t');
      await db.execute('INSERT INTO t VALUES (NULL)');
      await db.execute('INSERT INTO nope VALUES (1)');
      await _settle();
      expect(events, isEmpty);
    });

    test('a transaction reports once, after it commits', () async {
      final db = await JustDatabase.open(_name(), persist: false);
      await db.execute('CREATE TABLE a (x)');
      await db.execute('CREATE TABLE b (x)');
      await _settle();
      final events = _record(db);
      await db.transaction((tx) async {
        await tx.execute('INSERT INTO a VALUES (1)');
        await _settle();
        expect(events, isEmpty, reason: 'nothing before the commit');
        await tx.execute('INSERT INTO b VALUES (1)');
      });
      await _settle();
      expect(events, hasLength(1));
      expect(events.single.tables, {'a', 'b'});
    });

    test('a rolled-back transaction sends nothing', () async {
      final db = await JustDatabase.open(_name(), persist: false);
      await db.execute('CREATE TABLE a (x)');
      await _settle();
      final events = _record(db);
      await expectLater(
        db.transaction((tx) async {
          await tx.execute('INSERT INTO a VALUES (1)');
          throw StateError('undo');
        }),
        throwsStateError,
      );
      await db.execute('BEGIN');
      await db.execute('INSERT INTO a VALUES (2)');
      await db.execute('ROLLBACK');
      await _settle();
      expect(events, isEmpty);
    });

    test('BEGIN … COMMIT through execute reports at COMMIT', () async {
      final db = await JustDatabase.open(_name(), persist: false);
      await db.execute('CREATE TABLE a (x)');
      await _settle();
      final events = _record(db);
      await db.execute('BEGIN');
      await db.execute('INSERT INTO a VALUES (1)');
      await _settle();
      expect(events, isEmpty);
      await db.execute('COMMIT');
      await _settle();
      expect(events, hasLength(1));
      expect(events.single.touches('a'), isTrue);
    });

    test('a script sends one event', () async {
      final db = await JustDatabase.open(_name(), persist: false);
      final events = _record(db);
      await db.executeScript(
        'CREATE TABLE a (x); INSERT INTO a VALUES (1); CREATE VIEW v AS SELECT * FROM a',
      );
      await _settle();
      expect(events, hasLength(1));
      expect(events.single.schemaChanged, isTrue);
      expect(events.single.tables, {'a'});
    });

    test('renaming and dropping a table name both names', () async {
      final db = await JustDatabase.open(_name(), persist: false);
      await db.execute('CREATE TABLE a (x)');
      await _settle();
      final events = _record(db);
      await db.execute('ALTER TABLE a RENAME TO b');
      await _settle();
      expect(events.single.tables, containsAll(['a', 'b']));
      await db.execute('DROP TABLE b');
      await _settle();
      expect(events.last.touches('b'), isTrue);
      expect(events.last.schemaChanged, isTrue);
    });

    test('user_version alone is a change with no tables', () async {
      final db = await JustDatabase.open(_name(), persist: false);
      final events = _record(db);
      await db.execute('PRAGMA user_version = 3');
      await _settle();
      expect(events, hasLength(1));
      expect(events.single.tables, isEmpty);
      expect(events.single.schemaChanged, isFalse);
    });

    test('an import replaces everything', () async {
      final db = await JustDatabase.open(_name(), persist: false);
      await db.execute('CREATE TABLE old (x)');
      await _settle();
      final events = _record(db);
      await db.importSql(
        'CREATE TABLE fresh (y); INSERT INTO fresh VALUES (1);',
      );
      await _settle();
      expect(events, hasLength(1));
      expect(events.single.schemaChanged, isTrue);
      expect(events.single.tables, containsAll(['old', 'fresh']));
    });

    test(
      'loading a saved database sends nothing; closing ends the stream',
      () async {
        final name = _name();
        var db = await JustDatabase.open(name);
        await db.execute('CREATE TABLE t (x)');
        await db.execute('INSERT INTO t VALUES (1)');
        await db.close();
        db = await JustDatabase.open(name);
        final events = <DatabaseChange>[];
        final done = Completer<void>();
        db.changes.listen(events.add, onDone: done.complete);
        await _settle();
        expect(events, isEmpty);
        await db.close();
        await done.future.timeout(const Duration(seconds: 5));
      },
    );
  });

  group('listChanges', () {
    test('opening, closing and deleting send events', () async {
      var count = 0;
      final sub = DatabaseManager.listChanges.listen((_) => count++);
      addTearDown(sub.cancel);
      final name = _name();
      final db = await JustDatabase.open(name);
      await _settle();
      expect(count, 1);
      await db.close();
      await _settle();
      expect(count, 2);
      await DatabaseManager.deleteDatabase(name);
      await _settle();
      expect(count, 3);
    });
  });

  group('elapsed', () {
    test(
      'a statement that ran has a time; one that did not parse has none',
      () async {
        final db = await JustDatabase.open(_name(), persist: false);
        await db.execute('CREATE TABLE t (x)');
        for (var i = 0; i < 200; i++) {
          await db.execute('INSERT INTO t VALUES (?)', [i]);
        }
        final r = await db.query(
          'SELECT a.x FROM t a JOIN t b ON a.x < b.x ORDER BY 1 LIMIT 1',
        );
        expect(r.success, isTrue);
        expect(r.elapsed, greaterThan(Duration.zero));
        final bad = await db.execute('SELEKT 1');
        expect(bad.success, isFalse);
        expect(bad.elapsed, Duration.zero);
      },
    );
  });

  group('introspection', () {
    test('view and trigger SQL, triggers by table', () async {
      final db = await JustDatabase.open(_name(), persist: false);
      await db.executeScript('''
        CREATE TABLE t (x);
        CREATE TABLE log (x);
        CREATE VIEW v AS SELECT x FROM t;
        CREATE TRIGGER t_ins AFTER INSERT ON t BEGIN INSERT INTO log VALUES (new.x); END;
      ''');
      expect(db.getViewSql('V'), startsWith('CREATE VIEW v'));
      expect(db.getViewSql('nope'), isNull);
      expect(db.getTriggerSql('t_ins'), contains('INSERT INTO log'));
      expect(db.getTriggerTable('T_INS'), 't');
      expect(db.triggerNamesForTable('T'), ['t_ins']);
      expect(db.triggerNamesForTable('log'), isEmpty);
      expect(db.saveError, isNull);
    });
  });
}

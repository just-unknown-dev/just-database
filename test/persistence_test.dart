import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Points path_provider at a private temp directory so persistence tests
/// work in vm tests.
class _TempDirPathProvider extends PathProviderPlatform {
  _TempDirPathProvider(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

int _dbCounter = 0;

String _uniqueName(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_dbCounter++}';

Future<void> _exec(JustDatabase db, String sql) async {
  final result = await db.execute(sql);
  expect(result.success, isTrue, reason: '$sql\n→ ${result.errorMessage}');
}

Future<List<Map<String, dynamic>>> _rows(JustDatabase db, String sql) async {
  final result = await db.query(sql);
  expect(result.success, isTrue, reason: '$sql\n→ ${result.errorMessage}');
  return result.rows;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late Directory dbDir;

  setUpAll(() async {
    docsDir = await Directory.systemTemp.createTemp('just_database_persist_');
    dbDir = Directory('${docsDir.path}${Platform.pathSeparator}just_database');
    PathProviderPlatform.instance = _TempDirPathProvider(docsDir.path);
  });

  tearDownAll(() async {
    if (await docsDir.exists()) await docsDir.delete(recursive: true);
  });

  File dbFile(String name) =>
      File('${dbDir.path}${Platform.pathSeparator}$name.jdb');

  group('Persistence — saves', () {
    test('write → close → reopen never loses data', () async {
      // Each execute() starts a save without waiting for it, so these saves
      // used to overlap on the same file and could leave it truncated or
      // stale.
      final growing = _uniqueName('growing');
      for (var i = 0; i < 30; i++) {
        final fresh = _uniqueName('fresh');
        final db = await JustDatabase.open(fresh, persist: true);
        await _exec(db, 'CREATE TABLE a (id INTEGER PRIMARY KEY, v TEXT)');
        await _exec(db, 'CREATE TABLE b (id INTEGER PRIMARY KEY, v TEXT)');
        await _exec(db, "INSERT INTO a (id, v) VALUES (1, 'a$i')");
        await _exec(db, "INSERT INTO b (id, v) VALUES (1, 'b$i')");
        await db.close();

        final reopened = await JustDatabase.open(fresh, persist: true);
        expect(
          await _rows(reopened, 'SELECT v FROM a'),
          [
            {'v': 'a$i'},
          ],
          reason: 'iteration $i',
        );
        expect(
          await _rows(reopened, 'SELECT v FROM b'),
          [
            {'v': 'b$i'},
          ],
          reason: 'iteration $i',
        );
        await reopened.close();

        // The same database across sessions: every session adds one row.
        final g = await JustDatabase.open(growing, persist: true);
        if (i == 0) {
          await _exec(g, 'CREATE TABLE log (id INTEGER PRIMARY KEY, n INTEGER)');
        }
        await _exec(g, 'INSERT INTO log (id, n) VALUES (${i + 1}, $i)');
        await _exec(g, 'UPDATE log SET n = n + 1000 WHERE id = ${i + 1}');
        await g.close();

        final g2 = await JustDatabase.open(growing, persist: true);
        final log = await _rows(g2, 'SELECT id, n FROM log ORDER BY id');
        expect(log.length, i + 1, reason: 'iteration $i');
        expect(log.last, {'id': i + 1, 'n': i + 1000}, reason: 'iteration $i');
        await g2.close();
      }
    });

    test('un-awaited writes all land once close() returns', () async {
      final name = _uniqueName('burst');
      final db = await JustDatabase.open(name, persist: true);
      await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      final results = await Future.wait([
        for (var i = 1; i <= 50; i++)
          db.execute('INSERT INTO t (id, v) VALUES ($i, $i)'),
      ]);
      expect(results.every((r) => r.success), isTrue);
      await db.close();

      final reopened = await JustDatabase.open(name, persist: true);
      expect(await _rows(reopened, 'SELECT COUNT(*) AS c FROM t'), [
        {'c': 50},
      ]);
      await reopened.close();
    });

    test('flush() waits until every write so far is on disk', () async {
      final name = _uniqueName('flush');
      final db = await JustDatabase.open(name, persist: true);
      await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      await _exec(db, "INSERT INTO t (id, v) VALUES (1, 'one')");
      await _exec(db, "INSERT INTO t (id, v) VALUES (2, 'two')");
      await db.flush();

      // A second instance reads only what is on disk.
      final reader = await JustDatabase.open(name, persist: true);
      expect(await _rows(reader, 'SELECT v FROM t ORDER BY id'), [
        {'v': 'one'},
        {'v': 'two'},
      ]);
      await reader.close();

      // Nothing changed since the last save: flush() has nothing to do.
      await db.flush();
      await db.close();
    });

    test('flush() is a no-op for in-memory databases', () async {
      final db = await JustDatabase.open(_uniqueName('mem'), persist: false);
      await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await db.flush();
      await db.close();
    });

    test('saves leave no temporary files behind', () async {
      final name = _uniqueName('tmp');
      final db = await JustDatabase.open(name, persist: true);
      await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
      for (var i = 1; i <= 10; i++) {
        await _exec(db, 'INSERT INTO t (id) VALUES ($i)');
      }
      await db.close();

      final leftovers = dbDir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.startsWith(name) && n != '$name.jdb')
          .toList();
      expect(leftovers, isEmpty);
      expect(await PersistenceManager.listPersistedNames(), contains(name));
    });

    test('secure databases round-trip through the atomic write', () async {
      final name = _uniqueName('secure');
      const key = 'persistence-test-key';
      final db = await JustDatabase.open(
        name,
        mode: DatabaseMode.secure,
        encryptionKey: key,
      );
      await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      await _exec(db, "INSERT INTO t (id, v) VALUES (1, 'secret')");
      await db.close();

      expect(await PersistenceManager.peekMode(name), DatabaseMode.secure);
      final reopened = await JustDatabase.open(
        name,
        mode: DatabaseMode.secure,
        encryptionKey: key,
      );
      expect(await _rows(reopened, 'SELECT v FROM t'), [
        {'v': 'secret'},
      ]);
      await reopened.close();
    });
  });

  group('Persistence — unreadable files', () {
    test('open() throws on a corrupt file and leaves it untouched', () async {
      final name = _uniqueName('corrupt');
      await dbDir.create(recursive: true);
      const garbage = '{"mode": "standard", "tables": {';
      await dbFile(name).writeAsString(garbage);

      await expectLater(
        JustDatabase.open(name, persist: true),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('left untouched'),
          ),
        ),
      );
      expect(await dbFile(name).readAsString(), garbage);
    });

    test('open() throws on an empty file', () async {
      final name = _uniqueName('empty');
      await dbDir.create(recursive: true);
      await dbFile(name).writeAsString('');

      await expectLater(
        JustDatabase.open(name, persist: true),
        throwsA(isA<StateError>()),
      );
      expect(await dbFile(name).length(), 0);
    });

    test(
      'opening an encrypted file without its key throws instead of '
      'overwriting it',
      () async {
        final name = _uniqueName('secure_as_plain');
        const key = 'persistence-test-key';
        final db = await JustDatabase.open(
          name,
          mode: DatabaseMode.secure,
          encryptionKey: key,
        );
        await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
        await _exec(db, "INSERT INTO t (id, v) VALUES (1, 'kept')");
        await db.close();

        await expectLater(
          JustDatabase.open(name, persist: true),
          throwsA(isA<StateError>()),
        );

        final reopened = await JustDatabase.open(
          name,
          mode: DatabaseMode.secure,
          encryptionKey: key,
        );
        expect(await _rows(reopened, 'SELECT v FROM t'), [
          {'v': 'kept'},
        ]);
        await reopened.close();
      },
    );
  });

  group('Persistence — save errors', () {
    late PathProviderPlatform previous;
    late File notADirectory;

    setUp(() async {
      // A documents "directory" that is really a file: every save fails.
      notADirectory = File(
        '${docsDir.path}${Platform.pathSeparator}not_a_dir_${_dbCounter++}',
      );
      await notADirectory.writeAsString('x');
      previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _TempDirPathProvider(notADirectory.path);
    });

    tearDown(() async {
      PathProviderPlatform.instance = previous;
      if (await notADirectory.exists()) await notADirectory.delete();
    });

    test('flush() surfaces a failed save; close() does not throw', () async {
      final db = await JustDatabase.open(_uniqueName('unsaved'), persist: true);
      await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await expectLater(db.flush(), throwsA(isA<FileSystemException>()));
      await db.close();
      expect(db.isOpen, isFalse);
    });
  });
}

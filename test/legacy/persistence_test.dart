// Ported from the 1.x test/persistence_test.dart: saves, unreadable files
// and save errors.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';

import '../helpers/temp_paths.dart';
import 'legacy_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 2.0: databases live in <application support>/just_database/<name>.jdb.
  late TempPaths paths;

  setUpAll(() async {
    paths = await TempPaths.install();
  });

  tearDown(closeAllOpen);

  tearDownAll(() async {
    await paths.dispose();
  });

  group('Persistence — saves', () {
    test('write → close → reopen never loses data', () async {
      final growing = uniqueName('growing');
      for (var i = 0; i < 30; i++) {
        final fresh = uniqueName('fresh');
        final db = await JustDatabase.open(fresh);
        await exec(db, 'CREATE TABLE a (id INTEGER PRIMARY KEY, v TEXT)');
        await exec(db, 'CREATE TABLE b (id INTEGER PRIMARY KEY, v TEXT)');
        await exec(db, "INSERT INTO a (id, v) VALUES (1, 'a$i')");
        await exec(db, "INSERT INTO b (id, v) VALUES (1, 'b$i')");
        await db.close();

        final reopened = await JustDatabase.open(fresh);
        expect(await rows(reopened, 'SELECT v FROM a'), [
          {'v': 'a$i'},
        ], reason: 'iteration $i');
        expect(await rows(reopened, 'SELECT v FROM b'), [
          {'v': 'b$i'},
        ], reason: 'iteration $i');
        await reopened.close();

        // The same database across sessions: every session adds one row.
        final g = await JustDatabase.open(growing);
        if (i == 0) {
          await exec(g, 'CREATE TABLE log (id INTEGER PRIMARY KEY, n INTEGER)');
        }
        await exec(g, 'INSERT INTO log (id, n) VALUES (${i + 1}, $i)');
        await exec(g, 'UPDATE log SET n = n + 1000 WHERE id = ${i + 1}');
        await g.close();

        final g2 = await JustDatabase.open(growing);
        final log = await rows(g2, 'SELECT id, n FROM log ORDER BY id');
        expect(log.length, i + 1, reason: 'iteration $i');
        expect(log.last, {'id': i + 1, 'n': i + 1000}, reason: 'iteration $i');
        await g2.close();
      }
    });

    test('un-awaited writes all land once close() returns', () async {
      final name = uniqueName('burst');
      final db = await JustDatabase.open(name);
      await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
      final results = await Future.wait([
        for (var i = 1; i <= 50; i++)
          db.execute('INSERT INTO t (id, v) VALUES ($i, $i)'),
      ]);
      expect(results.every((r) => r.success), isTrue);
      await db.close();

      final reopened = await JustDatabase.open(name);
      expect(await rows(reopened, 'SELECT COUNT(*) AS c FROM t'), [
        {'c': 50},
      ]);
      await reopened.close();
    });

    test('flush() waits until every write so far is on disk', () async {
      final name = uniqueName('flush');
      final db = await JustDatabase.open(name);
      await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      await exec(db, "INSERT INTO t (id, v) VALUES (1, 'one')");
      await exec(db, "INSERT INTO t (id, v) VALUES (2, 'two')");
      await db.flush();

      // A second instance reads only what is on disk. 2.0: opening an open
      // name returns the same instance, so open a copy of the file.
      final copy = uniqueName('flush_copy');
      paths.file(name).copySync(paths.file(copy).path);
      final reader = await JustDatabase.open(copy);
      expect(identical(reader, db), isFalse);
      expect(await rows(reader, 'SELECT v FROM t ORDER BY id'), [
        {'v': 'one'},
        {'v': 'two'},
      ]);
      await reader.close();

      // Nothing changed since the last save: flush() has nothing to do.
      await db.flush();
      await db.close();
    });

    test('flush() is a no-op for in-memory databases', () async {
      final db = await JustDatabase.open(uniqueName('mem'), persist: false);
      await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await db.flush();
      await db.close();
    });

    test('saves leave no temporary files behind', () async {
      final name = uniqueName('tmp');
      final db = await JustDatabase.open(name);
      await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
      for (var i = 1; i <= 10; i++) {
        await exec(db, 'INSERT INTO t (id) VALUES ($i)');
      }
      await db.close();

      final leftovers = Directory(paths.databases)
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          // 2.0: `<name>.jdb-lock` (the guard against a second process)
          // stays next to the file; only `.tmp` files are leftovers.
          .where(
            (n) =>
                n.startsWith(name) && n != '$name.jdb' && n != '$name.jdb-lock',
          )
          .toList();
      expect(leftovers, isEmpty);
      // 2.0: PersistenceManager.listPersistedNames() is now
      // DatabaseManager.listDatabases().
      final saved = await DatabaseManager.listDatabases();
      expect(saved.map((d) => d.name), contains(name));
    });

    test('secure databases round-trip through the atomic write', () async {
      final name = uniqueName('secure');
      const key = 'persistence-test-key';
      // 2.0: encryption is on when an encryptionKey is passed (no secure
      // mode).
      final db = await JustDatabase.open(name, encryptionKey: key);
      await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      await exec(db, "INSERT INTO t (id, v) VALUES (1, 'secret')");
      await db.close();

      // 2.0: PersistenceManager.peekMode() is now DatabaseInfo.isEncrypted.
      final info = (await DatabaseManager.listDatabases()).singleWhere(
        (d) => d.name == name,
      );
      expect(info.isEncrypted, isTrue);
      final reopened = await JustDatabase.open(name, encryptionKey: key);
      expect(await rows(reopened, 'SELECT v FROM t'), [
        {'v': 'secret'},
      ]);
      await reopened.close();
    });
  });

  group('Persistence — unreadable files', () {
    test('open() throws on a corrupt file and leaves it untouched', () async {
      final name = uniqueName('corrupt');
      await Directory(paths.databases).create(recursive: true);
      const garbage = '{"mode": "standard", "tables": {';
      await paths.file(name).writeAsString(garbage);

      await expectLater(
        JustDatabase.open(name),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('left untouched'),
          ),
        ),
      );
      expect(await paths.file(name).readAsString(), garbage);
    });

    test('open() throws on an empty file', () async {
      final name = uniqueName('empty');
      await Directory(paths.databases).create(recursive: true);
      await paths.file(name).writeAsString('');

      await expectLater(JustDatabase.open(name), throwsA(isA<StateError>()));
      expect(await paths.file(name).length(), 0);
    });

    test('opening an encrypted file without its key throws instead of '
        'overwriting it', () async {
      final name = uniqueName('secure_as_plain');
      const key = 'persistence-test-key';
      final db = await JustDatabase.open(name, encryptionKey: key);
      await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      await exec(db, "INSERT INTO t (id, v) VALUES (1, 'kept')");
      await db.close();

      await expectLater(JustDatabase.open(name), throwsA(isA<StateError>()));

      final reopened = await JustDatabase.open(name, encryptionKey: key);
      expect(await rows(reopened, 'SELECT v FROM t'), [
        {'v': 'kept'},
      ]);
      await reopened.close();
    });
  });

  group('Persistence — save errors', () {
    test(
      'flush() surfaces a failed save; close() does too (1.x: it did not)',
      () async {
        // 1.x pointed the documents "directory" at a file. 2.0 locks the
        // database directory on open, so that fails at open instead; here
        // the database file's own path is a directory, so every save (a
        // rename over it) fails.
        final name = uniqueName('unsaved');
        final db = await JustDatabase.open(name);
        // open() wrote the new database; put a directory in its place.
        paths.file(name).deleteSync();
        Directory(paths.file(name).path).createSync(recursive: true);
        addTearDown(() {
          try {
            Directory(paths.file(name).path).deleteSync(recursive: true);
          } catch (_) {}
        });
        db.onSaveError = (_, _) {}; // background save failures are expected
        await exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
        await expectLater(db.flush(), throwsA(isA<FileSystemException>()));
        // 2.0: close() throws the error of its final save too (the database
        // is closed anyway).
        await expectLater(db.close(), throwsA(isA<FileSystemException>()));
        expect(db.isOpen, isFalse);
      },
    );
  });
}

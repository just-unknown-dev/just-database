import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:pointycastle/export.dart';

import '../helpers/temp_paths.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TempPaths paths;

  setUp(() async {
    paths = await TempPaths.install();
  });

  tearDown(() async {
    await DatabaseManager.closeAll();
    for (final db in JustDatabase.openDatabases) {
      await db.closeAll();
    }
    await paths.dispose();
  });

  group('opening', () {
    test('persists and reopens', () async {
      final db = await JustDatabase.open('app');
      await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
      await db.execute('INSERT INTO t (name) VALUES (?), (?)', ['a', 'b']);
      await db.close();
      expect(paths.file('app').existsSync(), isTrue);
      final again = await JustDatabase.open('app');
      final r = await again.query('SELECT name FROM t ORDER BY id');
      expect(r.values, [
        ['a'],
        ['b'],
      ]);
      await again.close();
    });

    test('a second open shares the instance; close is counted', () async {
      final a = await JustDatabase.open('shared', persist: false);
      final b = await JustDatabase.open('shared', persist: false);
      expect(identical(a, b), isTrue);
      await a.close();
      expect(b.isOpen, isTrue);
      await b.close();
      expect(b.isOpen, isFalse);
      await b.close(); // harmless
    });

    test('concurrent opens get one instance', () async {
      final both = await Future.wait([
        JustDatabase.open('race'),
        JustDatabase.open('race'),
      ]);
      expect(identical(both[0], both[1]), isTrue);
      await both[0].close();
      await both[1].close();
    });

    test('reopening while a close is still saving waits for it', () async {
      final db = await JustDatabase.open('reopen');
      await db.execute('CREATE TABLE t (v INTEGER)');
      for (var i = 0; i < 100; i++) {
        await db.execute('INSERT INTO t VALUES (?)', [i]);
      }
      final closing = db.close(); // not awaited
      final again = await JustDatabase.open('reopen');
      expect(again.rowCount('t'), 100);
      await closing;
      await again.close();
    });

    test('different options for an open name throw', () async {
      final db = await JustDatabase.open('opts', persist: false);
      expect(
        () => JustDatabase.open(
          'opts',
          persist: false,
          mode: DatabaseMode.writeFast,
        ),
        throwsStateError,
      );
      await db.close();
    });

    test('bad names are rejected', () async {
      for (final bad in ['../x', 'a/b', 'x:y', '', '.hidden', 'con', 'a..b']) {
        expect(() => JustDatabase.open(bad), throwsArgumentError, reason: bad);
      }
    });

    test('an unreadable file is not overwritten', () async {
      Directory(paths.databases).createSync(recursive: true);
      paths.file('broken').writeAsStringSync('{"version": 2, "tables": [');
      await expectLater(JustDatabase.open('broken'), throwsStateError);
      expect(
        paths.file('broken').readAsStringSync(),
        '{"version": 2, "tables": [',
      );
    });

    test('a file from a newer format version is refused', () async {
      Directory(paths.databases).createSync(recursive: true);
      paths.file('future').writeAsStringSync('{"version": 99, "tables": []}');
      await expectLater(JustDatabase.open('future'), throwsStateError);
    });

    test('a 1.x file in the documents directory is adopted', () async {
      Directory(paths.legacyDatabases).createSync(recursive: true);
      File(
        '${paths.legacyDatabases}${Platform.pathSeparator}old.jdb',
      ).writeAsStringSync(jsonEncode(_v1File()));
      final db = await JustDatabase.open('old');
      final r = await db.query(
        'SELECT id, name, active, born FROM people ORDER BY id',
      );
      expect(r.values, [
        [1, 'Ann', 1, '2000-01-02T03:04:05.000Z'],
        [2, 'Bob', 0, null],
      ]);
      // The id is the rowid now, and new rows continue after it.
      final ins = await db.execute("INSERT INTO people (name) VALUES ('Cy')");
      expect(ins.lastInsertRowId, 3);
      await db.close();
      expect(paths.file('old').existsSync(), isTrue);
    });
  });

  group('encryption', () {
    test('round trip, wrong key, missing key', () async {
      final db = await JustDatabase.open('vault', encryptionKey: 'pass phrase');
      await db.execute('CREATE TABLE s (v TEXT)');
      await db.execute("INSERT INTO s VALUES ('top secret')");
      await db.close();
      final bytes = paths.file('vault').readAsBytesSync();
      expect(
        utf8.decode(bytes, allowMalformed: true),
        isNot(contains('top secret')),
      );
      expect(bytes.sublist(0, 4), [0x4A, 0x44, 0x42, 0x02]);

      await expectLater(
        JustDatabase.open('vault', encryptionKey: 'wrong'),
        throwsStateError,
      );
      await expectLater(JustDatabase.open('vault'), throwsStateError);
      final again = await JustDatabase.open(
        'vault',
        encryptionKey: 'pass phrase',
      );
      expect((await again.query('SELECT v FROM s')).scalar, 'top secret');
      await again.close();
    });

    test('a 1.x encrypted file opens and is upgraded', () async {
      Directory(paths.databases).createSync(recursive: true);
      final plain = utf8.encode(jsonEncode(_v1File()));
      final key = Uint8List.fromList(
        crypto.sha256.convert(utf8.encode('old key')).bytes,
      );
      final iv = Uint8List.fromList(List.generate(12, (i) => i + 1));
      final c = GCMBlockCipher(AESEngine())
        ..init(true, AEADParameters(KeyParameter(key), 128, iv, Uint8List(0)));
      final sealed = c.process(Uint8List.fromList(plain));
      paths.file('legacy').writeAsBytesSync([...iv, ...sealed]);

      final db = await JustDatabase.open('legacy', encryptionKey: 'old key');
      expect((await db.query('SELECT COUNT(*) FROM people')).scalar, 2);
      await db.close();
      expect(paths.file('legacy').readAsBytesSync().sublist(0, 4), [
        0x4A,
        0x44,
        0x42,
        0x02,
      ]);
      final again = await JustDatabase.open('legacy', encryptionKey: 'old key');
      expect((await again.query('SELECT COUNT(*) FROM people')).scalar, 2);
      await again.close();
    });

    test('changeEncryptionKey encrypts, rekeys and decrypts', () async {
      final db = await JustDatabase.open('rekey');
      await db.execute('CREATE TABLE t (v)');
      await db.changeEncryptionKey('k1');
      await db.close();
      await expectLater(JustDatabase.open('rekey'), throwsStateError);
      final a = await JustDatabase.open('rekey', encryptionKey: 'k1');
      await a.changeEncryptionKey(null);
      await a.close();
      final b = await JustDatabase.open('rekey');
      expect(b.tableNames, ['t']);
      await b.close();
    });

    test('the key never appears in errors', () async {
      Directory(paths.databases).createSync(recursive: true);
      final db = await JustDatabase.open('k', encryptionKey: 'TOP-SECRET-KEY');
      await db.close();
      try {
        await JustDatabase.open('k', encryptionKey: 'OTHER-SECRET');
        fail('should throw');
      } catch (e) {
        expect('$e', isNot(contains('SECRET')));
      }
      expect(
        () => JustDatabase.open('x', encryptionKey: ''),
        throwsArgumentError,
      );
    });
  });

  group('statements', () {
    late JustDatabase db;
    setUp(() async {
      db = await JustDatabase.open('stmts', persist: false);
      await db.execute(
        'CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, at DATETIME, ok BOOLEAN, data BLOB)',
      );
    });
    tearDown(() => db.close());

    test('parameters bind Dart values', () async {
      final when = DateTime.utc(2024, 1, 2, 3, 4, 5);
      await db.execute(
        'INSERT INTO t (name, at, ok, data) VALUES (:name, :at, :ok, :data)',
        {
          'name': "O'Brien",
          ':at': when,
          'ok': true,
          'data': Uint8List.fromList([1, 2, 255]),
        },
      );
      final r = await db.query(
        'SELECT name, at, ok, data FROM t WHERE ok = ?',
        [true],
      );
      expect(r.values.single, [
        "O'Brien",
        '2024-01-02T03:04:05.000Z',
        1,
        Uint8List.fromList([1, 2, 255]),
      ]);
    });

    test('wrong parameter counts and query() writes are errors', () async {
      expect((await db.execute('SELECT ?')).error?.kind, SqlErrorKind.misuse);
      expect((await db.execute('SELECT ?', [1, 2])).success, isFalse);
      final w = await db.query("INSERT INTO t (name) VALUES ('x')");
      expect(w.error?.kind, SqlErrorKind.misuse);
      expect(db.rowCount('t'), 0);
    });

    test('duplicate result names are made unique', () async {
      await db.execute("INSERT INTO t (name) VALUES ('a')");
      final r = await db.query(
        'SELECT a.id, b.id FROM t a JOIN t b ON a.id = b.id',
      );
      expect(r.columns, ['id', 'id:1']);
    });

    test('executeScript stops at the first error', () async {
      final results = await db.executeScript(
        "INSERT INTO t (name) VALUES ('a'); INSERT INTO nope VALUES (1); INSERT INTO t (name) VALUES ('c')",
      );
      expect(results.length, 2);
      expect(results.last.success, isFalse);
      expect(db.rowCount('t'), 1);
    });

    test('QueryBuilder binds values', () async {
      await db.from('t').insert({'name': "it's", 'ok': false});
      final r = await db.from('t').whereEquals('name', "it's").get();
      expect(r.rows.single['ok'], 0);
      await db.from('t').where('name = ?', ["it's"]).update({'name': 'x'});
      expect((await db.from('t').select(['name']).get()).scalar, 'x');
    });
  });

  group('transactions', () {
    test('roll back on error, commit otherwise, nest as savepoints', () async {
      final db = await JustDatabase.open('tx', persist: false);
      await db.execute('CREATE TABLE t (v INTEGER UNIQUE)');
      await expectLater(
        db.transaction((tx) async {
          await tx.execute('INSERT INTO t VALUES (1)');
          await tx.execute('INSERT INTO t VALUES (1)');
        }),
        throwsA(isA<SqlException>()),
      );
      expect(db.rowCount('t'), 0);
      await db.transaction((tx) async {
        await tx.execute('INSERT INTO t VALUES (1)');
        try {
          await tx.transaction((inner) async {
            await inner.execute('INSERT INTO t VALUES (2)');
            throw StateError('undo the inner one');
          });
        } on StateError {
          // expected
        }
        await tx.execute('INSERT INTO t VALUES (3)');
      });
      expect((await db.query('SELECT v FROM t ORDER BY v')).values, [
        [1],
        [3],
      ]);
      await db.close();
    });

    test('other callers wait for a transaction', () async {
      final db = await JustDatabase.open('iso', persist: false);
      await db.execute('CREATE TABLE t (v INTEGER)');
      final order = <String>[];
      final tx = db.transaction((tx) async {
        await tx.execute('INSERT INTO t VALUES (1)');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        order.add('tx');
        throw StateError('roll back');
      });
      final other = db
          .execute('INSERT INTO t VALUES (2)')
          .then((_) => order.add('other'));
      await expectLater(tx, throwsStateError);
      await other;
      expect(order, ['tx', 'other']);
      expect((await db.query('SELECT v FROM t')).values, [
        [2],
      ]);
      await db.close();
    });

    test('nothing uncommitted is saved; close rolls back', () async {
      final db = await JustDatabase.open('uncommitted');
      await db.execute('CREATE TABLE t (v TEXT)');
      await db.flush();
      await db.execute('BEGIN');
      await db.execute("INSERT INTO t VALUES ('UNCOMMITTED_MARKER')");
      await db.flush();
      expect(
        paths.file('uncommitted').readAsStringSync(),
        isNot(contains('UNCOMMITTED_MARKER')),
      );
      await db.close();
      final again = await JustDatabase.open('uncommitted');
      expect(again.rowCount('t'), 0);
      await again.close();
    });
  });

  group('saving', () {
    test('views, triggers, indexes and infinities survive a reopen', () async {
      final db = await JustDatabase.open('keep');
      await db.executeScript('''
        CREATE TABLE t (id INTEGER PRIMARY KEY, v REAL, n TEXT);
        CREATE INDEX t_n ON t (n);
        CREATE VIEW big AS SELECT * FROM t WHERE v > 1;
        CREATE TABLE log (m TEXT);
        CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO log VALUES (NEW.n); END;
        INSERT INTO t (v, n) VALUES (1e400, 'inf'), (-1e400, 'ninf'), (2.5, 'x');
      ''');
      await db.close();
      final again = await JustDatabase.open('keep');
      expect(again.viewNames, ['big']);
      expect(again.triggerNames, ['tr']);
      expect(again.indexNamesForTable('t'), contains('t_n'));
      expect((await again.query('SELECT v FROM t ORDER BY id')).values, [
        [double.infinity],
        [double.negativeInfinity],
        [2.5],
      ]);
      await again.execute("INSERT INTO t (v, n) VALUES (0, 'after')");
      expect((await again.query('SELECT COUNT(*) FROM log')).scalar, 4);
      await again.close();
    });

    test('close waits for statements already running', () async {
      final db = await JustDatabase.open('inflight');
      await db.execute('CREATE TABLE t (v INTEGER)');
      final writes = [
        for (var i = 0; i < 20; i++)
          db.execute('INSERT INTO t VALUES (?)', [i]),
      ];
      await db.close();
      await Future.wait(writes);
      final again = await JustDatabase.open('inflight');
      expect(again.rowCount('t'), 20);
      await again.close();
    });

    test('writeFast batches saves', () async {
      final db = await JustDatabase.open('batch', mode: DatabaseMode.writeFast);
      await db.execute('CREATE TABLE t (v INTEGER)');
      for (var i = 0; i < 50; i++) {
        await db.execute('INSERT INTO t VALUES (?)', [i]);
      }
      await db.flush();
      await db.close();
      final again = await JustDatabase.open(
        'batch',
        mode: DatabaseMode.writeFast,
      );
      expect(again.rowCount('t'), 50);
      await again.close();
    });
  });

  group('migrations', () {
    test(
      'each step is atomic; versions, checksums and order are checked',
      () async {
        final db = await JustDatabase.open('mig');
        final v1 = SqlMigration(
          version: 1,
          name: 'a',
          upSql: 'CREATE TABLE a (x)',
          downSql: 'DROP TABLE a',
        );
        final bad = SqlMigration(
          version: 2,
          name: 'b',
          upSql: 'CREATE TABLE b (x); INSERT INTO missing VALUES (1)',
        );
        final r1 = await db.migrate([v1, bad]);
        expect(r1.map((r) => r.status), [
          MigrationStatus.applied,
          MigrationStatus.failed,
        ]);
        expect(db.tableNames, isNot(contains('b')));
        final fixed = SqlMigration(
          version: 2,
          name: 'b',
          upSql: 'CREATE TABLE b (x)',
        );
        final r2 = await db.migrate([v1, fixed]);
        expect(r2.single.status, MigrationStatus.applied);
        expect(await db.migrationRunner([v1, fixed]).currentVersion(), 2);

        expect(() => MigrationRunner(db, [v1, v1]), throwsArgumentError);
        final changed = SqlMigration(
          version: 1,
          name: 'a',
          upSql: 'CREATE TABLE a (x, y)',
        );
        await expectLater(
          db.migrate([changed, fixed]),
          throwsA(isA<MigrationException>()),
        );
        final r3 = await db.migrate([v1, fixed]);
        expect(r3, isEmpty);
        final down = await db
            .migrationRunner([v1, fixed])
            .rollback(targetVersion: 1);
        expect(down.single.status, MigrationStatus.failed); // v2 has no downSql
        expect(db.tableNames, contains('b'));
        await db.close();
      },
    );

    test('a migration below the applied version is refused', () async {
      final db = await JustDatabase.open('order');
      final m1 = SqlMigration(version: 1, name: 'a', upSql: 'SELECT 1');
      final m3 = SqlMigration(version: 3, name: 'c', upSql: 'SELECT 1');
      await db.migrate([m1, m3]);
      final m2 = SqlMigration(
        version: 2,
        name: 'b',
        upSql: 'CREATE TABLE b (x)',
      );
      await expectLater(
        db.migrate([m1, m2, m3]),
        throwsA(isA<MigrationException>()),
      );
      await db.close();
    });
  });

  group('backup', () {
    Future<JustDatabase> sample() async {
      final db = await JustDatabase.open('src', persist: false);
      await db.executeScript('''
        CREATE TABLE p (id INTEGER PRIMARY KEY AUTOINCREMENT, n REAL DEFAULT -1.5, b BLOB, at DATETIME);
        CREATE TABLE c (a INTEGER, b TEXT, PRIMARY KEY (a, b));
        CREATE UNIQUE INDEX p_at ON p (at);
        CREATE VIEW pv AS SELECT id FROM p;
        CREATE TRIGGER pt AFTER DELETE ON p BEGIN DELETE FROM c; END;
        INSERT INTO p (n, b, at) VALUES (-5, X'0102FF', '2024-01-01');
        INSERT INTO p (b) VALUES (NULL);
        INSERT INTO c VALUES (1, 'x');
      ''');
      return db;
    }

    test('SQL dump round trip', () async {
      final db = await sample();
      final sql = await db.exportSql();
      final copy = await JustDatabase.open('copy', persist: false);
      await copy.importSql(sql);
      expect(
        (await copy.query('SELECT * FROM p ORDER BY id')).values,
        (await db.query('SELECT * FROM p ORDER BY id')).values,
      );
      expect(copy.viewNames, ['pv']);
      expect(copy.triggerNames, ['pt']);
      expect(
        (await copy.execute("INSERT INTO c VALUES (1, 'x')")).success,
        isFalse,
      );
      expect((await copy.query('SELECT n FROM p WHERE id = 2')).scalar, -1.5);
      await db.close();
      await copy.close();
    });

    test('JSON round trip keeps the AUTOINCREMENT high-water mark', () async {
      final db = await sample();
      await db.execute('DELETE FROM p WHERE id = 2');
      final json =
          jsonDecode(jsonEncode(await db.exportJson())) as Map<String, Object?>;
      final copy = await JustDatabase.open('copy2', persist: false);
      await copy.importJson(json);
      final r = await copy.execute('INSERT INTO p (n) VALUES (1)');
      expect(r.lastInsertRowId, 3);
      expect(
        (await copy.query('SELECT b FROM p WHERE id = 1')).scalar,
        Uint8List.fromList([1, 2, 255]),
      );
      await db.close();
      await copy.close();
    });

    test('a failing import changes nothing', () async {
      final db = await sample();
      await expectLater(
        db.importSql('CREATE TABLE z (x); INSERT INTO nope VALUES (1);'),
        throwsA(isA<SqlException>()),
      );
      expect(db.tableNames, ['p', 'c']);
      await db.close();
    });
  });

  group('manager', () {
    test('sees databases the app opened and keeps its own reference', () async {
      final app = await JustDatabase.open('appdb');
      final viaManager = await DatabaseManager.open('appdb');
      expect(identical(app, viaManager), isTrue);
      await DatabaseManager.close('appdb');
      expect(app.isOpen, isTrue);
      final list = await DatabaseManager.listDatabases();
      expect(list.map((d) => d.name), contains('appdb'));
      await app.close();
    });

    test('deleteAll only deletes this app\'s databases', () async {
      final db = await JustDatabase.open('mine');
      await db.close();
      Directory(paths.legacyDatabases).createSync(recursive: true);
      final other = File(
        '${paths.legacyDatabases}${Platform.pathSeparator}other_app.jdb',
      )..writeAsStringSync('{}');
      await DatabaseManager.deleteAll();
      expect(paths.file('mine').existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
    });
  });
}

/// A file as just_database 1.x wrote it.
Map<String, Object?> _v1File() => {
  'version': 1,
  'mode': 'standard',
  'tables': {
    'people': {
      'schema': {
        'tableName': 'people',
        'columns': [
          {
            'name': 'id',
            'type': 'integer',
            'constraints': {'primaryKey': true, 'autoIncrement': true},
          },
          {
            'name': 'name',
            'type': 'text',
            'constraints': {'notNull': true},
          },
          {
            'name': 'active',
            'type': 'boolean',
            'constraints': {'hasDefault': true, 'defaultValue': true},
          },
          {'name': 'born', 'type': 'datetime', 'constraints': {}},
        ],
        'tableConstraints': [],
      },
      'autoIncrement': 2,
      'nextRowId': 3,
      'rows': [
        [
          1,
          'Ann',
          true,
          {'__type': 'datetime', 'data': '2000-01-02T03:04:05.000Z'},
        ],
        [2, 'Bob', false, null],
      ],
      'indices': [
        {
          'name': 'idx_id',
          'columns': ['id'],
          'type': 'primary',
          'unique': true,
          'createdAt': '2026-01-01T00:00:00.000',
        },
      ],
    },
  },
};

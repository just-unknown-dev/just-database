// Audit probes: database lifecycle + native persistence + encryption.
// Each test asserts the CORRECT behaviour, so a failure means the bug exists.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TempDirPathProvider extends PathProviderPlatform {
  _TempDirPathProvider(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

int _n = 0;
String _name(String p) =>
    'probe_${p}_${DateTime.now().microsecondsSinceEpoch}_${_n++}';

Future<void> _exec(JustDatabase db, String sql) async {
  final r = await db.execute(sql);
  expect(r.success, isTrue, reason: '$sql -> ${r.errorMessage}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory docs;
  late Directory dbDir;

  setUpAll(() async {
    docs = await Directory.systemTemp.createTemp('jdb_persist_probe_');
    dbDir = Directory('${docs.path}${Platform.pathSeparator}just_database');
    PathProviderPlatform.instance = _TempDirPathProvider(docs.path);
  });
  tearDownAll(() async {
    await DatabaseManager.closeAll();
    try {
      await docs.delete(recursive: true);
    } catch (_) {}
  });

  File dbFile(String name) =>
      File('${dbDir.path}${Platform.pathSeparator}$name.jdb');

  test('PER transaction: uncommitted rows are not written to disk', () async {
    final name = _name('tx');
    final db = await JustDatabase.open(name);
    await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    await db.flush();
    await db.beginTransaction();
    await _exec(db, "INSERT INTO t (id, v) VALUES (1, 'UNCOMMITTED_MARKER')");
    await db.flush();
    final onDisk = await dbFile(name).readAsString();
    // A crash here must not leave the uncommitted row on disk.
    final leaked = onDisk.contains('UNCOMMITTED_MARKER');
    await db.rollback();
    await db.close();
    expect(
      leaked,
      isFalse,
      reason: 'the save during an open transaction wrote the uncommitted row',
    );
  });

  test(
    'PER transaction: close() inside a transaction does not persist it',
    () async {
      final name = _name('tx_close');
      final db = await JustDatabase.open(name);
      await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      await db.beginTransaction();
      await _exec(db, "INSERT INTO t (id, v) VALUES (1, 'never committed')");
      await db.close();
      final again = await JustDatabase.open(name);
      final rows = (await again.query('SELECT * FROM t')).rows;
      await again.close();
      expect(rows, isEmpty);
    },
  );

  test('PER views and triggers survive close/reopen', () async {
    final name = _name('views');
    final db = await JustDatabase.open(name);
    await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
    await _exec(db, 'CREATE TABLE log (id INTEGER PRIMARY KEY, msg TEXT)');
    await _exec(db, 'CREATE VIEW big AS SELECT * FROM t WHERE v > 10');
    await _exec(
      db,
      'CREATE TRIGGER trg AFTER INSERT ON t BEGIN '
      "INSERT INTO log (msg) VALUES ('ins'); END",
    );
    expect(db.viewNames, contains('big'));
    expect(db.triggerNames, contains('trg'));
    await db.close();
    final again = await JustDatabase.open(name);
    final views = again.viewNames;
    final triggers = again.triggerNames;
    await again.close();
    expect(
      {'views': views, 'triggers': triggers},
      {
        'views': ['big'],
        'triggers': ['trg'],
      },
      reason: 'views/triggers lost on reopen',
    );
  });

  test('PER CREATE INDEX survives close/reopen', () async {
    final name = _name('idx');
    final db = await JustDatabase.open(name);
    await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v INTEGER)');
    await _exec(db, 'CREATE INDEX idx_v ON t (v)');
    final before = db.indexNamesForTable('t');
    await db.close();
    final again = await JustDatabase.open(name);
    final after = again.indexNamesForTable('t');
    final drop = await again.execute('DROP INDEX idx_v');
    await again.close();
    expect(
      {'names': after.toSet(), 'drop': drop.errorMessage},
      {'names': before.toSet(), 'drop': null},
    );
  });

  test('PER a non-finite REAL does not stop every later save', () async {
    final name = _name('inf');
    final db = await JustDatabase.open(name);
    await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, r REAL)');
    await db.flush();
    String? used;
    for (final expr in ['1e400', '1.0/0.0', '0.0/0.0', '-1e400']) {
      final r = await db.execute('INSERT INTO t (id, r) VALUES (1, $expr)');
      if (!r.success) continue;
      final v = (await db.query(
        'SELECT r FROM t WHERE id = 1',
      )).rows.first['r'];
      if (v is double && !v.isFinite) {
        used = expr;
        break;
      }
      await db.execute('DELETE FROM t WHERE id = 1');
    }
    if (used == null) {
      await db.close();
      markTestSkipped('no SQL expression produced a non-finite double');
      return;
    }
    await _exec(db, 'INSERT INTO t (id, r) VALUES (2, 2.5)');
    Object? flushError;
    try {
      await db.flush();
    } catch (e) {
      flushError = e;
    }
    await db.close();
    final again = await JustDatabase.open(name);
    final rows = (await again.query('SELECT id FROM t ORDER BY id')).rows;
    await again.close();
    expect(flushError, isNull, reason: 'flush failed after inserting $used');
    expect(
      rows.map((r) => r['id']),
      containsAll([2]),
      reason: 'row 2 was lost because $used made every save throw',
    );
  });

  test(
    'PER database name "../x" does not escape the database directory',
    () async {
      final leaf = _name('escape');
      final escaped = File('${docs.path}${Platform.pathSeparator}$leaf.jdb');
      Object? openError;
      try {
        final db = await JustDatabase.open('../$leaf');
        await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
        await db.close();
      } catch (e) {
        openError = e;
      }
      final exists = escaped.existsSync();
      if (exists) escaped.deleteSync();
      expect(
        exists,
        isFalse,
        reason:
            'wrote ${escaped.path} outside just_database/ (error: $openError)',
      );
    },
  );

  test(
    'PER database name with a path separator is rejected or saved',
    () async {
      final name = 'sub/${_name('slash')}';
      JustDatabase? db;
      try {
        db = await JustDatabase.open(name);
      } on ArgumentError {
        return; // rejecting the name is fine
      }
      await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
      Object? err;
      try {
        await db.flush();
      } catch (e) {
        err = e;
      }
      await db.close();
      expect(
        err,
        isNull,
        reason: 'open() accepted "$name" but every save fails',
      );
    },
  );

  test(
    'PER a write in flight at close() is saved by close(), nothing after',
    () async {
      final name = _name('inflight');
      final db = await JustDatabase.open(name);
      await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      await _exec(db, 'CREATE TABLE log (id INTEGER PRIMARY KEY, m TEXT)');
      await _exec(
        db,
        'CREATE TRIGGER trg AFTER INSERT ON t BEGIN '
        "INSERT INTO log (m) VALUES ('a'); INSERT INTO log (m) VALUES ('b'); END",
      );
      await db.flush();
      final pending = [
        for (var i = 1; i <= 20; i++)
          db.execute("INSERT INTO t (id, v) VALUES ($i, 'INFLIGHT_$i')"),
      ];
      await db.close();
      final atClose = await dbFile(name).readAsString();
      final results = await Future.wait(
        pending.map(
          (f) => f.then<Object?>((r) => r.success, onError: (Object e) => e),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final later = await dbFile(name).readAsString();
      final ok = results.where((r) => r == true).length;
      final inFile = RegExp('INFLIGHT_').allMatches(atClose).length;
      expect(
        {
          'succeeded': ok,
          'on disk at close': inFile,
          'written after close': later != atClose,
        },
        {'succeeded': ok, 'on disk at close': ok, 'written after close': false},
      );
    },
  );

  test('PER key never appears in error messages', () async {
    Object? err;
    try {
      await JustDatabase.open(
        _name('leak'),
        persist: false,
        encryptionKey: 'TOP-SECRET-KEY',
      );
    } catch (e) {
      err = e;
    }
    expect(err.toString(), isNot(contains('TOP-SECRET-KEY')));
  });

  test('PER an empty encryptionKey is rejected', () async {
    Object? err;
    try {
      final db = await JustDatabase.open(
        _name('emptykey'),
        persist: false,
        encryptionKey: '',
      );
      await db.close();
    } catch (e) {
      err = e;
    }
    expect(err, isA<ArgumentError>());
  });

  test('PER QueryBuilder.insert handles DATETIME and BLOB values', () async {
    final db = await JustDatabase.open(_name('qb'), persist: false);
    await _exec(
      db,
      'CREATE TABLE t (id INTEGER PRIMARY KEY, d DATETIME, b BLOB)',
    );
    final r1 = await db.from('t').insert({
      'id': 1,
      'd': DateTime.utc(2026, 1, 2),
    });
    final r2 = await db.from('t').insert({
      'id': 2,
      'b': Uint8List.fromList([1, 2]),
    });
    await db.close();
    expect(
      {'datetime': r1.errorMessage, 'blob': r2.errorMessage},
      {'datetime': null, 'blob': null},
    );
  });

  test('PER double close() is harmless', () async {
    final db = await JustDatabase.open(_name('dclose'), persist: false);
    await db.close();
    await expectLater(db.close(), completes);
  });

  test('PER same file opened twice does not lose writes', () async {
    final name = _name('twice');
    final a = await JustDatabase.open(name);
    await _exec(a, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
    await a.flush();
    JustDatabase b;
    try {
      b = await JustDatabase.open(name);
    } on StateError {
      await a.close();
      return; // refusing the second open is a correct fix
    }
    await _exec(a, 'INSERT INTO t (id) VALUES (1)');
    await _exec(b, 'INSERT INTO t (id) VALUES (2)');
    await a.close();
    await b.close();
    final c = await JustDatabase.open(name);
    final ids = (await c.query(
      'SELECT id FROM t ORDER BY id',
    )).rows.map((r) => r['id']).toList();
    await c.close();
    expect(ids, [1, 2], reason: 'last close() overwrote the other instance');
  });

  test(
    'PER DatabaseManager.open after db.close() returns an open db',
    () async {
      final name = _name('mgr_closed');
      final db = await DatabaseManager.open(name, persist: false);
      await db.close();
      final again = await DatabaseManager.open(name, persist: false);
      expect(
        again.isOpen,
        isTrue,
        reason: 'the manager handed back the closed instance',
      );
      await DatabaseManager.close(name);
    },
  );

  test('PER concurrent DatabaseManager.open returns one instance', () async {
    final name = _name('mgr_race');
    final both = await Future.wait([
      DatabaseManager.open(name, persist: false),
      DatabaseManager.open(name, persist: false),
    ]);
    final same = identical(both[0], both[1]);
    await both[0].close();
    if (both[1].isOpen) await both[1].close();
    expect(same, isTrue, reason: 'two instances for one database');
  });

  test('PER DatabaseManager.open checks mode and key of an open db', () async {
    final name = _name('mgr_key');
    await DatabaseManager.open(name, encryptionKey: 'right-key');
    Object? err;
    try {
      await DatabaseManager.open(name, encryptionKey: 'WRONG-key');
    } catch (e) {
      err = e;
    }
    await DatabaseManager.close(name);
    expect(
      err,
      isNotNull,
      reason: 'a wrong key got the already-open, decrypted database',
    );
  });

  test('PER encrypted file is tamper-evident (GCM tag checked)', () async {
    final name = _name('tamper');
    final db = await JustDatabase.open(name, encryptionKey: 'k');
    await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    await _exec(db, "INSERT INTO t (id, v) VALUES (1, 'x')");
    await db.close();
    final bytes = await dbFile(name).readAsBytes();
    bytes[bytes.length ~/ 2] ^= 0x01;
    await dbFile(name).writeAsBytes(bytes);
    await expectLater(
      JustDatabase.open(name, encryptionKey: 'k'),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'PER secure file key is not a bare unsalted SHA-256 of the passphrase',
    () async {
      // README: "The encryptionKey string is passed through PBKDF2-HMAC-SHA256
      // (310 000 iterations, random per-database salt)".
      const passphrase = 'my-secret-passphrase';
      final name = _name('kdf');
      final db = await JustDatabase.open(name, encryptionKey: passphrase);
      await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      await _exec(db, "INSERT INTO t (id, v) VALUES (1, 'secret')");
      await db.close();
      final raw = await dbFile(name).readAsBytes();
      final key = Uint8List.fromList(
        sha256.convert(utf8.encode(passphrase)).bytes,
      );
      String? plain;
      try {
        final c = GCMBlockCipher(AESEngine())
          ..init(
            false,
            AEADParameters(
              KeyParameter(key),
              128,
              Uint8List.fromList(raw.sublist(0, 12)),
              Uint8List(0),
            ),
          );
        plain = utf8.decode(c.process(Uint8List.fromList(raw.sublist(12))));
      } catch (_) {}
      expect(
        plain,
        isNull,
        reason:
            'decrypted with SHA-256(passphrase): ${plain?.substring(0, 60)}',
      );
    },
  );

  test('PER open() refuses a file written by a newer format version', () async {
    final name = _name('future');
    await dbDir.create(recursive: true);
    const future =
        '{"version": 2, "mode": "standard", "tables": {}, "pages": [1,2,3]}';
    await dbFile(name).writeAsString(future);
    Object? err;
    try {
      final db = await JustDatabase.open(name);
      await _exec(db, 'CREATE TABLE t (id INTEGER PRIMARY KEY)');
      await db.close();
    } catch (e) {
      err = e;
    }
    final after = await dbFile(name).readAsString();
    expect(
      err,
      isNotNull,
      reason:
          'opened an unknown version and rewrote it as: '
          '${after.substring(0, 40)}',
    );
  });

  test('PER peekMode of a corrupt plain file is not "secure"', () async {
    final name = _name('peek');
    await dbDir.create(recursive: true);
    await dbFile(name).writeAsString('{"mode": "standard", "tables": {');
    final info = (await DatabaseManager.listDatabases()).firstWhere(
      (d) => d.name == name,
    );
    expect(info.isEncrypted, isFalse);
  });

  test('PER migrate() reports a failed save', () async {
    final name = _name('mig_save');
    final db = await JustDatabase.open(name);
    // A directory where the .jdb file goes: every rename onto it fails.
    final file = File('${dbDir.path}${Platform.pathSeparator}$name.jdb');
    await file.delete();
    await Directory(file.path).create(recursive: true);
    Object? err;
    try {
      await db.migrate([
        SqlMigration(
          version: 1,
          name: 'one',
          upSql: 'CREATE TABLE t (id INTEGER PRIMARY KEY)',
        ),
      ]);
    } catch (e) {
      err = e;
    }
    Object? flushErr;
    try {
      await db.flush();
    } catch (e) {
      flushErr = e;
    }
    // close() reports the failed final save too.
    await expectLater(db.close(), throwsA(isA<FileSystemException>()));
    expect(flushErr, isNotNull, reason: 'precondition: saves must fail here');
    expect(
      err,
      isNotNull,
      reason: 'migrate() returned "applied" although nothing was saved',
    );
  });

  test('PER perf: one save of a 20k-row table (plain + secure)', () async {
    final name = _name('perf');
    final db = await JustDatabase.open(name);
    await _exec(
      db,
      'CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b REAL, c INTEGER)',
    );
    await db.transaction((tx) async {
      for (var i = 0; i < 20000; i++) {
        await tx.execute('INSERT INTO t (id, a, b, c) VALUES (?, ?, ?, ?)', [
          i,
          'row number $i padding',
          i * 1.5,
          i,
        ]);
      }
    });
    var sw = Stopwatch()..start();
    await db.flush();
    // ignore: avoid_print
    print(
      'save(plain): ${sw.elapsedMilliseconds}ms, file ${dbFile(name).lengthSync()} bytes',
    );
    sw = Stopwatch()..start();
    await db.changeEncryptionKey('k');
    // ignore: avoid_print
    print('save(encrypted, incl. key derivation): ${sw.elapsedMilliseconds}ms');
    await db.close();
  }, timeout: const Timeout(Duration(minutes: 3)));
}

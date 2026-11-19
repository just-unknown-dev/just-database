// Audit probes for the storage layer (Table / TableIndex / schema).
// Every test asserts the CORRECT behaviour, so a failing test = a bug.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'dart:convert';
import 'package:just_database/src/persistence/codec.dart';
import 'package:just_database/src/storage/catalog.dart';
import 'package:just_database/src/storage/index.dart';
import 'package:just_database/src/storage/values.dart';
import '../helpers/engine_harness.dart';

void main() {
  late Map<String, Object> tables;
  late EngineHarness ex;

  setUp(() {
    tables = {};
    ex = EngineHarness(tables);
  });

  Future<QueryResult> sql(String s) => ex.executeSQL(s);

  Future<void> ok(String s) async {
    final r = await sql(s);
    expect(r.success, isTrue, reason: '$s -> ${r.errorMessage}');
  }

  Future<void> fails(String s) async {
    final r = await sql(s);
    expect(r.success, isFalse, reason: '$s should have been rejected');
  }

  Future<List<Map<String, dynamic>>> rows(String s) async {
    final r = await sql(s);
    expect(r.success, isTrue, reason: '$s -> ${r.errorMessage}');
    return r.rows;
  }

  group('AUTOINCREMENT / primary key', () {
    test(
      'STO autoinc: auto id after an explicit id does not collide',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
        await ok("INSERT INTO t (id, v) VALUES (1, 'a')");
        final r = await sql("INSERT INTO t (v) VALUES ('b')");
        expect(r.success, isTrue, reason: r.errorMessage);
        expect(await rows('SELECT id FROM t ORDER BY id'), [
          {'id': 1},
          {'id': 2},
        ]);
      },
    );

    test('STO autoinc: failed insert does not burn an id', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT NOT NULL)');
      await fails('INSERT INTO t (v) VALUES (NULL)');
      await ok("INSERT INTO t (v) VALUES ('ok')");
      expect(await rows('SELECT id FROM t'), [
        {'id': 1},
      ]);
    });

    test('STO autoinc-restore: INSERT without id works after a JSON '
        'backup restore', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT)');
      await ok("INSERT INTO t (v) VALUES ('a')");
      await ok("INSERT INTO t (v) VALUES ('b')");
      final restored = EngineHarness();
      final json =
          jsonDecode(jsonEncode(encodeCatalog(ex.engine.catalog)))
              as Map<String, Object?>;
      restored.engine.catalog.loadTable(decodeCatalog(json).table('t')!);
      final r = await restored.executeSQL("INSERT INTO t (v) VALUES ('c')");
      expect(r.success, isTrue, reason: r.errorMessage);
    });

    test(
      'STO upd-coerce: UPDATE id = \'1\' onto an existing INTEGER PK',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
        await ok("INSERT INTO t (id, v) VALUES (1, 'a')");
        await ok("INSERT INTO t (id, v) VALUES (2, 'b')");
        await fails("UPDATE t SET id = '1' WHERE id = 2");
      },
    );

    test('STO pk-coerce: INTEGER PK 5 and \'5\' are the same key', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      await ok("INSERT INTO t (id, v) VALUES (5, 'a')");
      await fails("INSERT INTO t (id, v) VALUES ('5', 'b')");
      expect((await rows('SELECT * FROM t')).length, 1);
    });

    test('STO pk-coerce: TEXT UNIQUE \'1\' then 1 is a duplicate', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, code TEXT UNIQUE)');
      await ok("INSERT INTO t (code) VALUES ('1')");
      await fails('INSERT INTO t (code) VALUES (1)');
      expect((await rows('SELECT * FROM t')).length, 1);
    });
  });

  group('UNIQUE enforcement', () {
    test(
      'STO uq-nulls (sanity): several NULLs allowed in UNIQUE columns',
      () async {
        await ok(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, u TEXT UNIQUE, '
          'a INTEGER, b INTEGER, UNIQUE (a, b))',
        );
        await ok('INSERT INTO t (u, a, b) VALUES (NULL, 1, NULL)');
        await ok('INSERT INTO t (u, a, b) VALUES (NULL, 1, NULL)');
      },
    );

    test('STO uq-tablelevel: table-level UNIQUE(a) on one column', () async {
      await ok('CREATE TABLE t (a INTEGER, b TEXT, UNIQUE (a))');
      await ok("INSERT INTO t (a, b) VALUES (1, 'x')");
      await fails("INSERT INTO t (a, b) VALUES (1, 'y')");
    });

    test(
      'STO pk-tablelevel: table-level PRIMARY KEY (id) on one column',
      () async {
        await ok('CREATE TABLE t (id INTEGER, v TEXT, PRIMARY KEY (id))');
        await ok("INSERT INTO t (id, v) VALUES (1, 'a')");
        await fails("INSERT INTO t (id, v) VALUES (1, 'b')");
      },
    );

    test('STO pk-tablelevel-auto: table-level INTEGER PRIMARY KEY (id) is '
        'assigned when omitted', () async {
      await ok('CREATE TABLE t (id INTEGER, v TEXT, PRIMARY KEY (id))');
      await ok("INSERT INTO t (v) VALUES ('a')");
      expect(await rows('SELECT id FROM t'), [
        {'id': 1},
      ]);
    });

    test('STO two-pks: two column-level PRIMARY KEYs are rejected', () async {
      await fails(
        'CREATE TABLE t (a INTEGER PRIMARY KEY, b INTEGER PRIMARY KEY)',
      );
    });

    test('STO uq-index: CREATE UNIQUE INDEX on one column', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, email TEXT)');
      await ok('CREATE UNIQUE INDEX ux_email ON t (email)');
      await ok("INSERT INTO t (email) VALUES ('a@x')");
      await fails("INSERT INTO t (email) VALUES ('a@x')");
    });

    test(
      'STO uq-index-existing-dups: CREATE UNIQUE INDEX over duplicates',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, email TEXT)');
        await ok("INSERT INTO t (email) VALUES ('a@x')");
        await ok("INSERT INTO t (email) VALUES ('a@x')");
        await fails('CREATE UNIQUE INDEX ux_email ON t (email)');
      },
    );

    test(
      'STO uq-index-case: CREATE UNIQUE INDEX names column in other case',
      () async {
        await ok(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER)',
        );
        await ok('CREATE UNIQUE INDEX ux_ab ON t (A, B)');
        await ok('INSERT INTO t (a, b) VALUES (1, 1)');
        await fails('INSERT INTO t (a, b) VALUES (1, 1)');
      },
    );

    test(
      'STO idx-missing-col: CREATE INDEX on a missing column fails',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER)');
        await fails('CREATE INDEX ix ON t (nope)');
      },
    );

    test(
      'STO upd-composite-pk: UPDATE into a duplicate composite PK',
      () async {
        await ok('CREATE TABLE t (a INTEGER, b INTEGER, PRIMARY KEY (a, b))');
        await ok('INSERT INTO t (a, b) VALUES (1, 1)');
        await ok('INSERT INTO t (a, b) VALUES (1, 2)');
        await fails('UPDATE t SET b = 1 WHERE b = 2');
        expect(await rows('SELECT b FROM t ORDER BY b'), [
          {'b': 1},
          {'b': 2},
        ]);
      },
    );

    test(
      'STO upd-composite-uq: UPDATE into a duplicate composite UNIQUE',
      () async {
        await ok(
          'CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b INTEGER, '
          'UNIQUE (a, b))',
        );
        await ok('INSERT INTO t (a, b) VALUES (1, 1)');
        await ok('INSERT INTO t (a, b) VALUES (1, 2)');
        await fails('UPDATE t SET b = 1 WHERE b = 2');
      },
    );

    test(
      'STO datetime-uq-same: DATETIME UNIQUE rejects the same instant',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, at DATETIME UNIQUE)');
        await ok("INSERT INTO t (at) VALUES ('2024-01-01T00:00:00Z')");
        await fails("INSERT INTO t (at) VALUES ('2024-01-01T00:00:00Z')");
      },
    );

    test(
      'STO datetime-uq: DATETIME UNIQUE values 1 microsecond apart',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, at DATETIME UNIQUE)');
        await ok("INSERT INTO t (at) VALUES ('2024-01-01T00:00:00.000001Z')");
        await ok("INSERT INTO t (at) VALUES ('2024-01-01T00:00:00.000002Z')");
      },
    );
  });

  group('Statement atomicity', () {
    test('STO upd-atomic: failing multi-row UPDATE changes nothing', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, u INTEGER UNIQUE)');
      await ok('INSERT INTO t (id, u) VALUES (1, 1)');
      await ok('INSERT INTO t (id, u) VALUES (2, 2)');
      await fails('UPDATE t SET u = 5');
      expect(await rows('SELECT u FROM t ORDER BY id'), [
        {'u': 1},
        {'u': 2},
      ]);
    });

    test('STO ins-atomic: failing multi-row INSERT inserts nothing', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, u INTEGER UNIQUE)');
      await ok('INSERT INTO t (id, u) VALUES (1, 1)');
      await fails('INSERT INTO t (id, u) VALUES (3, 3), (4, 1)');
      expect((await rows('SELECT * FROM t')).length, 1);
    });

    test(
      'STO upd-notnull: UPDATE cannot set a NOT NULL column to NULL',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, n TEXT NOT NULL)');
        await ok("INSERT INTO t (n) VALUES ('x')");
        await fails('UPDATE t SET n = NULL');
      },
    );
  });

  group('Column names and case', () {
    test('STO ins-case: INSERT with column names in another case', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL)');
      await ok("INSERT INTO t (ID, NAME) VALUES (1, 'a')");
      expect(await rows('SELECT name FROM t'), [
        {'name': 'a'},
      ]);
    });

    test('STO upd-case: UPDATE SET NAME changes column name (and survives '
        'a save/load)', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
      await ok("INSERT INTO t (name) VALUES ('a')");
      await ok("UPDATE t SET NAME = 'b'");
      final reloaded = decodeCatalog(
        jsonDecode(jsonEncode(encodeCatalog(ex.engine.catalog)))
            as Map<String, Object?>,
      ).table('t')!;
      expect(reloaded.entries.single.value, [1, 'b']);
    });

    test(
      'STO ins-unknown-col: INSERT into a column that does not exist',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)');
        await fails("INSERT INTO t (nope) VALUES ('x')");
      },
    );

    test(
      'STO upd-unknown-col: UPDATE of a column that does not exist',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)');
        await ok("INSERT INTO t (a) VALUES ('x')");
        await fails("UPDATE t SET nope = 'y'");
      },
    );
  });

  group('ALTER TABLE', () {
    test(
      'STO rename-unique: UNIQUE still enforced after RENAME COLUMN',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, email TEXT UNIQUE)');
        await ok("INSERT INTO t (email) VALUES ('a')");
        await ok('ALTER TABLE t RENAME COLUMN email TO mail');
        await fails("INSERT INTO t (mail) VALUES ('a')");
        // A value first inserted after the rename must be unique too.
        await ok("INSERT INTO t (mail) VALUES ('b')");
        await fails("INSERT INTO t (mail) VALUES ('b')");
      },
    );

    test(
      'STO rename-pk: PRIMARY KEY still enforced after RENAME COLUMN',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
        await ok("INSERT INTO t (id, v) VALUES (1, 'a')");
        await ok('ALTER TABLE t RENAME COLUMN id TO pk');
        await fails("INSERT INTO t (pk, v) VALUES (1, 'b')");
        await ok("INSERT INTO t (pk, v) VALUES (2, 'c')");
        await fails("INSERT INTO t (pk, v) VALUES (2, 'd')");
      },
    );

    test('STO rename-composite: composite PK after RENAME COLUMN', () async {
      await ok('CREATE TABLE t (a INTEGER, b INTEGER, PRIMARY KEY (a, b))');
      await ok('INSERT INTO t (a, b) VALUES (1, 1)');
      await ok('ALTER TABLE t RENAME COLUMN b TO c');
      await fails('INSERT INTO t (a, c) VALUES (1, 1)');
    });

    test(
      'STO rename-case: RENAME COLUMN with the old name in another case',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, email TEXT)');
        await ok("INSERT INTO t (email) VALUES ('a')");
        await ok('ALTER TABLE t RENAME COLUMN EMAIL TO mail');
        expect(await rows('SELECT mail FROM t'), [
          {'mail': 'a'},
        ]);
      },
    );

    test(
      'STO rename-onto-existing: RENAME COLUMN onto an existing name',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b TEXT)');
        await fails('ALTER TABLE t RENAME COLUMN a TO b');
      },
    );

    test('STO drop-case: DROP COLUMN NAME really removes the data', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)');
      await ok("INSERT INTO t (name) VALUES ('secret')");
      await ok('ALTER TABLE t DROP COLUMN NAME');
      await ok('ALTER TABLE t ADD COLUMN name TEXT');
      expect(await rows('SELECT name FROM t'), [
        {'name': null},
      ]);
    });

    test('STO drop-missing: DROP COLUMN of a missing column fails', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)');
      await fails('ALTER TABLE t DROP COLUMN nope');
    });

    test('STO drop-pk: DROP COLUMN of the PRIMARY KEY fails', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)');
      await fails('ALTER TABLE t DROP COLUMN id');
    });

    test(
      'STO drop-composite-member: dropping a composite-PK column fails',
      () async {
        await ok(
          'CREATE TABLE t (a INTEGER, b INTEGER, c TEXT, '
          'PRIMARY KEY (a, b))',
        );
        await fails('ALTER TABLE t DROP COLUMN b');
      },
    );

    test('STO add-dup: ADD COLUMN with an existing name fails', () async {
      await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)');
      await fails('ALTER TABLE t ADD COLUMN a TEXT');
    });

    test(
      'STO add-notnull: ADD COLUMN NOT NULL without DEFAULT on rows',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)');
        await ok("INSERT INTO t (a) VALUES ('x')");
        final r = await sql('ALTER TABLE t ADD COLUMN b TEXT NOT NULL');
        if (r.success) {
          // If accepted, no row may hold NULL in a NOT NULL column.
          expect(await rows('SELECT b FROM t WHERE b IS NULL'), isEmpty);
        }
      },
    );

    test(
      'STO add-unique-default: ADD COLUMN UNIQUE DEFAULT over 2 rows',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT)');
        await ok("INSERT INTO t (a) VALUES ('x')");
        await ok("INSERT INTO t (a) VALUES ('y')");
        final r = await sql(
          "ALTER TABLE t ADD COLUMN c TEXT UNIQUE DEFAULT 'k'",
        );
        if (r.success) {
          final cs = (await rows(
            'SELECT c FROM t',
          )).map((e) => e['c']).toList();
          expect(cs.toSet().length, cs.length, reason: 'duplicate UNIQUE $cs');
        }
      },
    );

    test(
      'STO add-default-coerce: ADD COLUMN INTEGER DEFAULT \'5\' backfill',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY)');
        await ok('INSERT INTO t (id) VALUES (1)');
        await ok("ALTER TABLE t ADD COLUMN n INTEGER DEFAULT '5'");
        await ok('INSERT INTO t (id) VALUES (2)');
        expect(await rows('SELECT n FROM t ORDER BY id'), [
          {'n': 5},
          {'n': 5},
        ]);
      },
    );
  });

  group('DROP INDEX of constraint indexes', () {
    test(
      'STO drop-pk-index: DROP INDEX id cannot remove the PK index',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
        await ok("INSERT INTO t (id, v) VALUES (1, 'a')");
        await sql('DROP INDEX id ON t');
        await sql('DROP INDEX idx_id');
        await fails("INSERT INTO t (id, v) VALUES (1, 'b')");
      },
    );

    test(
      'STO drop-unique-index: DROP INDEX idx_email cannot remove UNIQUE',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, email TEXT UNIQUE)');
        await ok("INSERT INTO t (email) VALUES ('a')");
        final names = ex.engine.catalog
            .table('t')!
            .indexes
            .map((m) => m.name)
            .toList();
        for (final n in names) {
          await sql('DROP INDEX $n');
        }
        await fails("INSERT INTO t (email) VALUES ('a')");
      },
    );
  });

  group('Performance', () {
    test(
      'STO update-all-quadratic: UPDATE of every row scales linearly',
      () async {
        Future<int> timeFor(int n) async {
          final ts = <String, Object>{};
          final e = EngineHarness(ts);
          await e.executeSQL(
            'CREATE TABLE p (id INTEGER PRIMARY KEY, v INTEGER)',
          );
          final b = StringBuffer('INSERT INTO p (v) VALUES ');
          b.write(List.filled(n, '(0)').join(', '));
          expect((await e.executeSQL(b.toString())).success, isTrue);
          final sw = Stopwatch()..start();
          expect((await e.executeSQL('UPDATE p SET v = 1')).success, isTrue);
          return sw.elapsedMicroseconds;
        }

        final small = await timeFor(5000);
        final big = await timeFor(40000);
        // ignore: avoid_print
        print(
          'UPDATE all: 5000 rows ${small ~/ 1000} ms, '
          '40000 rows ${big ~/ 1000} ms',
        );
        // Quadratic took seconds; a ratio on a few ms is noisy under load.
        expect(
          big < 2000000 || big / small < 16,
          isTrue,
          reason: '8x rows took ${big / small}x',
        );
      },
    );
  });

  group('Low-cardinality index buckets', () {
    test('STO bucket-remove-quadratic: DELETE of rows sharing one FK value '
        'scales linearly', () async {
      Future<int> timeFor(int n) async {
        final ts = <String, Object>{};
        final e = EngineHarness(ts);
        await e.executeSQL('CREATE TABLE owner (id INTEGER PRIMARY KEY)');
        await e.executeSQL('INSERT INTO owner (id) VALUES (1)');
        await e.executeSQL(
          'CREATE TABLE item (id INTEGER PRIMARY KEY, '
          'owner_id INTEGER REFERENCES owner (id))',
        );
        final b = StringBuffer('INSERT INTO item (owner_id) VALUES ');
        b.write(List.filled(n, '(1)').join(', '));
        expect((await e.executeSQL(b.toString())).success, isTrue);
        final sw = Stopwatch()..start();
        expect((await e.executeSQL('DELETE FROM item')).success, isTrue);
        return sw.elapsedMicroseconds;
      }

      final small = await timeFor(10000);
      final big = await timeFor(80000);
      // ignore: avoid_print
      print('DELETE same-FK: 10k ${small ~/ 1000} ms, 80k ${big ~/ 1000} ms');
      // Quadratic took seconds; a ratio on a few ms is noisy under load.
      expect(
        big < 2000000 || big / small < 16,
        isTrue,
        reason: '8x rows: ${big / small}x',
      );
    });
  });

  group('Composite key hashing', () {
    test('STO composite-hash: (n, n) keys do not all collide', () {
      int timeFor(bool diagonal) {
        final idx = TableIndex(
          name: 'x',
          columns: [0, 1],
          collations: [Collation.binary, Collation.binary],
          unique: true,
          origin: IndexOrigin.unique,
        );
        final sw = Stopwatch()..start();
        for (var i = 0; i < 20000; i++) {
          final row = diagonal
              ? <Object?>[i, i]
              : <Object?>[i, i * 7919 + 104729];
          idx.conflict(row);
          idx.add(row, i);
        }
        return sw.elapsedMicroseconds;
      }

      final normal = timeFor(false);
      final diagonal = timeFor(true);
      // ignore: avoid_print
      print(
        'composite 20k: spread ${normal ~/ 1000} ms, diagonal ${diagonal ~/ 1000} ms',
      );
      expect(diagonal / normal, lessThan(5));
    });
  });

  group('Index persistence (file codec)', () {
    Catalog reload() => decodeCatalog(
      jsonDecode(jsonEncode(encodeCatalog(ex.engine.catalog)))
          as Map<String, Object?>,
    );

    test(
      'STO idx-reload-two: two indexes on one column survive a reload',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER)');
        await ok('CREATE INDEX ix1 ON t (a)');
        await ok('CREATE INDEX ix2 ON t (a)');
        final names = reload()
            .table('t')!
            .describeIndexes()
            .map((m) => m.name)
            .toSet();
        expect(names, containsAll(['ix1', 'ix2']));
      },
    );

    test(
      'STO idx-reload-unique-col: CREATE INDEX on a UNIQUE column survives a reload',
      () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER UNIQUE)');
        await ok('CREATE INDEX ix_a ON t (a)');
        final names = reload()
            .table('t')!
            .describeIndexes()
            .map((m) => m.name)
            .toSet();
        expect(names, contains('ix_a'));
      },
    );

    test('STO rowid-reload: row ids are stable across a reload', () async {
      await ok('CREATE TABLE t (v TEXT)');
      await ok("INSERT INTO t (rowid, v) VALUES (7, 'a'), (9, 'b')");
      expect(reload().table('t')!.rowids.toList(), [7, 9]);
    });
  });

  group('Type affinity', () {
    test(
      'STO affinity-tinyint: TINYINT stores integers, not strings',
      () async {
        await ok('CREATE TABLE t (a TINYINT, b MEDIUMINT, c INT8)');
        await ok('INSERT INTO t (a, b, c) VALUES (5, 6, 7)');
        expect(await rows('SELECT a, b, c FROM t'), [
          {'a': 5, 'b': 6, 'c': 7},
        ]);
      },
    );

    test(
      'STO affinity-int-real: INTEGER column keeps 3.7 (no truncation)',
      () async {
        await ok('CREATE TABLE t (a INTEGER)');
        await ok('INSERT INTO t (a) VALUES (3.7)');
        expect(await rows('SELECT a FROM t'), [
          {'a': 3.7},
        ]);
      },
    );

    test(
      'STO int-infinity: INTEGER column given 1e400 is rejected cleanly',
      () async {
        await ok('CREATE TABLE t (a INTEGER)');
        // SQLite keeps a value INTEGER affinity cannot convert: Infinity.
        final r = await sql('INSERT INTO t (a) VALUES (1e400)');
        expect(r.success, isTrue, reason: r.errorMessage);
        expect(await rows('SELECT a, typeof(a) AS t FROM t'), [
          {'a': double.infinity, 't': 'real'},
        ]);
      },
    );
  });
}

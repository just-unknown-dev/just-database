// What an app and a connected workbench send each other: every value,
// result, error and snapshot survives JSON unchanged.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/src/core/workbench_wire.dart';

/// [json] after a trip through JSON text, as over the VM service.
Object? _wire(Object? json) => jsonDecode(jsonEncode(json));

void main() {
  test('values JSON cannot carry exactly are tagged', () {
    final values = <Object?>[
      null,
      0,
      -42,
      9007199254740991,
      9007199254740993,
      -9223372036854775808,
      1.5,
      2.0,
      double.nan,
      double.infinity,
      double.negativeInfinity,
      '',
      'ünïcødé ✓',
      Uint8List.fromList([0, 1, 254, 255]),
      Uint8List(0),
    ];
    for (final v in values) {
      final back = decodeValue(_wire(encodeValue(v)));
      if (v is double && v.isNaN) {
        expect(back, isA<double>().having((d) => d.isNaN, 'isNaN', isTrue));
      } else {
        expect(back, v, reason: '$v');
        expect(back.runtimeType, v.runtimeType, reason: '$v');
      }
    }
    // A string that looks like a tag stays a string.
    expect(decodeValue(_wire(encodeValue(r'{"$blob":"AA=="}'))), isA<String>());
  });

  test('parameters: positional and named', () {
    expect(decodeParameters(_wire(encodeParameters(null))), isNull);
    final blob = Uint8List.fromList([7, 8]);
    expect(decodeParameters(_wire(encodeParameters([1, 'a', blob, null]))), [
      1,
      'a',
      blob,
      null,
    ]);
    expect(decodeParameters(_wire(encodeParameters({':id': 3, 'name': 'x'}))), {
      ':id': 3,
      'name': 'x',
    });
    expect(() => encodeParameters('nope'), throwsArgumentError);
  });

  test('results, failures and errors keep their kind and position', () async {
    final db = await JustDatabase.open('wire_results', persist: false);
    addTearDown(db.close);
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, b BLOB, r REAL)');
    await db.execute('INSERT INTO t (b, r) VALUES (?, ?)', [
      Uint8List.fromList([1, 2, 3]),
      0.25,
    ]);
    final ok = await db.query('SELECT * FROM t');
    final back = decodeResult(_wire(encodeResult(ok)) as Map<String, Object?>);
    expect(back.columns, ok.columns);
    expect(back.values, ok.values);
    expect(back.elapsed, ok.elapsed);
    expect(back.success, isTrue);

    final insert = await db.execute('INSERT INTO t (r) VALUES (1.0)');
    final insertBack = decodeResult(
      _wire(encodeResult(insert)) as Map<String, Object?>,
    );
    expect(insertBack.affectedRows, 1);
    expect(insertBack.lastInsertRowId, insert.lastInsertRowId);

    const syntax = SqlException.syntax('near "FORM"', 'SELECT * FORM t', 9);
    final failed = decodeResult(
      _wire(encodeResult(QueryResult.failure(syntax))) as Map<String, Object?>,
    );
    expect(failed.success, isFalse);
    expect(failed.error!.message, syntax.message);
    expect(failed.error!.kind, SqlErrorKind.syntax);
    expect(failed.error!.sql, syntax.sql);
    expect(failed.error!.offset, 9);

    Object roundTrip(Object e) =>
        decodeError(_wire(encodeError(e)) as Map<String, Object?>);
    expect(roundTrip(syntax), isA<SqlException>());
    expect(
      roundTrip(StateError('gone')),
      isA<StateError>().having((e) => e.message, 'message', 'gone'),
    );
    expect(
      roundTrip(ArgumentError('bad')),
      isA<ArgumentError>().having((e) => e.message, 'message', 'bad'),
    );
    expect(
      roundTrip(const FormatException('json')),
      isA<FormatException>().having((e) => e.message, 'message', 'json'),
    );
    expect('${roundTrip(Exception('other'))}', 'Exception: other');
  });

  test('a snapshot answers what the database answers', () async {
    final db = await JustDatabase.open('wire_snapshot', persist: false);
    addTearDown(db.close);
    await db.executeScript('''
      CREATE TABLE players (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE,
        level INTEGER DEFAULT 1 CHECK (level > 0));
      CREATE TABLE runs (id INTEGER PRIMARY KEY,
        player_id INTEGER REFERENCES players(id) ON DELETE CASCADE,
        score INTEGER);
      CREATE INDEX runs_score ON runs (score);
      CREATE VIEW best AS SELECT player_id, MAX(score) AS s FROM runs GROUP BY player_id;
      CREATE TRIGGER t1 AFTER INSERT ON runs BEGIN SELECT 1; END;
      CREATE TRIGGER t2 AFTER DELETE ON players BEGIN SELECT 1; END;
      INSERT INTO players (name) VALUES ('Ann'), ('Bob');
      INSERT INTO runs (player_id, score) VALUES (1, 10), (2, 20), (1, 30);
    ''');
    final snap = DatabaseSnapshot.fromJson(
      _wire(DatabaseSnapshot.of(db).toJson()) as Map<String, Object?>,
    );
    expect(snap.name, db.name);
    expect(snap.mode, db.mode);
    expect(snap.isOpen, isTrue);
    expect(snap.openerCount, 1);
    expect(snap.estimatedSizeBytes, db.estimatedSizeBytes);
    expect([for (final t in snap.tables) t.schema.name], db.tableNames);
    for (final t in snap.tables) {
      final name = t.schema.name;
      expect(t.schema.sql, db.getTableSchema(name)!.sql);
      expect(t.rowCount, db.rowCount(name));
      expect(
        [
          for (final i in t.indexes)
            '${i.name} ${i.columns} ${i.unique} ${i.origin}',
        ],
        [
          for (final i in db.indexesForTable(name))
            '${i.name} ${i.columns} ${i.unique} ${i.origin}',
        ],
      );
    }
    expect([for (final v in snap.views) v.name], db.viewNames);
    expect(snap.views.single.sql, db.getViewSql('best'));
    expect([for (final t in snap.triggers) t.name], db.triggerNames);
    expect([for (final t in snap.triggers) t.table], ['runs', 'players']);
  });

  test('listings, changes and benchmark results', () {
    const info = DatabaseInfo(
      name: 'a',
      isOpen: true,
      isPersisted: true,
      isEncrypted: true,
      sizeBytes: 123,
      mode: DatabaseMode.readFast,
      tableCount: 2,
      totalRows: 9,
    );
    final infoBack = decodeDatabaseInfo(
      _wire(encodeDatabaseInfo(info)) as Map<String, Object?>,
    );
    expect(
      [
        infoBack.name,
        infoBack.isOpen,
        infoBack.isPersisted,
        infoBack.isEncrypted,
        infoBack.sizeBytes,
        infoBack.mode,
        infoBack.tableCount,
        infoBack.totalRows,
      ],
      ['a', true, true, true, 123, DatabaseMode.readFast, 2, 9],
    );

    final change = decodeChange(
      _wire(
            encodeChange(
              const DatabaseChange(tables: {'t', 'u'}, schemaChanged: true),
            ),
          )
          as Map<String, Object?>,
    );
    expect(change.tables, {'t', 'u'});
    expect(change.schemaChanged, isTrue);

    final suite = BenchmarkSuiteResult(
      suiteName: 'standard',
      runAt: DateTime.utc(2026, 11, 20, 12),
      results: const [
        QueryStats(
          label: 'insert',
          iterations: 3,
          times: [
            Duration(microseconds: 10),
            Duration(microseconds: 30),
            Duration(microseconds: 20),
          ],
        ),
      ],
    );
    final suiteBack = decodeSuiteResult(
      _wire(encodeSuiteResult(suite)) as Map<String, Object?>,
    );
    expect(suiteBack.suiteName, 'standard');
    expect(suiteBack.runAt, suite.runAt);
    expect(suiteBack.results.single.median, const Duration(microseconds: 20));
    expect(suiteBack.results.single.format(), suite.results.single.format());
  });
}

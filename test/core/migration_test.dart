// Audit probes: MigrationRunner / JustDatabase.migrate.
// Each test asserts the CORRECT behaviour, so a failure means the bug exists.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';

int _n = 0;
String _name(String p) =>
    'mig_${p}_${DateTime.now().microsecondsSinceEpoch}_${_n++}';

SqlMigration _m(int v, String up, {String? down}) =>
    SqlMigration(version: v, name: 'v$v', upSql: up, downSql: down);

void main() {
  test('MIG a failed migration leaves no partial schema behind', () async {
    final db = await JustDatabase.open(_name('partial'), persist: false);
    final r1 = await db.migrate([
      _m(
        1,
        'CREATE TABLE a (id INTEGER PRIMARY KEY);\n'
        'INSERT INTO missing_table (id) VALUES (1);',
      ),
    ]);
    expect(r1.single.status, MigrationStatus.failed);
    final leftover = db.tableNames.contains('a');
    // The fixed migration must now apply cleanly.
    final r2 = await db.migrate([
      _m(
        1,
        'CREATE TABLE a (id INTEGER PRIMARY KEY);\n'
        'CREATE TABLE b (id INTEGER PRIMARY KEY);',
      ),
    ]);
    await db.close();
    expect(
      {'leftover a': leftover, 'retry': r2.single.status.name},
      {'leftover a': false, 'retry': 'applied'},
      reason: 'retry error: ${r2.single.errorMessage}',
    );
  });

  test('MIG duplicate versions are rejected', () async {
    final db = await JustDatabase.open(_name('dup'), persist: false);
    Object? err;
    List<MigrationResult>? res;
    try {
      res = await db.migrate([
        _m(1, 'CREATE TABLE a (id INTEGER PRIMARY KEY)'),
        _m(1, 'CREATE TABLE b (id INTEGER PRIMARY KEY)'),
      ]);
    } catch (e) {
      err = e;
    }
    final tables = db.tableNames.toList();
    await db.close();
    expect(
      err,
      isA<ArgumentError>(),
      reason: 'no error; results: $res; tables now: $tables',
    );
  });

  test(
    'MIG a migration added below the current version is not skipped',
    () async {
      final db = await JustDatabase.open(_name('gap'), persist: false);
      await db.migrate([
        _m(1, 'CREATE TABLE a (id INTEGER PRIMARY KEY)'),
        _m(3, 'CREATE TABLE c (id INTEGER PRIMARY KEY)'),
      ]);
      final all = [
        _m(1, 'CREATE TABLE a (id INTEGER PRIMARY KEY)'),
        _m(2, 'CREATE TABLE b (id INTEGER PRIMARY KEY)'),
        _m(3, 'CREATE TABLE c (id INTEGER PRIMARY KEY)'),
      ];
      final status = await db.migrationRunner(all).status();
      // Never skipped silently: migrate refuses the out-of-order step.
      await expectLater(db.migrate(all), throwsA(isA<MigrationException>()));
      await db.close();
      expect(
        status.firstWhere((s) => s.version == 2).status,
        MigrationStatus.pending,
      );
    },
  );

  test('MIG a changed, already-applied migration is detected', () async {
    final db = await JustDatabase.open(_name('cksum'), persist: false);
    await db.migrate([_m(1, 'CREATE TABLE a (id INTEGER PRIMARY KEY)')]);
    Object? err;
    List<MigrationResult>? res;
    try {
      res = await db.migrate([
        _m(1, 'CREATE TABLE a (id INTEGER PRIMARY KEY, extra TEXT)'),
      ]);
    } catch (e) {
      err = e;
    }
    await db.close();
    expect(
      err != null || (res?.any((r) => !r.success) ?? false),
      isTrue,
      reason: 'checksum mismatch ignored: $res',
    );
  });

  test(
    'MIG rollback() of a failed down() leaves the version consistent',
    () async {
      final db = await JustDatabase.open(_name('down'), persist: false);
      await db.migrate([
        _m(
          1,
          'CREATE TABLE a (id INTEGER PRIMARY KEY);'
          'CREATE TABLE b (id INTEGER PRIMARY KEY);',
          down: 'DROP TABLE b; DROP TABLE nope;',
        ),
      ]);
      final runner = db.migrationRunner([
        _m(
          1,
          'CREATE TABLE a (id INTEGER PRIMARY KEY);'
          'CREATE TABLE b (id INTEGER PRIMARY KEY);',
          down: 'DROP TABLE b; DROP TABLE nope;',
        ),
      ]);
      final res = await runner.rollback();
      final version = await runner.currentVersion();
      final hasB = db.tableNames.contains('b');
      await db.close();
      expect(res.single.status, MigrationStatus.failed);
      // Either the down() is undone (b still there, version 1) or it completed.
      expect(
        {'version': version, 'b exists': hasB},
        {'version': 1, 'b exists': true},
        reason: 'half-rolled-back: b dropped but version still $version',
      );
    },
  );
}

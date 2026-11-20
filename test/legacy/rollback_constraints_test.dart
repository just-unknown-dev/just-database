// Ported from the 1.x test/rollback_constraints_test.dart.
//
// Regression tests: ROLLBACK and ROLLBACK TO SAVEPOINT must restore every
// index (definition and contents), so UNIQUE and PRIMARY KEY constraints keep
// being enforced and explicit indexes survive.
//
// 2.0: Table, TableIndex and the raw tables map are internal. Index contents
// are read through a query that forces the index with an INDEX hint, and
// index names through indexNamesForTable().
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';

import 'legacy_helpers.dart';

void main() {
  late JustDatabase db;

  setUp(() async => db = await openMemory('rb'));

  tearDown(closeAllOpen);

  Future<QueryResult> sql(String statement, [JustDatabase? on]) =>
      (on ?? db).execute(statement);

  Future<void> ok(String statement, [JustDatabase? on]) async {
    final r = await sql(statement, on);
    expect(r.success, isTrue, reason: '$statement → ${r.errorMessage}');
  }

  /// The `id` values of the rows that [index] on [column] maps [value] to.
  Future<List<Object?>> idsVia(
    String table,
    String index,
    String column,
    Object value, [
    JustDatabase? on,
  ]) async {
    final r = await (on ?? db).query(
      'SELECT /*+ INDEX($table $index) */ id FROM $table WHERE $column = ? ORDER BY id',
      [value],
    );
    expect(r.success, isTrue, reason: r.errorMessage);
    return [for (final row in r.values) row.first];
  }

  Future<void> rejected(String statement, [JustDatabase? on]) async {
    final r = await sql(statement, on);
    expect(r.success, isFalse, reason: '$statement should have been rejected');
    expect(r.errorMessage, contains('UNIQUE constraint'));
  }

  /// Runs [write] inside a transaction and rolls it back, in each of the
  /// ways a transaction can be undone.
  final rollbacks = <String, Future<void> Function(String write)>{
    'ROLLBACK': (write) async {
      await ok('BEGIN');
      await ok(write);
      await ok('ROLLBACK');
    },
    'ROLLBACK TO SAVEPOINT': (write) async {
      await ok('BEGIN');
      await ok('SAVEPOINT sp');
      await ok(write);
      await ok('ROLLBACK TO SAVEPOINT sp');
      await ok('COMMIT');
    },
  };

  for (final MapEntry(key: kind, value: rollback) in rollbacks.entries) {
    group('after $kind', () {
      test('UNIQUE column is still enforced', () async {
        await ok('CREATE TABLE u (id INTEGER PRIMARY KEY, email TEXT UNIQUE)');
        await ok("INSERT INTO u (id, email) VALUES (1, 'a@x')");
        await rollback("INSERT INTO u (id, email) VALUES (2, 'b@x')");

        await rejected("INSERT INTO u (id, email) VALUES (3, 'a@x')");
        await ok("INSERT INTO u (id, email) VALUES (3, 'c@x')");
        // The rolled-back value is free again.
        await ok("INSERT INTO u (id, email) VALUES (2, 'b@x')");
        final update = await sql("UPDATE u SET email = 'a@x' WHERE id = 3");
        expect(update.success, isFalse);
        expect(update.errorMessage, contains('UNIQUE constraint'));
      });

      test('single-column PRIMARY KEY is still enforced', () async {
        await ok('CREATE TABLE u (id INTEGER PRIMARY KEY, email TEXT UNIQUE)');
        await ok("INSERT INTO u (id, email) VALUES (1, 'a@x')");
        await rollback("INSERT INTO u (id, email) VALUES (2, 'b@x')");

        await rejected("INSERT INTO u (id, email) VALUES (1, 'c@x')");
        await ok("INSERT INTO u (id, email) VALUES (2, 'c@x')");
        expect(await rows(db, 'SELECT id, email FROM u ORDER BY id'), [
          {'id': 1, 'email': 'a@x'},
          {'id': 2, 'email': 'c@x'},
        ]);
      });

      test('composite PRIMARY KEY is still enforced', () async {
        await ok(
          'CREATE TABLE m (a INTEGER, b INTEGER, v TEXT, PRIMARY KEY (a, b))',
        );
        await ok("INSERT INTO m (a, b, v) VALUES (1, 1, 'first')");
        await rollback("INSERT INTO m (a, b, v) VALUES (1, 2, 'gone')");

        await rejected("INSERT INTO m (a, b, v) VALUES (1, 1, 'dup')");
        await ok("INSERT INTO m (a, b, v) VALUES (1, 2, 'second')");
        await rejected("INSERT INTO m (a, b, v) VALUES (1, 2, 'dup')");
      });

      test('explicit CREATE INDEX survives with its contents', () async {
        await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, a INTEGER, b TEXT)');
        await ok("INSERT INTO t (id, a, b) VALUES (1, 10, 'x')");
        await ok("INSERT INTO t (id, a, b) VALUES (2, 20, 'y')");
        await ok('CREATE INDEX idx_t_b ON t (b)');
        await ok('CREATE UNIQUE INDEX idx_t_ab ON t (a, b)');
        await rollback("INSERT INTO t (id, a, b) VALUES (3, 30, 'x')");

        expect(
          db.indexNamesForTable('t'),
          containsAll(['idx_t_b', 'idx_t_ab']),
        );
        expect(await idsVia('t', 'idx_t_b', 'b', 'x'), [1]);
        expect(await idsVia('t', 'idx_t_b', 'b', 'y'), [2]);
        await rejected("INSERT INTO t (id, a, b) VALUES (4, 10, 'x')");
        await ok("INSERT INTO t (id, a, b) VALUES (4, 10, 'z')");
        expect(await idsVia('t', 'idx_t_b', 'b', 'z'), [4]);
      });
    });
  }

  test('an index created inside the transaction is rolled back', () async {
    await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, b TEXT)');
    await ok('BEGIN');
    await ok('CREATE INDEX idx_t_b ON t (b)');
    await ok('ROLLBACK');
    expect(db.indexNamesForTable('t'), isNot(contains('idx_t_b')));
  });

  test(
    'rolling back to the same savepoint twice restores it each time',
    () async {
      await ok('CREATE TABLE u (id INTEGER PRIMARY KEY, email TEXT UNIQUE)');
      await ok("INSERT INTO u (id, email) VALUES (1, 'a@x')");
      await ok('BEGIN');
      await ok('SAVEPOINT sp');
      await ok("INSERT INTO u (id, email) VALUES (2, 'b@x')");
      await ok('ROLLBACK TO SAVEPOINT sp');
      // A write after restoring must not leak into the savepoint's snapshot.
      await ok("INSERT INTO u (id, email) VALUES (2, 'b@x')");
      await ok('ROLLBACK TO SAVEPOINT sp');
      await ok("INSERT INTO u (id, email) VALUES (2, 'b@x')");
      await rejected("INSERT INTO u (id, email) VALUES (3, 'a@x')");
      await ok('ROLLBACK');
      await ok("INSERT INTO u (id, email) VALUES (2, 'b@x')");
      await rejected("INSERT INTO u (id, email) VALUES (3, 'a@x')");
    },
  );

  test(
    'a table dropped inside the transaction comes back with its indexes',
    () async {
      await ok('CREATE TABLE u (id INTEGER PRIMARY KEY, email TEXT UNIQUE)');
      await ok("INSERT INTO u (id, email) VALUES (1, 'a@x')");
      await ok('CREATE INDEX idx_u_email ON u (email)');
      await ok('BEGIN');
      await ok('DROP TABLE u');
      await ok('ROLLBACK');

      expect(db.indexNamesForTable('u'), contains('idx_u_email'));
      await rejected("INSERT INTO u (id, email) VALUES (2, 'a@x')");
      await rejected("INSERT INTO u (id, email) VALUES (1, 'b@x')");
      await ok("INSERT INTO u (id, email) VALUES (2, 'b@x')");
    },
  );

  test('indexes loaded from JSON survive ROLLBACK', () async {
    // 2.0: Table.toJson/fromJson and auto-indexes are gone; the JSON comes
    // from exportJson() and is loaded with importJson().
    final source = await openMemory('rb_src');
    await ok(
      'CREATE TABLE u (id INTEGER PRIMARY KEY, email TEXT UNIQUE, name TEXT)',
      source,
    );
    await ok(
      "INSERT INTO u (id, email, name) VALUES (1, 'a@x', 'Ann')",
      source,
    );
    await ok('CREATE INDEX idx_u_name ON u (name)', source);
    await db.importJson(await source.exportJson());

    await ok('BEGIN');
    await ok("INSERT INTO u (id, email, name) VALUES (2, 'b@x', 'Bob')");
    await ok('ROLLBACK');

    expect(db.indexNamesForTable('u'), contains('idx_u_name'));
    expect(await idsVia('u', 'idx_u_name', 'name', 'Ann'), [1]);
    expect(await idsVia('u', 'idx_u_name', 'name', 'Bob'), isEmpty);
    await rejected("INSERT INTO u (id, email, name) VALUES (2, 'a@x', 'X')");
    await rejected("INSERT INTO u (id, email, name) VALUES (1, 'c@x', 'X')");
  });

  test('clone() is independent of the original table', () async {
    // 2.0: Table.clone() is gone (rollback uses an undo log); a copy is an
    // export imported into another database.
    await ok('CREATE TABLE u (id INTEGER PRIMARY KEY, email TEXT UNIQUE)');
    await ok("INSERT INTO u (id, email) VALUES (1, 'a@x')");
    final copy = await openMemory('rb_copy');
    await copy.importJson(await db.exportJson());

    await rejected("INSERT INTO u (id, email) VALUES (2, 'a@x')", copy);
    await rejected("INSERT INTO u (id, email) VALUES (1, 'b@x')", copy);
    await ok("INSERT INTO u (id, email) VALUES (2, 'b@x')", copy);
    expect(await rows(copy, 'SELECT email FROM u WHERE id = 2'), [
      {'email': 'b@x'},
    ]);
    // The original did not see the copy's insert.
    await ok("INSERT INTO u (id, email) VALUES (2, 'b@x')");
    expect(db.rowCount('u'), 2);
  });
}

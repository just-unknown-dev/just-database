import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';

/// Regression tests: ROLLBACK and ROLLBACK TO SAVEPOINT must restore every
/// index (definition and contents), so UNIQUE and PRIMARY KEY constraints keep
/// being enforced and explicit indexes survive.
void main() {
  late Map<String, Table> tables;
  late Executor executor;

  setUp(() {
    tables = {};
    executor = Executor(tables);
  });

  Future<QueryResult> sql(String statement) => executor.executeSQL(statement);

  Future<void> ok(String statement) async {
    final r = await sql(statement);
    expect(r.success, isTrue, reason: '$statement → ${r.errorMessage}');
  }

  /// The `id` values of the rows an index on [column] maps [value] to.
  List<Object?> idsVia(String table, String column, Object value) {
    final t = tables[table]!;
    return t
        .getIndexForColumns([column])!
        .lookup(value)
        .map((rowId) => t.getByRowId(rowId)!.values['id'])
        .toList();
  }

  Future<void> rejected(String statement) async {
    final r = await sql(statement);
    expect(r.success, isFalse, reason: '$statement should have been rejected');
    expect(r.errorMessage, contains('UNIQUE constraint'));
  }

  /// Runs [rollback] after a write inside a transaction, in each of the ways
  /// the executor restores a snapshot.
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
        expect(tables['u']!.getByPrimaryKey(1)?.values['email'], 'a@x');
        expect(tables['u']!.getByPrimaryKey(2)?.values['email'], 'c@x');
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

        final table = tables['t']!;
        expect(table.indexNames, containsAll(['idx_t_b', 'idx_t_ab']));
        expect(idsVia('t', 'b', 'x'), [1]);
        expect(idsVia('t', 'b', 'y'), [2]);
        await rejected("INSERT INTO t (id, a, b) VALUES (4, 10, 'x')");
        await ok("INSERT INTO t (id, a, b) VALUES (4, 10, 'z')");
        expect(idsVia('t', 'b', 'z'), [4]);
      });
    });
  }

  test('an index created inside the transaction is rolled back', () async {
    await ok('CREATE TABLE t (id INTEGER PRIMARY KEY, b TEXT)');
    await ok('BEGIN');
    await ok('CREATE INDEX idx_t_b ON t (b)');
    await ok('ROLLBACK');
    expect(tables['t']!.indexNames, isNot(contains('idx_t_b')));
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

      expect(tables['u']!.indexNames, contains('idx_u_email'));
      await rejected("INSERT INTO u (id, email) VALUES (2, 'a@x')");
      await rejected("INSERT INTO u (id, email) VALUES (1, 'b@x')");
      await ok("INSERT INTO u (id, email) VALUES (2, 'b@x')");
    },
  );

  test('indexes loaded from JSON survive ROLLBACK', () async {
    final source = <String, Table>{};
    await Executor(source).executeSQL(
      'CREATE TABLE u (id INTEGER PRIMARY KEY, email TEXT UNIQUE, name TEXT)',
    );
    final original = source['u']!
      ..insert({'id': 1, 'email': 'a@x', 'name': 'Ann'})
      ..createAutoIndex('name');
    tables['u'] = Table.fromJson(original.toJson());

    await ok('BEGIN');
    await ok("INSERT INTO u (id, email, name) VALUES (2, 'b@x', 'Bob')");
    await ok('ROLLBACK');

    final table = tables['u']!;
    expect(table.indexNames, contains('name'));
    expect(idsVia('u', 'name', 'Ann'), [1]);
    expect(idsVia('u', 'name', 'Bob'), isEmpty);
    await rejected("INSERT INTO u (id, email, name) VALUES (2, 'a@x', 'X')");
    await rejected("INSERT INTO u (id, email, name) VALUES (1, 'c@x', 'X')");
  });

  test('clone() is independent of the original table', () async {
    await ok('CREATE TABLE u (id INTEGER PRIMARY KEY, email TEXT UNIQUE)');
    await ok("INSERT INTO u (id, email) VALUES (1, 'a@x')");
    final copy = tables['u']!.clone();

    expect(copy.insert({'id': 2, 'email': 'a@x'}).success, isFalse);
    expect(copy.insert({'id': 1, 'email': 'b@x'}).success, isFalse);
    expect(copy.insert({'id': 2, 'email': 'b@x'}).success, isTrue);
    expect(copy.getByPrimaryKey(2)?.values['email'], 'b@x');
    // The original did not see the copy's insert.
    await ok("INSERT INTO u (id, email) VALUES (2, 'b@x')");
    expect(tables['u']!.rowCount, 2);
  });
}

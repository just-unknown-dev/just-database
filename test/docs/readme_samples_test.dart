// The README's code samples, run as written (keep them in sync).
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';

import '../helpers/temp_paths.dart';

class User extends DbRecord {
  const User({super.id, required this.name, this.active = true});
  final String name;
  final bool active;

  @override
  Map<String, Object?> toMap() => {'name': name, 'active': active};
}

class Users extends DbTable<User> {
  @override
  String get tableName => 'users';

  @override
  List<DbColumn> get columns => [
    DbColumn.text('name', notNull: true),
    DbColumn.boolean('active', defaultValue: true),
  ];

  @override
  User fromRow(Map<String, Object?> row) => User(
    id: row.intValue('id'),
    name: row.stringValue('name')!,
    active: row.boolValue('active') ?? true,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late TempPaths paths;
  setUp(() async => paths = await TempPaths.install());
  tearDown(() async {
    for (final db in JustDatabase.openDatabases) {
      await db.closeAll();
    }
    await paths.dispose();
  });

  test('quick start', () async {
    final db = await JustDatabase.open('app');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT UNIQUE,
        joined DATETIME DEFAULT CURRENT_TIMESTAMP
      )''');
    final added = await db.execute(
      'INSERT INTO users (name, email) VALUES (?, ?)',
      ["Ann O'Brien", 'ann@example.com'],
    );
    expect(added.lastInsertRowId, 1);
    final result = await db.query(
      'SELECT id, name FROM users WHERE email = :email',
      {'email': 'ann@example.com'},
    );
    expect(result.rows, [
      {'id': 1, 'name': "Ann O'Brien"},
    ]);
    final joined =
        (await db.query('SELECT joined FROM users')).scalar as String;
    expect(
      RegExp(r'^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d$').hasMatch(joined),
      isTrue,
    );
    await db.close();
  });

  test('transactions', () async {
    final db = await JustDatabase.open('bank', persist: false);
    await db.execute(
      'CREATE TABLE accounts (id INTEGER PRIMARY KEY, balance INTEGER)',
    );
    await db.execute('INSERT INTO accounts VALUES (1, 500), (2, 0)');
    await db.transaction((tx) async {
      await tx.execute(
        'UPDATE accounts SET balance = balance - ? WHERE id = ?',
        [100, 1],
      );
      await tx.execute(
        'UPDATE accounts SET balance = balance + ? WHERE id = ?',
        [100, 2],
      );
    });
    expect(
      (await db.query('SELECT balance FROM accounts ORDER BY id')).values,
      [
        [400],
        [100],
      ],
    );
    await db.close();
  });

  test('spatial', () async {
    final db = await JustDatabase.open('geo', persist: false);
    await db.execute('CREATE TABLE places (name TEXT, lng REAL, lat REAL)');
    await db.execute('CREATE SPATIAL INDEX places_pos ON places (lng, lat)');
    await db.execute(
      "INSERT INTO places VALUES ('Louvre', 2.3376, 48.8606), ('Rome', 12.4964, 41.9028)",
    );
    final near = await db.query(
      'SELECT name FROM places '
      'WHERE ST_WITHIN(ST_MAKEPOINT(lng, lat), ST_MAKEENVELOPE(?, ?, ?, ?))',
      [2.2, 48.8, 2.5, 48.9],
    );
    expect(near.values, [
      ['Louvre'],
    ]);
    final km =
        (await db.query(
              "SELECT ST_DISTANCE_SPHERE(ST_MAKEPOINT(2.3376, 48.8606), ST_MAKEPOINT(12.4964, 41.9028)) / 1000",
            )).scalar
            as double;
    expect(km, closeTo(1105, 10));
    await db.close();
  });

  test('migrations', () async {
    final db = await JustDatabase.open('mig', persist: false);
    final results = await db.migrate([
      SqlMigration(
        version: 1,
        name: 'create users',
        upSql: 'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)',
        downSql: 'DROP TABLE users',
      ),
      CallbackMigration(
        version: 2,
        name: 'add email',
        upCallback: (tx) =>
            tx.execute('ALTER TABLE users ADD COLUMN email TEXT'),
      ),
    ]);
    expect(results.every((r) => r.status == MigrationStatus.applied), isTrue);
    expect(db.getTableSchema('users')!.columns.map((c) => c.name), [
      'id',
      'name',
      'email',
    ]);
    await db.close();
  });

  test('backup and restore', () async {
    final db = await JustDatabase.open('src', persist: false);
    await db.execute('CREATE TABLE t (v)');
    await db.execute("INSERT INTO t VALUES (1), ('two'), (X'03')");
    final other = await JustDatabase.open('dst', persist: false);
    final sql = await db.exportSql();
    final json = await db.exportJson();
    await other.importSql(sql);
    expect(other.rowCount('t'), 3);
    await other.importJson(json);
    expect(other.rowCount('t'), 3);
    await db.close();
    await other.close();
  });

  test('ORM', () async {
    final db = await JustDatabase.open('orm', persist: false);
    final users = Users();
    await users.createTable(db);
    final ann = await users.insert(db, const User(name: 'Ann'));
    expect(ann.id, 1);
    await users.insert(db, const User(name: 'Bob', active: false));
    final active = await users.findAll(
      db,
      where: 'active = ?',
      whereArgs: [true],
    );
    expect(active.map((u) => u.name), ['Ann']);
    await db.close();
  });

  test('query builder', () async {
    final db = await JustDatabase.open('qb', persist: false);
    await db.execute('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)');
    for (var i = 1; i <= 60; i++) {
      await db.execute('INSERT INTO users (name) VALUES (?)', ['A$i']);
    }
    final page = await db
        .from('users')
        .select(['id', 'name'])
        .where('name LIKE ?', ['A%'])
        .orderBy('name')
        .limit(20)
        .offset(40)
        .get();
    expect(page.rowCount, 20);
    await db.from('users').whereEquals('id', 3).update({'name': 'Bo'});
    expect(
      (await db.query('SELECT name FROM users WHERE id = 3')).scalar,
      'Bo',
    );
    await db.close();
  });

  test('benchmarks', () async {
    final db = await JustDatabase.open('bench', persist: false);
    await db.execute('CREATE TABLE users (name TEXT)');
    final suite = await db.runStandardBenchmark(
      rowCount: 100,
      warmup: 1,
      iterations: 3,
    );
    expect(suite.results, isNotEmpty);
    final stats = await db.benchmarkQuery(
      'by name',
      'SELECT * FROM users WHERE name = ?',
      parameters: ['Ann'],
      iterations: 3,
    );
    expect(stats.iterations, 3);
    await db.close();
  });
}

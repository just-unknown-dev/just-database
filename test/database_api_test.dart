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

/// Opens a fresh in-memory database with a unique name.
Future<JustDatabase> _openDb() => JustDatabase.open(
  'api_test_${DateTime.now().microsecondsSinceEpoch}_${_dbCounter++}',
  persist: false,
);

Future<void> _exec(JustDatabase db, String sql) async {
  final result = await db.execute(sql);
  expect(result.success, isTrue, reason: '$sql\n→ ${result.errorMessage}');
}

Future<List<Map<String, dynamic>>> _rows(JustDatabase db, String sql) async {
  final result = await db.query(sql);
  expect(result.success, isTrue, reason: '$sql\n→ ${result.errorMessage}');
  return result.rows;
}

List<Migration> _usersMigrations() => [
  // Deliberately out of order: the runner sorts by version.
  CallbackMigration(
    version: 2,
    name: 'seed_admin',
    upCallback: (executor) async {
      final result = await executor.executeSQL(
        "INSERT INTO users (name) VALUES ('Admin')",
      );
      if (!result.success) throw StateError(result.errorMessage!);
    },
    downCallback: (executor) async {
      await executor.executeSQL("DELETE FROM users WHERE name = 'Admin'");
    },
  ),
  SqlMigration(
    version: 1,
    name: 'create_users',
    upSql:
        'CREATE TABLE users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)',
    downSql: 'DROP TABLE users',
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;

  setUpAll(() async {
    docsDir = await Directory.systemTemp.createTemp('just_database_api_');
    PathProviderPlatform.instance = _TempDirPathProvider(docsDir.path);
  });

  tearDownAll(() async {
    if (await docsDir.exists()) await docsDir.delete(recursive: true);
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Migrations on an opened database
  // ───────────────────────────────────────────────────────────────────────────
  group('JustDatabase.migrate', () {
    late JustDatabase db;

    setUp(() async => db = await _openDb());
    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    test('applies pending migrations in version order', () async {
      final results = await db.migrate(_usersMigrations());

      expect(results.map((r) => r.version), [1, 2]);
      expect(results.every((r) => r.status == MigrationStatus.applied), isTrue);
      expect(await _rows(db, 'SELECT name FROM users'), [
        {'name': 'Admin'},
      ]);
    });

    test('skips migrations that were already applied', () async {
      await db.migrate(_usersMigrations());
      final again = await db.migrate(_usersMigrations());

      expect(again.every((r) => r.status == MigrationStatus.skipped), isTrue);
      expect(await _rows(db, 'SELECT name FROM users'), hasLength(1));
    });

    test('stops at targetVersion', () async {
      await db.migrate(_usersMigrations(), targetVersion: 1);

      expect(await _rows(db, 'SELECT * FROM users'), isEmpty);
      expect(await db.migrationRunner(_usersMigrations()).currentVersion(), 1);
    });

    test('migrationRunner supports status and rollback', () async {
      final runner = db.migrationRunner(_usersMigrations());
      await runner.migrate();

      expect(await runner.currentVersion(), 2);
      final rolledBack = await runner.rollback(targetVersion: 1);
      expect(rolledBack.single.version, 2);
      expect(await runner.currentVersion(), 1);
      expect(await _rows(db, 'SELECT * FROM users'), isEmpty);

      final status = await runner.status();
      expect(status.map((s) => (s.version, s.status)), [
        (1, MigrationStatus.applied),
        (2, MigrationStatus.pending),
      ]);
    });

    test('a failed migration stops the run and is reported', () async {
      final results = await db.migrate([
        SqlMigration(
          version: 1,
          name: 'ok',
          upSql: 'CREATE TABLE a (id INTEGER PRIMARY KEY)',
        ),
        SqlMigration(
          version: 2,
          name: 'broken',
          upSql: 'INSERT INTO missing_table (id) VALUES (1)',
        ),
        SqlMigration(
          version: 3,
          name: 'never_reached',
          upSql: 'CREATE TABLE c (id INTEGER PRIMARY KEY)',
        ),
      ]);

      expect(results.map((r) => r.status), [
        MigrationStatus.applied,
        MigrationStatus.failed,
      ]);
      expect(db.tableNames, isNot(contains('c')));
    });

    test('callbacks can use the database itself without deadlocking', () async {
      final results = await db.migrate([
        SqlMigration(
          version: 1,
          name: 'create_users',
          upSql: 'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)',
        ),
        CallbackMigration(
          version: 2,
          name: 'view_and_transaction',
          upCallback: (_) async {
            await _exec(db, 'CREATE VIEW user_names AS SELECT name FROM users');
            await db.transaction((tx) async {
              await _exec(tx, "INSERT INTO users (id, name) VALUES (1, 'A')");
            });
          },
        ),
      ]).timeout(const Duration(seconds: 5));

      expect(results.last.status, MigrationStatus.applied);
      expect(await _rows(db, 'SELECT * FROM user_names'), [
        {'name': 'A'},
      ]);
    });

    test('throws once the database is closed', () async {
      await db.close();
      expect(() => db.migrate(_usersMigrations()), throwsStateError);
    });

    test('migrations are saved for persistent databases', () async {
      final name = 'api_migrate_persist_${DateTime.now().microsecondsSinceEpoch}';
      final first = await JustDatabase.open(name);
      await first.migrate(_usersMigrations());
      // Reopen without close(): migrate() must have saved on its own.
      final second = await JustDatabase.open(name);
      addTearDown(() => PersistenceManager.delete(name));

      expect(await second.migrationRunner(_usersMigrations()).currentVersion(), 2);
      expect(await _rows(second, 'SELECT name FROM users'), [
        {'name': 'Admin'},
      ]);
      final again = await second.migrate(_usersMigrations());
      expect(again.every((r) => r.status == MigrationStatus.skipped), isTrue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Async introspection (same API as on web)
  // ───────────────────────────────────────────────────────────────────────────
  group('Async introspection', () {
    test('matches the sync getters', () async {
      final db = await _openDb();
      await _exec(db, 'CREATE TABLE items (id INTEGER PRIMARY KEY, sku TEXT)');
      await _exec(db, 'CREATE INDEX idx_items_sku ON items (sku)');
      await _exec(db, 'CREATE VIEW item_skus AS SELECT sku FROM items');
      await _exec(
        db,
        'CREATE TRIGGER trg_items AFTER INSERT ON items BEGIN '
        "UPDATE items SET sku = 'x' WHERE id = NEW.id; END",
      );
      await _exec(db, "INSERT INTO items (id, sku) VALUES (1, 'a')");

      expect(await db.tableNamesAsync(), db.tableNames);
      expect(await db.viewNamesAsync(), db.viewNames);
      expect(await db.triggerNamesAsync(), db.triggerNames);
      expect(
        await db.indexNamesForTableAsync('items'),
        db.indexNamesForTable('items'),
      );
      expect(await db.indexNamesForTableAsync('items'), contains('idx_items_sku'));
      expect(
        (await db.getTableSchemaAsync('items'))?.tableName,
        db.getTableSchema('items')?.tableName,
      );
      expect(await db.getTableSchemaAsync('nope'), isNull);
      expect(await db.totalRowsAsync(), 1);
      expect(await db.estimatedSizeBytesAsync(), db.estimatedSizeBytes);
    });

    test('onStorageDowngrade can be set and is never called on native', () async {
      var calls = 0;
      JustDatabase.onStorageDowngrade = (_, _) => calls++;
      addTearDown(() => JustDatabase.onStorageDowngrade = null);

      final name = 'api_downgrade_${DateTime.now().microsecondsSinceEpoch}';
      final db = await JustDatabase.open(name);
      addTearDown(() => PersistenceManager.delete(name));
      await db.close();

      expect(calls, 0);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // FOREIGN KEY ... ON DELETE / ON UPDATE
  // ───────────────────────────────────────────────────────────────────────────
  group('Foreign key actions — parsing', () {
    ForeignKeyConstraintNode tableFk(String sql) =>
        (Parser.parseSQL(sql) as CreateTableStatement).foreignKeys.single;

    ColumnDefinitionNode column(String sql, String name) =>
        (Parser.parseSQL(sql) as CreateTableStatement).columns.firstWhere(
          (c) => c.name == name,
        );

    test('table-level FOREIGN KEY with ON DELETE CASCADE', () {
      final fk = tableFk(
        'CREATE TABLE items (id INTEGER PRIMARY KEY, invoiceId TEXT, '
        'FOREIGN KEY (invoiceId) REFERENCES invoices (invoiceId) '
        'ON DELETE CASCADE)',
      );
      expect(fk.referencedTable, 'invoices');
      expect(fk.onDelete, ForeignKeyAction.cascade);
      expect(fk.onUpdate, ForeignKeyAction.noAction);
    });

    test('column-level REFERENCES with both clauses in either order', () {
      final a = column(
        'CREATE TABLE c (id INTEGER, p INTEGER REFERENCES p (id) '
        'ON DELETE SET NULL ON UPDATE CASCADE NOT NULL)',
        'p',
      );
      expect(a.onDelete, ForeignKeyAction.setNull);
      expect(a.onUpdate, ForeignKeyAction.cascade);
      expect(a.notNull, isTrue);

      final b = column(
        'CREATE TABLE c (p INTEGER REFERENCES p ON UPDATE RESTRICT '
        'ON DELETE SET DEFAULT)',
        'p',
      );
      expect(b.foreignKeyColumn, isNull);
      expect(b.onDelete, ForeignKeyAction.setDefault);
      expect(b.onUpdate, ForeignKeyAction.restrict);
    });

    test('NO ACTION and lower-case keywords', () {
      final fk = tableFk(
        'create table c (p integer, foreign key (p) references p (id) '
        'on delete no action on update cascade)',
      );
      expect(fk.onDelete, ForeignKeyAction.noAction);
      expect(fk.onUpdate, ForeignKeyAction.cascade);
    });

    test('rejects unknown actions', () {
      expect(
        () => Parser.parseSQL(
          'CREATE TABLE c (p INTEGER REFERENCES p (id) ON DELETE EXPLODE)',
        ),
        throwsA(isA<ParseException>()),
      );
      expect(
        () => Parser.parseSQL(
          'CREATE TABLE c (p INTEGER REFERENCES p (id) ON INSERT CASCADE)',
        ),
        throwsA(isA<ParseException>()),
      );
    });
  });

  group('Foreign key actions — behaviour', () {
    late JustDatabase db;

    setUp(() async {
      db = await _openDb();
      await _exec(
        db,
        'CREATE TABLE invoices (id INTEGER PRIMARY KEY, invoiceId TEXT UNIQUE)',
      );
      await _exec(db, "INSERT INTO invoices VALUES (1, 'INV-1')");
      await _exec(db, "INSERT INTO invoices VALUES (2, 'INV-2')");
    });

    tearDown(() async {
      if (db.isOpen) await db.close();
    });

    Future<void> addItems(String fkClause) async {
      await _exec(
        db,
        'CREATE TABLE invoice_items (id INTEGER PRIMARY KEY, '
        'invoiceId TEXT, description TEXT, '
        'FOREIGN KEY (invoiceId) REFERENCES invoices (invoiceId) $fkClause)',
      );
      await _exec(db, "INSERT INTO invoice_items VALUES (1, 'INV-1', 'a')");
      await _exec(db, "INSERT INTO invoice_items VALUES (2, 'INV-1', 'b')");
      await _exec(db, "INSERT INTO invoice_items VALUES (3, 'INV-2', 'c')");
    }

    test('ON DELETE CASCADE removes the child rows', () async {
      await addItems('ON DELETE CASCADE');

      final result = await db.execute(
        "DELETE FROM invoices WHERE invoiceId = 'INV-1'",
      );

      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.affectedRows, 1, reason: 'only the parent row counts');
      expect(await _rows(db, 'SELECT id FROM invoice_items'), [
        {'id': 3},
      ]);
    });

    test('column-level REFERENCES ... ON DELETE CASCADE', () async {
      await _exec(
        db,
        'CREATE TABLE notes (id INTEGER PRIMARY KEY, '
        'invoice INTEGER REFERENCES invoices (id) ON DELETE CASCADE)',
      );
      await _exec(db, 'INSERT INTO notes VALUES (1, 1)');
      await _exec(db, 'INSERT INTO notes VALUES (2, 2)');

      await _exec(db, 'DELETE FROM invoices WHERE id = 2');

      expect(await _rows(db, 'SELECT id FROM notes'), [
        {'id': 1},
      ]);
    });

    test('REFERENCES without a column uses the primary key', () async {
      await _exec(
        db,
        'CREATE TABLE notes (id INTEGER PRIMARY KEY, '
        'invoice INTEGER REFERENCES invoices ON DELETE CASCADE)',
      );
      await _exec(db, 'INSERT INTO notes VALUES (1, 1)');

      await _exec(db, 'DELETE FROM invoices WHERE id = 1');

      expect(await _rows(db, 'SELECT * FROM notes'), isEmpty);
    });

    test('cascades through several levels', () async {
      await addItems('ON DELETE CASCADE');
      await _exec(
        db,
        'CREATE TABLE item_tags (id INTEGER PRIMARY KEY, item INTEGER, '
        'FOREIGN KEY (item) REFERENCES invoice_items (id) ON DELETE CASCADE)',
      );
      await _exec(db, 'INSERT INTO item_tags VALUES (1, 1)');
      await _exec(db, 'INSERT INTO item_tags VALUES (2, 3)');

      await _exec(db, "DELETE FROM invoices WHERE invoiceId = 'INV-1'");

      expect(await _rows(db, 'SELECT id FROM item_tags'), [
        {'id': 2},
      ]);
    });

    test('self-referencing cascade deletes a whole subtree', () async {
      await _exec(
        db,
        'CREATE TABLE categories (id INTEGER PRIMARY KEY, parent INTEGER, '
        'FOREIGN KEY (parent) REFERENCES categories (id) ON DELETE CASCADE)',
      );
      for (final (id, parent) in [(1, null), (2, 1), (3, 2), (4, null)]) {
        await _exec(db, 'INSERT INTO categories VALUES ($id, ${parent ?? 'NULL'})');
      }

      await _exec(db, 'DELETE FROM categories WHERE id = 1');

      expect(await _rows(db, 'SELECT id FROM categories'), [
        {'id': 4},
      ]);
    });

    test('cascaded deletes fire the child table\'s DELETE triggers', () async {
      await addItems('ON DELETE CASCADE');
      await _exec(db, 'CREATE TABLE removed (description TEXT)');
      await _exec(
        db,
        'CREATE TRIGGER trg_removed AFTER DELETE ON invoice_items BEGIN '
        'INSERT INTO removed (description) VALUES (OLD.description); END',
      );

      await _exec(db, "DELETE FROM invoices WHERE invoiceId = 'INV-1'");

      final removed = await _rows(db, 'SELECT description FROM removed');
      expect(removed.map((r) => r['description']), unorderedEquals(['a', 'b']));
    });

    test('ON DELETE SET NULL clears the reference', () async {
      await addItems('ON DELETE SET NULL');

      await _exec(db, "DELETE FROM invoices WHERE invoiceId = 'INV-1'");

      expect(await _rows(db, 'SELECT id, invoiceId FROM invoice_items'), [
        {'id': 1, 'invoiceId': null},
        {'id': 2, 'invoiceId': null},
        {'id': 3, 'invoiceId': 'INV-2'},
      ]);
    });

    test('ON DELETE SET DEFAULT writes the column default', () async {
      await _exec(
        db,
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, invoiceId TEXT DEFAULT 'INV-2', "
        'FOREIGN KEY (invoiceId) REFERENCES invoices (invoiceId) '
        'ON DELETE SET DEFAULT)',
      );
      await _exec(db, "INSERT INTO notes VALUES (1, 'INV-1')");

      await _exec(db, "DELETE FROM invoices WHERE invoiceId = 'INV-1'");

      expect(await _rows(db, 'SELECT invoiceId FROM notes'), [
        {'invoiceId': 'INV-2'},
      ]);
    });

    test('SET NULL on a NOT NULL column fails and changes nothing', () async {
      await _exec(
        db,
        'CREATE TABLE notes (id INTEGER PRIMARY KEY, invoiceId TEXT NOT NULL, '
        'FOREIGN KEY (invoiceId) REFERENCES invoices (invoiceId) '
        'ON DELETE SET NULL)',
      );
      await _exec(db, "INSERT INTO notes VALUES (1, 'INV-1')");

      final result = await db.execute('DELETE FROM invoices');

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('NOT NULL'));
      expect(await _rows(db, 'SELECT * FROM invoices'), hasLength(2));
      expect(await _rows(db, 'SELECT invoiceId FROM notes'), [
        {'invoiceId': 'INV-1'},
      ]);
    });

    test('ON DELETE RESTRICT blocks the delete and changes nothing', () async {
      await addItems('ON DELETE RESTRICT');

      final result = await db.execute('DELETE FROM invoices');

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('FOREIGN KEY constraint failed'));
      expect(await _rows(db, 'SELECT * FROM invoices'), hasLength(2));
      expect(await _rows(db, 'SELECT * FROM invoice_items'), hasLength(3));
    });

    test('RESTRICT deeper in a cascade blocks the whole delete', () async {
      await addItems('ON DELETE CASCADE');
      await _exec(
        db,
        'CREATE TABLE payments (id INTEGER PRIMARY KEY, item INTEGER, '
        'FOREIGN KEY (item) REFERENCES invoice_items (id) ON DELETE RESTRICT)',
      );
      await _exec(db, 'INSERT INTO payments VALUES (1, 2)');

      final result = await db.execute("DELETE FROM invoices WHERE id = 1");

      expect(result.success, isFalse);
      expect(await _rows(db, 'SELECT * FROM invoices'), hasLength(2));
      expect(await _rows(db, 'SELECT * FROM invoice_items'), hasLength(3));
    });

    test('RESTRICT allows deleting a parent without children', () async {
      await addItems('ON DELETE RESTRICT');
      await _exec(db, "INSERT INTO invoices VALUES (3, 'INV-3')");

      await _exec(db, 'DELETE FROM invoices WHERE id = 3');

      expect(await _rows(db, 'SELECT * FROM invoices'), hasLength(2));
    });

    test('without an action, child rows are left alone', () async {
      await addItems('');

      await _exec(db, "DELETE FROM invoices WHERE invoiceId = 'INV-1'");

      expect(await _rows(db, 'SELECT * FROM invoice_items'), hasLength(3));
    });

    test('ON UPDATE CASCADE follows a changed key', () async {
      await addItems('ON UPDATE CASCADE');

      await _exec(
        db,
        "UPDATE invoices SET invoiceId = 'INV-1A' WHERE invoiceId = 'INV-1'",
      );

      expect(await _rows(db, 'SELECT invoiceId FROM invoice_items'), [
        {'invoiceId': 'INV-1A'},
        {'invoiceId': 'INV-1A'},
        {'invoiceId': 'INV-2'},
      ]);
    });

    test('ON UPDATE SET NULL clears the reference', () async {
      await addItems('ON UPDATE SET NULL');

      await _exec(db, "UPDATE invoices SET invoiceId = 'X' WHERE id = 2");

      expect(await _rows(db, 'SELECT invoiceId FROM invoice_items WHERE id = 3'), [
        {'invoiceId': null},
      ]);
    });

    test('ON UPDATE RESTRICT blocks the update and changes nothing', () async {
      await addItems('ON UPDATE RESTRICT');
      // INV-1 is now free to change; INV-2 still has a child.
      await _exec(db, "DELETE FROM invoice_items WHERE invoiceId = 'INV-1'");

      final result = await db.execute(
        "UPDATE invoices SET invoiceId = CONCAT(invoiceId, '-X')",
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('ON UPDATE RESTRICT'));
      expect(await _rows(db, 'SELECT invoiceId FROM invoices'), [
        {'invoiceId': 'INV-1'},
        {'invoiceId': 'INV-2'},
      ]);
    });

    test('updating other columns does not trigger ON UPDATE', () async {
      await addItems('ON UPDATE RESTRICT');

      await _exec(db, 'UPDATE invoices SET id = id + 10');

      expect(await _rows(db, 'SELECT id FROM invoices'), [
        {'id': 11},
        {'id': 12},
      ]);
    });

    test('ROLLBACK restores cascaded rows', () async {
      await addItems('ON DELETE CASCADE');

      await db.beginTransaction();
      await _exec(db, 'DELETE FROM invoices');
      expect(await _rows(db, 'SELECT * FROM invoice_items'), isEmpty);
      await db.rollback();

      expect(await _rows(db, 'SELECT * FROM invoice_items'), hasLength(3));
    });

    test('composite foreign keys reject actions', () async {
      final result = await db.execute(
        'CREATE TABLE c (a INTEGER, b INTEGER, '
        'FOREIGN KEY (a, b) REFERENCES invoices (id, invoiceId) '
        'ON DELETE CASCADE)',
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('single-column'));
    });

    test('actions survive a save and reopen', () async {
      final name = 'api_fk_persist_${DateTime.now().microsecondsSinceEpoch}';
      final first = await JustDatabase.open(name);
      addTearDown(() => PersistenceManager.delete(name));
      // One migration means one awaited save. Separate execute() calls each
      // start an unawaited save, and those can overlap and clobber the file.
      final results = await first.migrate([
        SqlMigration(
          version: 1,
          name: 'schema',
          upSql: '''
            CREATE TABLE p (id INTEGER PRIMARY KEY);
            CREATE TABLE c (id INTEGER PRIMARY KEY, p INTEGER
              REFERENCES p (id) ON DELETE CASCADE ON UPDATE SET NULL);
            INSERT INTO p VALUES (1);
            INSERT INTO c VALUES (1, 1);
          ''',
        ),
      ]);
      expect(results.single.status, MigrationStatus.applied);
      await first.close();

      final second = await JustDatabase.open(name);
      final constraints = second.getTableSchema('c')!.getColumn('p')!.constraints;
      expect(constraints.onDelete, ForeignKeyAction.cascade);
      expect(constraints.onUpdate, ForeignKeyAction.setNull);

      await _exec(second, 'DELETE FROM p');
      expect(await _rows(second, 'SELECT * FROM c'), isEmpty);
      await second.close();
    });
  });

  group('Foreign key actions — backups', () {
    Future<Map<String, Table>> sourceTables() async {
      final tables = <String, Table>{};
      final executor = Executor(tables);
      for (final sql in [
        'CREATE TABLE p (id INTEGER PRIMARY KEY)',
        'CREATE TABLE c (id INTEGER PRIMARY KEY, p INTEGER, '
            'FOREIGN KEY (p) REFERENCES p (id) '
            'ON DELETE CASCADE ON UPDATE RESTRICT)',
      ]) {
        final result = await executor.executeSQL(sql);
        expect(result.success, isTrue, reason: result.errorMessage);
      }
      return tables;
    }

    void expectActions(Map<String, Table> tables) {
      final constraints = tables['c']!.schema.getColumn('p')!.constraints;
      expect(constraints.onDelete, ForeignKeyAction.cascade);
      expect(constraints.onUpdate, ForeignKeyAction.restrict);
    }

    test('SQL dump writes and restores the actions', () async {
      final sql = BackupManager.exportSql(await sourceTables());
      expect(sql, contains('ON DELETE CASCADE ON UPDATE RESTRICT'));

      final restored = <String, Table>{};
      await BackupManager.importSql(sql, restored);
      expectActions(restored);
    });

    test('JSON backup writes and restores the actions', () async {
      final json = BackupManager.exportJson(await sourceTables());

      final restored = <String, Table>{};
      BackupManager.importJson(json, restored);
      expectActions(restored);
    });

    test('schema JSON round-trips the actions and omits them when unset', () {
      const constraints = ConstraintDefinition(
        foreignKeyTable: 'p',
        onDelete: ForeignKeyAction.setDefault,
      );
      final json = constraints.toJson();
      expect(json['onDelete'], 'setDefault');
      expect(json.containsKey('onUpdate'), isFalse);

      final back = ConstraintDefinition.fromJson(json);
      expect(back.onDelete, ForeignKeyAction.setDefault);
      expect(back.onUpdate, ForeignKeyAction.noAction);
    });
  });
}

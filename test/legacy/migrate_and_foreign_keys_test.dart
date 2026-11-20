// Ported from the 1.x test/database_api_test.dart: migrations on an opened
// database, async introspection and foreign key actions.
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';

import '../helpers/temp_paths.dart';
import 'legacy_helpers.dart';

List<Migration> _usersMigrations() => [
  // Deliberately out of order: the runner sorts by version.
  CallbackMigration(
    version: 2,
    name: 'seed_admin',
    upCallback: (tx) async {
      await tx.execute("INSERT INTO users (name) VALUES ('Admin')");
    },
    downCallback: (tx) async {
      await tx.execute("DELETE FROM users WHERE name = 'Admin'");
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
  late TempPaths paths;

  setUp(() async {
    paths = await TempPaths.install();
  });

  tearDown(() async {
    await closeAllOpen();
    await paths.dispose();
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Migrations on an opened database
  // ───────────────────────────────────────────────────────────────────────────
  group('JustDatabase.migrate', () {
    late JustDatabase db;

    setUp(() async => db = await openMemory('api'));

    test('applies pending migrations in version order', () async {
      final results = await db.migrate(_usersMigrations());

      expect(results.map((r) => r.version), [1, 2]);
      expect(results.every((r) => r.status == MigrationStatus.applied), isTrue);
      expect(await rows(db, 'SELECT name FROM users'), [
        {'name': 'Admin'},
      ]);
    });

    test('skips migrations that were already applied', () async {
      await db.migrate(_usersMigrations());
      final again = await db.migrate(_usersMigrations());

      // 2.0: migrate() returns a result only for the steps it ran; there is
      // no `skipped` status any more.
      expect(again, isEmpty);
      expect(await rows(db, 'SELECT name FROM users'), hasLength(1));
    });

    test('stops at targetVersion', () async {
      await db.migrate(_usersMigrations(), targetVersion: 1);

      expect(await rows(db, 'SELECT * FROM users'), isEmpty);
      expect(await db.migrationRunner(_usersMigrations()).currentVersion(), 1);
    });

    test('migrationRunner supports status and rollback', () async {
      final runner = db.migrationRunner(_usersMigrations());
      await runner.migrate();

      expect(await runner.currentVersion(), 2);
      final rolledBack = await runner.rollback(targetVersion: 1);
      expect(rolledBack.single.version, 2);
      expect(rolledBack.single.status, MigrationStatus.rolledBack);
      expect(await runner.currentVersion(), 1);
      expect(await rows(db, 'SELECT * FROM users'), isEmpty);

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
      final results = await db
          .migrate([
            SqlMigration(
              version: 1,
              name: 'create_users',
              upSql: 'CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)',
            ),
            CallbackMigration(
              version: 2,
              name: 'view_and_transaction',
              upCallback: (_) async {
                await exec(
                  db,
                  'CREATE VIEW user_names AS SELECT name FROM users',
                );
                await db.transaction((tx) async {
                  await tx.execute(
                    "INSERT INTO users (id, name) VALUES (1, 'A')",
                  );
                });
              },
            ),
          ])
          .timeout(const Duration(seconds: 5));

      expect(results.last.status, MigrationStatus.applied);
      expect(await rows(db, 'SELECT * FROM user_names'), [
        {'name': 'A'},
      ]);
    });

    test('throws once the database is closed', () async {
      await db.close();
      expect(() => db.migrate(_usersMigrations()), throwsStateError);
    });

    test('migrations are saved for persistent databases', () async {
      final name = uniqueName('api_migrate_persist');
      final first = await JustDatabase.open(name);
      await first.migrate(_usersMigrations());
      // migrate() must have saved on its own, without close().
      // 2.0: opening an open name returns the same instance, so read what
      // is on disk through a copy of the file instead.
      final copy = uniqueName('api_migrate_copy');
      paths.file(name).copySync(paths.file(copy).path);
      final second = await JustDatabase.open(copy);

      expect(
        await second.migrationRunner(_usersMigrations()).currentVersion(),
        2,
      );
      expect(await rows(second, 'SELECT name FROM users'), [
        {'name': 'Admin'},
      ]);
      final again = await second.migrate(_usersMigrations());
      // 2.0: nothing ran, so there are no results (no `skipped` status).
      expect(again, isEmpty);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  // Async introspection (same API as on web)
  // ───────────────────────────────────────────────────────────────────────────
  group('Async introspection', () {
    test('matches the sync getters', () async {
      final db = await openMemory('api');
      await exec(db, 'CREATE TABLE items (id INTEGER PRIMARY KEY, sku TEXT)');
      await exec(db, 'CREATE INDEX idx_items_sku ON items (sku)');
      await exec(db, 'CREATE VIEW item_skus AS SELECT sku FROM items');
      await exec(
        db,
        'CREATE TRIGGER trg_items AFTER INSERT ON items BEGIN '
        "UPDATE items SET sku = 'x' WHERE id = NEW.id; END",
      );
      await exec(db, "INSERT INTO items (id, sku) VALUES (1, 'a')");

      expect(await db.tableNamesAsync(), db.tableNames);
      expect(await db.viewNamesAsync(), db.viewNames);
      expect(await db.triggerNamesAsync(), db.triggerNames);
      expect(
        await db.indexNamesForTableAsync('items'),
        db.indexNamesForTable('items'),
      );
      expect(
        await db.indexNamesForTableAsync('items'),
        contains('idx_items_sku'),
      );
      expect(
        (await db.getTableSchemaAsync('items'))?.name,
        db.getTableSchema('items')?.name,
      );
      expect(await db.getTableSchemaAsync('nope'), isNull);
      expect(await db.totalRowsAsync(), 1);
      expect(await db.estimatedSizeBytesAsync(), db.estimatedSizeBytes);
    });

    test(
      'onStorageDowngrade can be set and is never called on native',
      () async {
        var calls = 0;
        JustDatabase.onStorageDowngrade = (_, _) => calls++;
        addTearDown(() => JustDatabase.onStorageDowngrade = null);

        final db = await JustDatabase.open(uniqueName('api_downgrade'));
        expect(db.persist, isTrue);
        await db.close();

        expect(calls, 0);
      },
    );
  });

  // ───────────────────────────────────────────────────────────────────────────
  // FOREIGN KEY ... ON DELETE / ON UPDATE
  // ───────────────────────────────────────────────────────────────────────────
  group('Foreign key actions — parsing', () {
    // 2.0: the parser and its AST are internal; the parsed actions are read
    // back through the public schema (column-level REFERENCES are stored as
    // table constraints).
    Future<TableSchema> schemaOf(String sql) async {
      final db = await openMemory('fk_parse');
      await exec(db, sql);
      return db.getTableSchema(db.tableNames.single)!;
    }

    test('table-level FOREIGN KEY with ON DELETE CASCADE', () async {
      final fk = (await schemaOf(
        'CREATE TABLE items (id INTEGER PRIMARY KEY, invoiceId TEXT, '
        'FOREIGN KEY (invoiceId) REFERENCES invoices (invoiceId) '
        'ON DELETE CASCADE)',
      )).foreignKeys.single;
      expect(fk.parentTable, 'invoices');
      expect(fk.onDelete, ForeignKeyAction.cascade);
      expect(fk.onUpdate, ForeignKeyAction.noAction);
    });

    test('column-level REFERENCES with both clauses in either order', () async {
      final a = await schemaOf(
        'CREATE TABLE c (id INTEGER, p INTEGER REFERENCES p (id) '
        'ON DELETE SET NULL ON UPDATE CASCADE NOT NULL)',
      );
      expect(a.foreignKeys.single.columns, ['p']);
      expect(a.foreignKeys.single.onDelete, ForeignKeyAction.setNull);
      expect(a.foreignKeys.single.onUpdate, ForeignKeyAction.cascade);
      expect(a.column('p')!.notNull, isTrue);

      final b = await schemaOf(
        'CREATE TABLE c (p INTEGER REFERENCES p ON UPDATE RESTRICT '
        'ON DELETE SET DEFAULT)',
      );
      expect(b.foreignKeys.single.parentColumns, isEmpty);
      expect(b.foreignKeys.single.onDelete, ForeignKeyAction.setDefault);
      expect(b.foreignKeys.single.onUpdate, ForeignKeyAction.restrict);
    });

    test('NO ACTION and lower-case keywords', () async {
      final fk = (await schemaOf(
        'create table c (p integer, foreign key (p) references p (id) '
        'on delete no action on update cascade)',
      )).foreignKeys.single;
      expect(fk.onDelete, ForeignKeyAction.noAction);
      expect(fk.onUpdate, ForeignKeyAction.cascade);
    });

    test('rejects unknown actions', () async {
      final db = await openMemory('fk_parse');
      final explode = await db.execute(
        'CREATE TABLE c (p INTEGER REFERENCES p (id) ON DELETE EXPLODE)',
      );
      expect(explode.success, isFalse);
      expect(explode.error!.kind, SqlErrorKind.syntax);
      final onInsert = await db.execute(
        'CREATE TABLE c (p INTEGER REFERENCES p (id) ON INSERT CASCADE)',
      );
      expect(onInsert.success, isFalse);
      expect(onInsert.error!.kind, SqlErrorKind.syntax);
      expect(db.tableNames, isEmpty);
    });
  });

  group('Foreign key actions — behaviour', () {
    late JustDatabase db;

    setUp(() async {
      db = await openMemory('fk');
      await exec(
        db,
        'CREATE TABLE invoices (id INTEGER PRIMARY KEY, invoiceId TEXT UNIQUE)',
      );
      await exec(db, "INSERT INTO invoices VALUES (1, 'INV-1')");
      await exec(db, "INSERT INTO invoices VALUES (2, 'INV-2')");
    });

    Future<void> addItems(String fkClause) async {
      await exec(
        db,
        'CREATE TABLE invoice_items (id INTEGER PRIMARY KEY, '
        'invoiceId TEXT, description TEXT, '
        'FOREIGN KEY (invoiceId) REFERENCES invoices (invoiceId) $fkClause)',
      );
      await exec(db, "INSERT INTO invoice_items VALUES (1, 'INV-1', 'a')");
      await exec(db, "INSERT INTO invoice_items VALUES (2, 'INV-1', 'b')");
      await exec(db, "INSERT INTO invoice_items VALUES (3, 'INV-2', 'c')");
    }

    test('ON DELETE CASCADE removes the child rows', () async {
      await addItems('ON DELETE CASCADE');

      final result = await db.execute(
        "DELETE FROM invoices WHERE invoiceId = 'INV-1'",
      );

      expect(result.success, isTrue, reason: result.errorMessage);
      expect(result.affectedRows, 1, reason: 'only the parent row counts');
      expect(await rows(db, 'SELECT id FROM invoice_items'), [
        {'id': 3},
      ]);
    });

    test('column-level REFERENCES ... ON DELETE CASCADE', () async {
      await exec(
        db,
        'CREATE TABLE notes (id INTEGER PRIMARY KEY, '
        'invoice INTEGER REFERENCES invoices (id) ON DELETE CASCADE)',
      );
      await exec(db, 'INSERT INTO notes VALUES (1, 1)');
      await exec(db, 'INSERT INTO notes VALUES (2, 2)');

      await exec(db, 'DELETE FROM invoices WHERE id = 2');

      expect(await rows(db, 'SELECT id FROM notes'), [
        {'id': 1},
      ]);
    });

    test('REFERENCES without a column uses the primary key', () async {
      await exec(
        db,
        'CREATE TABLE notes (id INTEGER PRIMARY KEY, '
        'invoice INTEGER REFERENCES invoices ON DELETE CASCADE)',
      );
      await exec(db, 'INSERT INTO notes VALUES (1, 1)');

      await exec(db, 'DELETE FROM invoices WHERE id = 1');

      expect(await rows(db, 'SELECT * FROM notes'), isEmpty);
    });

    test('cascades through several levels', () async {
      await addItems('ON DELETE CASCADE');
      await exec(
        db,
        'CREATE TABLE item_tags (id INTEGER PRIMARY KEY, item INTEGER, '
        'FOREIGN KEY (item) REFERENCES invoice_items (id) ON DELETE CASCADE)',
      );
      await exec(db, 'INSERT INTO item_tags VALUES (1, 1)');
      await exec(db, 'INSERT INTO item_tags VALUES (2, 3)');

      await exec(db, "DELETE FROM invoices WHERE invoiceId = 'INV-1'");

      expect(await rows(db, 'SELECT id FROM item_tags'), [
        {'id': 2},
      ]);
    });

    test('self-referencing cascade deletes a whole subtree', () async {
      await exec(
        db,
        'CREATE TABLE categories (id INTEGER PRIMARY KEY, parent INTEGER, '
        'FOREIGN KEY (parent) REFERENCES categories (id) ON DELETE CASCADE)',
      );
      for (final (id, parent) in [(1, null), (2, 1), (3, 2), (4, null)]) {
        await exec(db, 'INSERT INTO categories VALUES (?, ?)', [id, parent]);
      }

      await exec(db, 'DELETE FROM categories WHERE id = 1');

      expect(await rows(db, 'SELECT id FROM categories'), [
        {'id': 4},
      ]);
    });

    test("cascaded deletes fire the child table's DELETE triggers", () async {
      await addItems('ON DELETE CASCADE');
      await exec(db, 'CREATE TABLE removed (description TEXT)');
      await exec(
        db,
        'CREATE TRIGGER trg_removed AFTER DELETE ON invoice_items BEGIN '
        'INSERT INTO removed (description) VALUES (OLD.description); END',
      );

      await exec(db, "DELETE FROM invoices WHERE invoiceId = 'INV-1'");

      final removed = await rows(db, 'SELECT description FROM removed');
      expect(removed.map((r) => r['description']), unorderedEquals(['a', 'b']));
    });

    test('ON DELETE SET NULL clears the reference', () async {
      await addItems('ON DELETE SET NULL');

      await exec(db, "DELETE FROM invoices WHERE invoiceId = 'INV-1'");

      expect(
        await rows(db, 'SELECT id, invoiceId FROM invoice_items ORDER BY id'),
        [
          {'id': 1, 'invoiceId': null},
          {'id': 2, 'invoiceId': null},
          {'id': 3, 'invoiceId': 'INV-2'},
        ],
      );
    });

    test('ON DELETE SET DEFAULT writes the column default', () async {
      await exec(
        db,
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, invoiceId TEXT DEFAULT 'INV-2', "
        'FOREIGN KEY (invoiceId) REFERENCES invoices (invoiceId) '
        'ON DELETE SET DEFAULT)',
      );
      await exec(db, "INSERT INTO notes VALUES (1, 'INV-1')");

      await exec(db, "DELETE FROM invoices WHERE invoiceId = 'INV-1'");

      expect(await rows(db, 'SELECT invoiceId FROM notes'), [
        {'invoiceId': 'INV-2'},
      ]);
    });

    test('SET NULL on a NOT NULL column fails and changes nothing', () async {
      await exec(
        db,
        'CREATE TABLE notes (id INTEGER PRIMARY KEY, invoiceId TEXT NOT NULL, '
        'FOREIGN KEY (invoiceId) REFERENCES invoices (invoiceId) '
        'ON DELETE SET NULL)',
      );
      await exec(db, "INSERT INTO notes VALUES (1, 'INV-1')");

      final result = await db.execute('DELETE FROM invoices');

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('NOT NULL'));
      expect(await rows(db, 'SELECT * FROM invoices'), hasLength(2));
      expect(await rows(db, 'SELECT invoiceId FROM notes'), [
        {'invoiceId': 'INV-1'},
      ]);
    });

    test('ON DELETE RESTRICT blocks the delete and changes nothing', () async {
      await addItems('ON DELETE RESTRICT');

      final result = await db.execute('DELETE FROM invoices');

      expect(result.success, isFalse);
      expect(result.errorMessage, contains('FOREIGN KEY constraint failed'));
      expect(await rows(db, 'SELECT * FROM invoices'), hasLength(2));
      expect(await rows(db, 'SELECT * FROM invoice_items'), hasLength(3));
    });

    test('RESTRICT deeper in a cascade blocks the whole delete', () async {
      await addItems('ON DELETE CASCADE');
      await exec(
        db,
        'CREATE TABLE payments (id INTEGER PRIMARY KEY, item INTEGER, '
        'FOREIGN KEY (item) REFERENCES invoice_items (id) ON DELETE RESTRICT)',
      );
      await exec(db, 'INSERT INTO payments VALUES (1, 2)');

      final result = await db.execute('DELETE FROM invoices WHERE id = 1');

      expect(result.success, isFalse);
      expect(await rows(db, 'SELECT * FROM invoices'), hasLength(2));
      expect(await rows(db, 'SELECT * FROM invoice_items'), hasLength(3));
    });

    test('RESTRICT allows deleting a parent without children', () async {
      await addItems('ON DELETE RESTRICT');
      await exec(db, "INSERT INTO invoices VALUES (3, 'INV-3')");

      await exec(db, 'DELETE FROM invoices WHERE id = 3');

      expect(await rows(db, 'SELECT * FROM invoices'), hasLength(2));
    });

    test(
      'without an action, child rows are left alone (2.0: delete refused)',
      () async {
        await addItems('');

        final result = await db.execute(
          "DELETE FROM invoices WHERE invoiceId = 'INV-1'",
        );

        // 2.0: foreign keys are enforced by default, so the default action
        // (NO ACTION) refuses to orphan the children instead of ignoring them.
        expect(result.success, isFalse);
        expect(result.errorMessage, contains('FOREIGN KEY constraint failed'));
        expect(await rows(db, 'SELECT * FROM invoice_items'), hasLength(3));
        expect(await rows(db, 'SELECT * FROM invoices'), hasLength(2));
      },
    );

    test('ON UPDATE CASCADE follows a changed key', () async {
      await addItems('ON UPDATE CASCADE');

      await exec(
        db,
        "UPDATE invoices SET invoiceId = 'INV-1A' WHERE invoiceId = 'INV-1'",
      );

      expect(
        await rows(db, 'SELECT invoiceId FROM invoice_items ORDER BY id'),
        [
          {'invoiceId': 'INV-1A'},
          {'invoiceId': 'INV-1A'},
          {'invoiceId': 'INV-2'},
        ],
      );
    });

    test('ON UPDATE SET NULL clears the reference', () async {
      await addItems('ON UPDATE SET NULL');

      await exec(db, "UPDATE invoices SET invoiceId = 'X' WHERE id = 2");

      expect(
        await rows(db, 'SELECT invoiceId FROM invoice_items WHERE id = 3'),
        [
          {'invoiceId': null},
        ],
      );
    });

    test('ON UPDATE RESTRICT blocks the update and changes nothing', () async {
      await addItems('ON UPDATE RESTRICT');
      // INV-1 is now free to change; INV-2 still has a child.
      await exec(db, "DELETE FROM invoice_items WHERE invoiceId = 'INV-1'");

      final result = await db.execute(
        "UPDATE invoices SET invoiceId = CONCAT(invoiceId, '-X')",
      );

      expect(result.success, isFalse);
      // 2.0: SQLite's message, which does not name the action.
      expect(result.errorMessage, contains('FOREIGN KEY constraint failed'));
      expect(await rows(db, 'SELECT invoiceId FROM invoices ORDER BY id'), [
        {'invoiceId': 'INV-1'},
        {'invoiceId': 'INV-2'},
      ]);
    });

    test('updating other columns does not trigger ON UPDATE', () async {
      await addItems('ON UPDATE RESTRICT');

      await exec(db, 'UPDATE invoices SET id = id + 10');

      expect(await rows(db, 'SELECT id FROM invoices ORDER BY id'), [
        {'id': 11},
        {'id': 12},
      ]);
    });

    test('ROLLBACK restores cascaded rows', () async {
      await addItems('ON DELETE CASCADE');

      await db.beginTransaction();
      await exec(db, 'DELETE FROM invoices');
      expect(await rows(db, 'SELECT * FROM invoice_items'), isEmpty);
      await db.rollback();

      expect(await rows(db, 'SELECT * FROM invoice_items'), hasLength(3));
    });

    test('composite foreign keys take actions (1.x: rejected them)', () async {
      // 2.0: composite foreign keys take actions, as in SQLite (1.x
      // refused them with "single-column").
      await exec(db, 'CREATE TABLE pairs (a INTEGER, b TEXT, UNIQUE (a, b))');
      await exec(db, "INSERT INTO pairs VALUES (1, 'x'), (2, 'y')");
      await exec(
        db,
        'CREATE TABLE c (id INTEGER PRIMARY KEY, a INTEGER, b TEXT, '
        'FOREIGN KEY (a, b) REFERENCES pairs (a, b) '
        'ON DELETE CASCADE)',
      );
      await exec(db, "INSERT INTO c (a, b) VALUES (1, 'x'), (2, 'y')");
      expect(db.getTableSchema('c')!.foreignKeys.single.columns, ['a', 'b']);

      await exec(db, 'DELETE FROM pairs WHERE a = 1');

      expect(await rows(db, 'SELECT a, b FROM c'), [
        {'a': 2, 'b': 'y'},
      ]);
    });

    test('actions survive a save and reopen', () async {
      final name = uniqueName('api_fk_persist');
      final first = await JustDatabase.open(name);
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
      final fk = second.getTableSchema('c')!.foreignKeys.single;
      expect(fk.columns, ['p']);
      expect(fk.onDelete, ForeignKeyAction.cascade);
      expect(fk.onUpdate, ForeignKeyAction.setNull);

      await exec(second, 'DELETE FROM p');
      expect(await rows(second, 'SELECT * FROM c'), isEmpty);
      await second.close();
    });
  });

  group('Foreign key actions — backups', () {
    // 2.0: BackupManager is internal; backups go through the database.
    Future<JustDatabase> source() async {
      final db = await openMemory('fk_backup');
      for (final sql in [
        'CREATE TABLE p (id INTEGER PRIMARY KEY)',
        'CREATE TABLE c (id INTEGER PRIMARY KEY, p INTEGER, '
            'FOREIGN KEY (p) REFERENCES p (id) '
            'ON DELETE CASCADE ON UPDATE RESTRICT)',
      ]) {
        await exec(db, sql);
      }
      return db;
    }

    void expectActions(JustDatabase db) {
      final fk = db.getTableSchema('c')!.foreignKeys.single;
      expect(fk.onDelete, ForeignKeyAction.cascade);
      expect(fk.onUpdate, ForeignKeyAction.restrict);
    }

    test('SQL dump writes and restores the actions', () async {
      final sql = await (await source()).exportSql();
      expect(sql, contains('ON DELETE CASCADE ON UPDATE RESTRICT'));

      final restored = await openMemory('fk_restored');
      await restored.importSql(sql);
      expectActions(restored);
    });

    test('JSON backup writes and restores the actions', () async {
      final json = await (await source()).exportJson();

      final restored = await openMemory('fk_restored');
      await restored.importJson(json);
      expectActions(restored);
    });

    test('schema JSON round-trips the actions and omits them when unset', () {
      const fk = ForeignKeyDefinition(
        columns: ['p'],
        parentTable: 'p',
        onDelete: ForeignKeyAction.setDefault,
      );
      final json = fk.toJson();
      expect(json['onDelete'], 'setDefault');
      expect(json.containsKey('onUpdate'), isFalse);

      final back = ForeignKeyDefinition.fromJson(json);
      expect(back.onDelete, ForeignKeyAction.setDefault);
      expect(back.onUpdate, ForeignKeyAction.noAction);
    });
  });
}

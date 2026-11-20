// JustDatabaseAdminController with real storage (temporary directories):
// listing, opening (passphrases, random keys), modes, duplicates,
// encryption, backups, deleting, read-only, live updates and settings.
import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/src/ui/admin_preferences.dart';
import 'package:just_database/src/ui/admin_selection.dart';
import 'package:just_database/src/ui/just_database_admin_controller.dart'
    show AdminEncryption, BackupFormat;
import 'package:just_database/ui.dart';

import 'ui_test_support.dart';

/// A controller that keeps nothing between runs, once it has listed.
Future<JustDatabaseAdminController> _controller({
  bool readOnly = false,
  bool remember = false,
  bool persistByDefault = true,
}) async {
  final c = JustDatabaseAdminController(
    readOnly: readOnly,
    rememberSettings: remember,
    persistByDefault: persistByDefault,
  );
  await _until(() => c.hasLoaded && !c.isBusy);
  return c;
}

Future<void> _until(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 400; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(condition(), isTrue, reason: reason ?? 'never became true');
}

Future<void> _saveDb(String name, {String? key, int rows = 2}) async {
  final db = await JustDatabase.open(name, encryptionKey: key);
  (await db.execute('CREATE TABLE notes (body TEXT)')).orThrow();
  for (var i = 0; i < rows; i++) {
    (await db.execute('INSERT INTO notes VALUES (?)', ['note $i'])).orThrow();
  }
  await db.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePaths paths;
  setUpAll(() async => paths = await FakePaths.install());
  tearDownAll(() => paths.dispose());

  group('listing and opening', () {
    test("lists the app's databases and the saved ones; opens a saved one "
        'from storage and closes only what it opened', () async {
      final saved = uniqueName('saved');
      await _saveDb(saved);
      final app = await JustDatabase.open(uniqueName('app'), persist: false);
      final c = await _controller(persistByDefault: false);
      expect(c.infoFor(saved)?.isOpen, isFalse);
      expect(c.infoFor(app.name)?.isOpen, isTrue);

      expect(await c.selectDatabase(saved), isTrue);
      final db = c.database!;
      expect(db.persist, isTrue, reason: 'a saved database opens from storage');
      expect(db.rowCount('notes'), 2);
      expect(c.opened(saved), isTrue);
      expect(c.opened(app.name), isFalse);

      expect(await c.close(app.name), isFalse, reason: "the app's own");
      expect(c.lastError, contains('opened by the app'));

      c.dispose();
      await _until(() => !db.isOpen);
      expect(app.isOpen, isTrue);
      await app.close();
      await DatabaseManager.deleteDatabase(saved);
    });

    test('an unknown name fails and creates nothing', () async {
      final c = await _controller();
      final name = uniqueName('nope');
      expect(await c.selectDatabase(name), isFalse);
      expect(c.lastError, contains('There is no database named'));
      expect(paths.file(name).existsSync(), isFalse);
      c.dispose();
    });

    test('a passphrase-encrypted database asks for its passphrase', () async {
      final name = uniqueName('secret');
      await _saveDb(name, key: 'open sesame');
      final c = await _controller();
      expect(c.isEncrypted(name), isTrue);
      expect(await c.open(name), isFalse);
      expect(c.passphraseNeededFor, name);
      expect(c.lastError, contains('enter its passphrase'));

      expect(await c.open(name, passphrase: 'wrong'), isFalse);
      expect(c.lastError, contains('wrong encryptionKey'));

      expect(await c.open(name, passphrase: 'open sesame'), isTrue);
      expect(JustDatabase.findOpen(name)!.rowCount('notes'), 2);
      // Remembered for the session: reopening needs no prompt.
      expect(await c.close(name), isTrue);
      expect(await c.open(name), isTrue);
      c.dispose();
      await _until(() => JustDatabase.findOpen(name) == null);
      await DatabaseManager.deleteDatabase(name);
    });
  });

  group('creating', () {
    test('validates the name and refuses one in use', () async {
      final c = await _controller();
      expect(await c.create('bad name'), isFalse);
      expect(c.lastError, contains('Use only letters'));
      final name = uniqueName('taken');
      await _saveDb(name);
      expect(c.checkNewName(name), isNull, reason: 'not listed yet');
      await c.refresh();
      expect(c.checkNewName(name), contains('already exists'));
      expect(await c.create(name), isFalse);
      c.dispose();
      await DatabaseManager.deleteDatabase(name);
    });

    test('in memory, saved, random key and passphrase', () async {
      final c = await _controller();
      final mem = uniqueName('mem');
      expect(await c.create(mem, persist: false), isTrue);
      expect(c.database!.persist, isFalse);
      expect(c.selection, AdminSelection(mem));

      final keyed = uniqueName('keyed');
      expect(
        await c.create(keyed, encryption: AdminEncryption.randomKey),
        isTrue,
      );
      expect(c.isEncrypted(keyed), isTrue);
      expect(await SecureKeyManager.hasAutoKey(dbName: keyed), isTrue);
      expect(await c.close(keyed), isTrue);
      expect(await c.open(keyed), isTrue, reason: 'the stored key opens it');

      final pass = uniqueName('pass');
      expect(
        await c.create(pass, encryption: AdminEncryption.passphrase),
        isFalse,
      );
      expect(c.lastError, contains('enter a passphrase'));
      expect(
        await c.create(
          pass,
          encryption: AdminEncryption.passphrase,
          passphrase: 'pw',
        ),
        isTrue,
      );
      expect(c.isEncrypted(pass), isTrue);

      expect(await c.delete(keyed), isTrue);
      expect(await SecureKeyManager.hasAutoKey(dbName: keyed), isFalse);
      expect(await c.delete(pass), isTrue);
      expect(await c.delete(mem), isTrue);
      c.dispose();
    });
  });

  group('database actions', () {
    test('the mode changes only while the screen is the only user', () async {
      final name = uniqueName('mode');
      await _saveDb(name);
      final c = await _controller();
      expect(await c.open(name), isTrue);
      expect(c.canChangeMode(name), isTrue);
      expect(await c.reopen(name, DatabaseMode.writeFast), isTrue);
      final db = JustDatabase.findOpen(name)!;
      expect(db.mode, DatabaseMode.writeFast);

      final app = await JustDatabase.open(name, mode: DatabaseMode.writeFast);
      expect(c.canChangeMode(name), isFalse);
      expect(await c.reopen(name, DatabaseMode.standard), isFalse);
      await app.close();
      c.dispose();
      await _until(() => JustDatabase.findOpen(name) == null);
      await DatabaseManager.deleteDatabase(name);
    });

    test('duplicate copies the rows; the copy may be encrypted', () async {
      final name = uniqueName('orig');
      await _saveDb(name, rows: 3);
      final c = await _controller();
      expect(await c.open(name), isTrue);
      final copy = '${name}_copy';
      expect(
        await c.duplicate(
          name,
          copy,
          encryption: AdminEncryption.passphrase,
          passphrase: 'k',
        ),
        isTrue,
      );
      expect(c.selection?.database, copy);
      expect(JustDatabase.findOpen(copy)!.rowCount('notes'), 3);
      expect(c.isEncrypted(copy), isTrue);
      expect(await c.duplicate(name, copy), isFalse, reason: 'name taken');
      expect(await c.delete(copy), isTrue);
      expect(await c.delete(name), isTrue);
      c.dispose();
    });

    test('encrypt, re-key and decrypt a saved database', () async {
      final name = uniqueName('enc');
      await _saveDb(name);
      final c = await _controller();
      expect(await c.open(name), isTrue);
      expect(c.isEncrypted(name), isFalse);

      expect(
        await c.setEncryption(
          name,
          AdminEncryption.passphrase,
          passphrase: 'a',
        ),
        isTrue,
      );
      expect(c.isEncrypted(name), isTrue);
      expect(await c.setEncryption(name, AdminEncryption.randomKey), isTrue);
      expect(await SecureKeyManager.hasAutoKey(dbName: name), isTrue);
      expect(await c.setEncryption(name, AdminEncryption.none), isTrue);
      expect(c.isEncrypted(name), isFalse);
      expect(await SecureKeyManager.hasAutoKey(dbName: name), isFalse);

      expect(await c.close(name), isTrue);
      final plain = await JustDatabase.open(name);
      expect(plain.rowCount('notes'), 2);
      await plain.close();
      c.dispose();
      await DatabaseManager.deleteDatabase(name);
    });

    test('export, import as new and import into', () async {
      final name = uniqueName('src');
      await _saveDb(name, rows: 2);
      final c = await _controller();
      expect(await c.open(name), isTrue);
      final sql = (await c.exportText(name, BackupFormat.sql))!;
      expect(sql, contains('CREATE TABLE'));
      final json = (await c.exportText(name, BackupFormat.json))!;
      expect(jsonDecode(json), containsPair('format', 'just_database'));

      final fromSql = uniqueName('fromsql');
      expect(await c.importAsNew(fromSql, sql), isTrue);
      expect(JustDatabase.findOpen(fromSql)!.rowCount('notes'), 2);
      final fromJson = uniqueName('fromjson');
      expect(await c.importAsNew(fromJson, json), isTrue);
      expect(JustDatabase.findOpen(fromJson)!.rowCount('notes'), 2);

      expect(
        await c.importInto(
          fromSql,
          'CREATE TABLE other (x); INSERT INTO other VALUES (1);',
        ),
        isTrue,
      );
      expect(JustDatabase.findOpen(fromSql)!.tableNames, ['other']);

      expect(
        await c.importAsNew(uniqueName('broken'), '{"not": "an export"'),
        isFalse,
      );
      expect(c.lastError, contains('could not be read'));
      expect(c.databases.where((d) => d.name.startsWith('broken')), isEmpty);

      for (final n in [name, fromSql, fromJson]) {
        expect(await c.delete(n), isTrue);
      }
      c.dispose();
    });

    test('delete all deletes every database, open ones too', () async {
      final a = uniqueName('all_a');
      await _saveDb(a);
      final app = await JustDatabase.open(uniqueName('all_b'));
      final c = await _controller();
      expect(await c.deleteAll(), isTrue);
      expect(c.databases, isEmpty);
      expect(app.isOpen, isFalse);
      expect(paths.file(a).existsSync(), isFalse);
      c.dispose();
    });
  });

  test('a read-only controller refuses every write', () async {
    final name = uniqueName('ro');
    await _saveDb(name);
    final c = await _controller(readOnly: true);
    expect(await c.open(name), isTrue, reason: 'opening is allowed');
    expect(await c.exportText(name, BackupFormat.sql), isNotNull);
    for (final attempt in <Future<bool> Function()>[
      () => c.create(uniqueName('x')),
      () => c.delete(name),
      () => c.deleteAll(),
      () => c.importInto(name, 'CREATE TABLE t (x);'),
      () => c.duplicate(name, uniqueName('y')),
      () => c.setEncryption(name, AdminEncryption.randomKey),
    ]) {
      expect(await attempt(), isFalse);
      expect(c.lastError, contains('read-only'));
    }
    expect(JustDatabase.findOpen(name)!.tableNames, ['notes']);
    c.dispose();
    await _until(() => JustDatabase.findOpen(name) == null);
    await DatabaseManager.deleteDatabase(name);
  });

  test('changes made by the app reach the screen; a dropped selection '
      'falls back to its database', () async {
    final app = await JustDatabase.open(uniqueName('live'), persist: false);
    await app.execute('CREATE TABLE t (x)');
    final c = await _controller();
    expect(
      await c.select(
        AdminSelection(app.name, kind: AdminObjectKind.table, object: 't'),
      ),
      isTrue,
    );
    var notified = 0;
    c.addListener(() => notified++);
    await app.execute('INSERT INTO t VALUES (1)');
    await _until(() => notified > 0, reason: 'the write was noticed');

    await app.execute('DROP TABLE t');
    await _until(() => c.selection?.kind == null);
    expect(c.selection, AdminSelection(app.name));

    // A database the app opens later shows up by itself.
    final later = await JustDatabase.open(uniqueName('later'), persist: false);
    await _until(() => c.infoFor(later.name) != null);
    await later.close();
    await _until(() => c.infoFor(later.name) == null);
    c.dispose();
    await app.close();
  });

  test('settings, history and snippets are kept between runs', () async {
    var c = await _controller(remember: true);
    c
      ..setPageSize(250)
      ..setDefaultMode(DatabaseMode.readFast)
      ..setThemeMode(ThemeMode.light)
      ..addHistory(
        HistoryEntry(
          sql: 'SELECT 1',
          database: 'x',
          at: DateTime.now(),
          ok: true,
        ),
      )
      ..saveSnippet('one', 'SELECT 1');
    c.dispose(); // saves the pending change
    await Future<void>.delayed(const Duration(milliseconds: 300));

    c = await _controller(remember: true);
    await _until(() => c.pageSize == 250, reason: 'the settings were read');
    expect(c.defaultMode, DatabaseMode.readFast);
    expect(c.themeMode, ThemeMode.light);
    expect(c.history.single.sql, 'SELECT 1');
    expect(c.snippets.single.name, 'one');
    c
      ..clearHistory()
      ..deleteSnippet('one')
      ..setPageSize(50)
      ..setDefaultMode(DatabaseMode.standard)
      ..setThemeMode(ThemeMode.dark);
    c.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });

  test('history keeps the newest run of a statement, at most 100', () async {
    final c = await _controller();
    for (var i = 0; i < 120; i++) {
      c.addHistory(
        HistoryEntry(
          sql: 'SELECT $i',
          database: 'd',
          at: DateTime.now(),
          ok: true,
        ),
      );
    }
    c.addHistory(
      HistoryEntry(
        sql: 'SELECT 119',
        database: 'd',
        at: DateTime.now(),
        ok: false,
      ),
    );
    expect(c.history, hasLength(AdminPreferences.maxHistory));
    expect(c.history.first.ok, isFalse);
    expect(c.history.where((h) => h.sql == 'SELECT 119'), hasLength(1));
    c.dispose();
  });
}

// The web store (IndexedDB) and WebCrypto, in a browser:
//   flutter test --platform chrome test/web
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';

void main() {
  String unique(String p) => '${p}_${DateTime.now().microsecondsSinceEpoch}';

  test('saves to IndexedDB and reopens', () async {
    final name = unique('web');
    final db = await JustDatabase.open(name);
    expect(
      db.persist,
      isTrue,
      reason: 'IndexedDB must be available in the test browser',
    );
    await db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    await db.execute('INSERT INTO t (v) VALUES (?), (?)', ['a', 'b']);
    await db.close();
    final again = await JustDatabase.open(name);
    expect((await again.query('SELECT v FROM t ORDER BY id')).values, [
      ['a'],
      ['b'],
    ]);
    await again.close();
    await DatabaseManager.deleteDatabase(name);
    expect(
      (await DatabaseManager.listDatabases()).map((d) => d.name),
      isNot(contains(name)),
    );
  });

  test('encrypts with WebCrypto; a wrong key fails', () async {
    final name = unique('webkey');
    final db = await JustDatabase.open(name, encryptionKey: 'web secret');
    await db.execute('CREATE TABLE s (v TEXT)');
    await db.execute("INSERT INTO s VALUES ('hidden')");
    await db.close();
    await expectLater(
      JustDatabase.open(name, encryptionKey: 'nope'),
      throwsStateError,
    );
    final info = (await DatabaseManager.listDatabases()).firstWhere(
      (d) => d.name == name,
    );
    expect(info.isEncrypted, isTrue);
    final again = await JustDatabase.open(name, encryptionKey: 'web secret');
    expect((await again.query('SELECT v FROM s')).scalar, 'hidden');
    await again.close();
    await DatabaseManager.deleteDatabase(name);
  });
}

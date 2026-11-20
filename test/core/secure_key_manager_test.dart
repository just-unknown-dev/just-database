// Audit probes: SecureKeyManager.
// Each test asserts the CORRECT behaviour, so a failure means the bug exists.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _TempDirPathProvider extends PathProviderPlatform {
  _TempDirPathProvider(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async => path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

int _n = 0;
String _name(String p) =>
    'key_${p}_${DateTime.now().microsecondsSinceEpoch}_${_n++}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('jdb_key_probe_');
    PathProviderPlatform.instance = _TempDirPathProvider(dir.path);
  });
  tearDownAll(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('KEY concurrent first resolveAutoKey calls agree on one key', () async {
    final db = _name('auto');
    final keys = await Future.wait([
      SecureKeyManager.resolveAutoKey(dbName: db),
      SecureKeyManager.resolveAutoKey(dbName: db),
    ]);
    final stored = await SecureKeyManager.resolveAutoKey(dbName: db);
    expect(
      {keys[0], keys[1], stored}.length,
      1,
      reason:
          'callers got ${keys[0].substring(0, 8)}… and '
          '${keys[1].substring(0, 8)}…, stored ${stored.substring(0, 8)}…; '
          'a database encrypted with the losing key can never be opened',
    );
  });

  test('KEY concurrent first resolveKey calls agree on one salt', () async {
    final db = _name('salt');
    final sw = Stopwatch()..start();
    final keys = await Future.wait([
      SecureKeyManager.resolveKey(dbName: db, password: 'pw'),
      SecureKeyManager.resolveKey(dbName: db, password: 'pw'),
    ]);
    // ignore: avoid_print
    print('two concurrent PBKDF2 derivations: ${sw.elapsedMilliseconds}ms');
    final again = await SecureKeyManager.resolveKey(dbName: db, password: 'pw');
    expect(
      {keys[0], keys[1], again}.length,
      1,
      reason: 'same password, different keys: the salt was raced',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('KEY non-Latin-1 passwords do not collide', () async {
    final db = _name('utf');
    final sw = Stopwatch()..start();
    // 'пароль' code units & 0xFF == '?0@>;L'
    final cyrillic = await SecureKeyManager.resolveKey(
      dbName: db,
      password: 'пароль',
    );
    // ignore: avoid_print
    print('one PBKDF2 derivation (VM, JIT): ${sw.elapsedMilliseconds}ms');
    final ascii = await SecureKeyManager.resolveKey(
      dbName: db,
      password: '?0@>;L',
    );
    expect(
      cyrillic,
      isNot(ascii),
      reason: 'password "пароль" derives the same key as "?0@>;L"',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}

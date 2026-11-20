// The workbench service over the real Dart VM service, as the DevTools
// extension reaches it: registered when a database opens in a debug build,
// called through a VM service client, its events posted while a workbench
// is connected and not after.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:isolate' as isolates;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/src/core/workbench_service.dart';
import 'package:just_database/src/core/workbench_wire.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import '../ui/ui_test_support.dart';

void main() {
  late FakePaths paths;
  setUpAll(() async => paths = await FakePaths.install());
  tearDownAll(() => paths.dispose());
  tearDown(WorkbenchService.reset);

  test('a client calls the service over the VM service and gets its '
      'events while connected', () async {
    final db = await JustDatabase.open(uniqueName('vm'), persist: false);
    addTearDown(db.close);

    final info = await developer.Service.getInfo();
    if (info.serverUri == null) {
      markTestSkipped('needs the VM service: flutter test --enable-vmservice');
      return;
    }
    final service = await vmServiceConnectUri('${info.serverWebSocketUri}');
    addTearDown(service.dispose);
    final isolateId = developer.Service.getIsolateId(isolates.Isolate.current)!;

    final isolate = await service.getIsolate(isolateId);
    expect(
      isolate.extensionRPCs,
      contains(workbenchExtension),
      reason: 'opening a database registers the service in a debug build',
    );

    Future<Map<String, Object?>> call(
      String method, [
      Map<String, Object?> args = const {},
    ]) async {
      final response = await service.callServiceExtension(
        workbenchExtension,
        isolateId: isolateId,
        args: {'method': method, 'args': jsonEncode(args)},
      );
      return response.json!.cast<String, Object?>();
    }

    final hello = await call('connect');
    expect(hello['ok'], isTrue);
    expect(hello['protocol'], workbenchProtocol);
    expect(hello['version'], kJustDatabaseVersion);
    final session = hello['session'];

    final listing = await call('list', {'session': session});
    expect([
      for (final s in listing['open'] as List) (s as Map)['name'],
    ], contains(db.name));

    final created = await call('execute', {
      'database': db.name,
      'sql': 'CREATE TABLE t (id INTEGER PRIMARY KEY, b BLOB)',
    });
    expect(created['ok'], isTrue);
    final snapshot = DatabaseSnapshot.fromJson(
      created['snapshot'] as Map<String, Object?>,
    );
    expect([for (final t in snapshot.tables) t.schema.name], ['t']);

    await service.streamListen(EventStreams.kExtension);
    final change = service.onExtensionEvent.firstWhere(
      (e) => e.extensionKind == workbenchChangeEvent,
    );
    await call('execute', {
      'database': db.name,
      'sql': 'INSERT INTO t (b) VALUES (?)',
      'parameters': encodeParameters([
        Uint8List.fromList([1, 2, 3]),
      ]),
    });
    final event = await change.timeout(const Duration(seconds: 5));
    final data = event.extensionData!.data;
    expect(data['database'], db.name);
    expect((data['change'] as Map)['tables'], ['t']);

    final rows = await call('query', {
      'database': db.name,
      'sql': 'SELECT b FROM t',
    });
    final result = decodeResult(rows['result'] as Map<String, Object?>);
    expect(result.values.single.single, Uint8List.fromList([1, 2, 3]));

    final missing = await call('query', {'database': 'nope', 'sql': '1'});
    expect(missing['ok'], isFalse);
    expect(
      decodeError(missing['error'] as Map<String, Object?>),
      isA<StateError>(),
    );

    // Once the last workbench disconnects, the app's writes post nothing.
    expect((await call('disconnect', {'session': session}))['ok'], isTrue);
    final after = <String>[];
    final sub = service.onExtensionEvent.listen(
      (e) => after.add('${e.extensionKind}'),
    );
    await db.execute('INSERT INTO t (b) VALUES (NULL)');
    await Future<void>.delayed(WorkbenchService.changeDelay * 3);
    await sub.cancel();
    expect(after, isEmpty);
  });

  test(
    'a workbench cannot reach a database through an ended session',
    () async {
      final hello = await WorkbenchService.handle('connect', const {});
      final name = uniqueName('session');
      await WorkbenchService.handle('disconnect', {
        'session': hello['session'],
      });
      final reply = await WorkbenchService.handle('create', {
        'session': hello['session'],
        'database': name,
        'mode': 'standard',
        'persist': false,
        'encryption': 'none',
      });
      expect(reply['ok'], isFalse);
      expect(
        '${decodeError(reply['error'] as Map<String, Object?>)}',
        contains('session ended'),
      );
      await JustDatabase.findOpen(name)?.close();
    },
  );
}

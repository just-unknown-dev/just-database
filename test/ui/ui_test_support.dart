// Shared set-up for the admin UI widget tests.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/just_database.dart';
import 'package:just_database/src/core/workbench_service.dart';
import 'package:just_database/src/ui/backend/remote_host.dart';
import 'package:just_database/ui.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Whether the workbench tests reach the databases through the workbench
/// service, as the DevTools extension does (see remote_workbench_test.dart),
/// instead of directly.
bool remoteWorkbench = false;

/// A controller for a test: on this app's databases, or (with
/// [remoteWorkbench]) on the same databases through [LoopbackTransport].
JustDatabaseAdminController testController({
  bool readOnly = false,
  bool rememberSettings = false,
  bool persistByDefault = true,
}) => remoteWorkbench
    ? JustDatabaseAdminController.withHost(
        RemoteAdminHost(LoopbackTransport()),
        readOnly: readOnly,
        rememberSettings: rememberSettings,
        persistByDefault: persistByDefault,
      )
    : JustDatabaseAdminController(
        readOnly: readOnly,
        rememberSettings: rememberSettings,
        persistByDefault: persistByDefault,
      );

/// Calls this app's workbench service directly, sending every call, reply
/// and event through JSON as the Dart VM service would.
final class LoopbackTransport implements WorkbenchTransport {
  static Map<String, Object?> _wire(Map<String, Object?> json) =>
      jsonDecode(jsonEncode(json)) as Map<String, Object?>;

  @override
  Future<Map<String, Object?>> call(
    String method,
    Map<String, Object?> args,
  ) async => _wire(await WorkbenchService.handle(method, _wire(args)));

  @override
  Stream<(String, Map<String, Object?>)> get events =>
      WorkbenchService.events.map((e) => (e.$1, _wire(e.$2)));
}

/// Points path_provider at fresh temporary directories (created up front,
/// so listing databases needs no asynchronous file system work).
class FakePaths extends PathProviderPlatform {
  FakePaths._(this.root);

  static Future<FakePaths> install() async {
    final root = await Directory.systemTemp.createTemp('jdb_ui_test_');
    final paths = FakePaths._(root);
    Directory(paths.databases).createSync(recursive: true);
    Directory(paths.documents).createSync(recursive: true);
    PathProviderPlatform.instance = paths;
    return paths;
  }

  final Directory root;

  String get support => '${root.path}${Platform.pathSeparator}support';
  String get documents => '${root.path}${Platform.pathSeparator}documents';
  String get databases => '$support${Platform.pathSeparator}just_database';

  File file(String name) =>
      File('$databases${Platform.pathSeparator}$name.jdb');

  Future<void> dispose() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {
      // Windows may hold a handle for a moment.
    }
  }

  @override
  Future<String?> getApplicationSupportPath() async => support;

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getTemporaryPath() async => root.path;
}

int _counter = 0;

/// A database name no other test uses.
String uniqueName(String prefix) =>
    '${prefix}_${DateTime.now().microsecondsSinceEpoch}_${_counter++}';

/// Runs [sql] and fails the test when it fails.
Future<QueryResult> exec(JustDatabase db, String sql, [Object? params]) async {
  final r = await db.execute(sql, params);
  expect(r.success, isTrue, reason: '$sql -> ${r.errorMessage}');
  return r;
}

/// A big test window, so wide tables and dialogs fit.
void useLargeWindow(WidgetTester tester, {Size size = const Size(1400, 1000)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Pumps until [condition] holds, letting real I/O run in between.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int maxRounds = 200,
  String? reason,
}) async {
  for (var i = 0; i < maxRounds; i++) {
    if (condition()) return;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(condition(), isTrue, reason: reason ?? 'condition never became true');
}

/// Starts [action] in the test's fake-async zone and pumps (letting real
/// I/O run) until it completes; returns its value or rethrows its error.
/// [action] must not call `expect` (it runs beside a pump).
///
/// Database work must stay in one zone: a database opened inside
/// `tester.runAsync` and then used from the test body (or the reverse)
/// leaves its internal futures waiting for microtasks nobody runs.
Future<T> drive<T>(
  WidgetTester tester,
  Future<T> Function() action, {
  int maxRounds = 400,
}) async {
  T? value;
  Object? error;
  StackTrace? stack;
  var done = false;
  action().then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e, StackTrace s) {
      error = e;
      stack = s;
      done = true;
    },
  );
  await tester.pump();
  await pumpUntil(
    tester,
    () => done,
    maxRounds: maxRounds,
    reason: 'the operation never finished',
  );
  if (error != null) Error.throwWithStackTrace(error!, stack!);
  return value as T;
}

/// Lets real I/O and the resulting frames run for a few rounds.
Future<void> settleIo(WidgetTester tester, {int rounds = 10}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  await tester.pumpAndSettle();
}

/// The text field of [column] in an insert form or an edit dialog.
Finder fieldOf(String column) => find.byKey(ValueKey('jdb-field-$column'));

/// The NULL / DEFAULT menu of [column].
Finder modeMenuOf(String column) => find.byKey(ValueKey('jdb-mode-$column'));

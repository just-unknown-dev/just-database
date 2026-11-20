// The workbench tests again, with the workbench reaching the databases
// through the workbench service as the DevTools extension does: every call,
// reply and event goes through JSON (see LoopbackTransport).
import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/src/core/workbench_service.dart';

import 'controller_test.dart' as controller;
import 'ui_test_support.dart';
import 'workbench_compact_test.dart' as compact;
import 'workbench_wide_test.dart' as wide;

void main() {
  remoteWorkbench = true;
  // Each test's workbench connects anew (its listeners live in that test).
  tearDown(WorkbenchService.reset);
  group('remote controller', controller.main);
  group('remote wide', wide.main);
  group('remote compact', compact.main);
}

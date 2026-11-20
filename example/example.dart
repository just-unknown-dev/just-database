// Runs the just_database API tour (lib/tour.dart) and prints what it did:
// tables, bound parameters, a join, a transaction, a migration, the ORM and
// a backup. The example app (lib/main.dart) shows the workbench and runs the
// same tour from a button.
//
//   cd example
//   flutter run -t example.dart
import 'package:flutter/widgets.dart';

import 'lib/tour.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  for (final line in await runTour()) {
    debugPrint(line);
  }
}

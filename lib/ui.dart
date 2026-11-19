/// The database workbench of just_database, for Flutter.
///
/// [JustDatabaseAdminScreen] lists every database of the app (the ones it
/// has open and the saved ones). It browses and edits rows, edits schemas,
/// runs SQL, exports and imports, encrypts, benchmarks, and creates and
/// deletes databases: a sidebar and panes on wide screens, drill-down pages
/// on phones. [JustDatabaseAdminController] holds its state; pass one to
/// share it or to choose what the screen shows. `readOnly: true` makes a
/// screen that cannot change anything.
///
/// ```dart
/// import 'package:just_database/ui.dart';
///
/// MaterialApp(home: const JustDatabaseAdminScreen());
/// ```
///
/// The database API itself is in `package:just_database/just_database.dart`.
library;

export 'src/ui/ui.dart';

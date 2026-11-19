/// The Flutter admin UI of just_database.
///
/// [JustDatabaseAdminScreen] lists every database of the app (the ones it
/// has open and the saved ones) and lets you browse and edit rows, inspect
/// schemas, run SQL, benchmark, and create and delete databases. Its parts
/// can also be used on their own: [DatabaseProvider] (the state), the tabs,
/// and the [DatabaseDetailPage], [InsertPage] and [BenchmarkPage] pages.
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

/// A pure-Dart SQL database for Flutter.
///
/// * SQLite-style SQL: joins of every kind, subqueries, UNION / INTERSECT /
///   EXCEPT, aggregates, CASE and CAST, upserts, triggers, views, foreign
///   keys with actions, CHECK constraints, transactions and savepoints.
/// * Bound parameters (`?`, `?NNN`, `:name`) on every statement.
/// * Saved after every committed change to a file (IndexedDB on the web),
///   optionally AES-256-GCM encrypted.
/// * Migrations, SQL and JSON export/import, a typed ORM and benchmarks.
///
/// The admin UI is in `package:just_database/ui.dart`.
library;

export 'src/benchmark/benchmark.dart';
export 'src/core/core.dart';
export 'src/orm/orm.dart';
export 'src/sql/sql.dart';
export 'src/storage/storage.dart';

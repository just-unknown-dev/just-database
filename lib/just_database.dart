/// just_database — Pure-Dart SQL database engine for Flutter.
///
/// Features:
/// - Full SQL support: SELECT, INSERT, UPDATE, DELETE, CREATE/DROP/ALTER TABLE
/// - JOINs: INNER, LEFT, RIGHT
/// - Aggregates: COUNT, SUM, AVG, MIN, MAX with GROUP BY and HAVING
/// - 3 concurrency modes: standard, readFast, writeFast
/// - Optional file persistence via path_provider
/// - Embeddable admin widget [JustDatabaseAdminWidget]
/// - Triggers (BEFORE/AFTER INSERT/UPDATE/DELETE)
/// - Spatial data (ST_* functions, R-tree index)
/// - Query optimization hints (/*+ INDEX(...) */)
/// - Backup/restore (SQL dump + JSON)
/// - Schema migrations
/// - Performance benchmarking
/// - ORM layer (DbTable / DbRecord / DbColumn)
library;

export 'src/core/database_mode.dart';
export 'src/core/database.dart';
export 'src/core/database_manager.dart';
export 'src/core/backup.dart';
export 'src/core/migration.dart';
export 'src/core/secure_key_manager.dart';
export 'src/storage/schema.dart';
export 'src/storage/database_row.dart';
export 'src/storage/table.dart' show Table, InsertResult;
export 'src/storage/index.dart';
export 'src/storage/persistence.dart';
export 'src/storage/spatial.dart';
export 'src/storage/rtree.dart';
export 'src/sql/executor.dart';
export 'src/sql/parser.dart';
export 'src/sql/ast.dart'
    hide TokenType; // TokenType is internal; hide to keep public API clean
export 'src/concurrency/lock_manager.dart';
export 'src/widgets/admin_widget.dart';
export 'src/benchmark/benchmark.dart';
export 'src/orm/db_table.dart';
export 'src/version.dart';

// UI components for database administration
export 'ui.dart';

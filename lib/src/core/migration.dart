import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../sql/parser.dart';
import '../sql/executor.dart';

/// Status of an individual migration.
enum MigrationStatus { pending, applied, skipped, failed }

/// Result for a single migration step.
class MigrationResult {
  final int version;
  final String name;
  final MigrationStatus status;
  final String? errorMessage;
  final Duration? duration;

  const MigrationResult({
    required this.version,
    required this.name,
    required this.status,
    this.errorMessage,
    this.duration,
  });

  bool get success =>
      status == MigrationStatus.applied || status == MigrationStatus.skipped;

  @override
  String toString() =>
      'MigrationResult(v$version "$name" ${status.name}${errorMessage != null ? ": $errorMessage" : ""})';
}

/// Abstract base class for migrations.
abstract class Migration {
  /// The schema version this migration upgrades to.
  int get version;

  /// Human-readable name for the migration.
  String get name;

  /// Applies the migration (up).
  Future<void> up(Executor executor);

  /// Rolls back the migration (down). Optional — default throws unimplemented.
  Future<void> down(Executor executor) {
    throw UnimplementedError(
      'Rollback not implemented for migration v$version',
    );
  }

  /// Optional checksum for integrity validation (e.g., SHA-256 of the SQL script).
  String? get checksum => null;
}

/// A migration defined by raw SQL strings.
class SqlMigration extends Migration {
  @override
  final int version;

  @override
  final String name;

  final String upSql;
  final String? downSql;

  SqlMigration({
    required this.version,
    required this.name,
    required this.upSql,
    this.downSql,
  });

  @override
  Future<void> up(Executor executor) async {
    final stmts = Parser.parseSQLStatements(upSql);
    for (final stmt in stmts) {
      final result = await executor.execute(stmt);
      if (!result.success) {
        throw StateError(
          'Migration v$version up() failed: ${result.errorMessage}',
        );
      }
    }
  }

  @override
  Future<void> down(Executor executor) async {
    if (downSql == null) {
      throw UnimplementedError('No down SQL for migration v$version');
    }
    final stmts = Parser.parseSQLStatements(downSql!);
    for (final stmt in stmts) {
      final result = await executor.execute(stmt);
      if (!result.success) {
        throw StateError(
          'Migration v$version down() failed: ${result.errorMessage}',
        );
      }
    }
  }

  @override
  String get checksum {
    final bytes = utf8.encode(upSql);
    return sha256.convert(bytes).toString();
  }
}

/// A migration defined by Dart callback functions.
class CallbackMigration extends Migration {
  @override
  final int version;

  @override
  final String name;

  final Future<void> Function(Executor) upCallback;
  final Future<void> Function(Executor)? downCallback;

  CallbackMigration({
    required this.version,
    required this.name,
    required this.upCallback,
    this.downCallback,
  });

  @override
  Future<void> up(Executor executor) => upCallback(executor);

  @override
  Future<void> down(Executor executor) {
    if (downCallback == null) {
      throw UnimplementedError('No down callback for migration v$version');
    }
    return downCallback!(executor);
  }
}

/// Manages schema versioning and migration execution.
/// Stores applied versions in a special `_migrations` table.
class MigrationRunner {
  static const String _migrationsTable = '_migrations';

  final Executor _executor;
  final List<Migration> _migrations;

  MigrationRunner({
    required Executor executor,
    required List<Migration> migrations,
  }) : _executor = executor,
       _migrations = List.of(migrations)
         ..sort((a, b) => a.version.compareTo(b.version));

  /// Creates the internal migrations table if it doesn't exist.
  Future<void> initialize() async {
    final result = await _executor.executeSQL('''
      CREATE TABLE IF NOT EXISTS $_migrationsTable (
        version INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        checksum TEXT,
        applied_at TEXT NOT NULL
      )
    ''');
    if (!result.success) {
      throw StateError(
        'Failed to initialize migrations table: ${result.errorMessage}',
      );
    }
  }

  /// Returns the highest applied migration version (0 if none).
  Future<int> currentVersion() async {
    await _ensureInitialized();
    final result = await _executor.executeSQL(
      'SELECT MAX(version) AS v FROM $_migrationsTable',
    );
    if (!result.success || result.rows.isEmpty) return 0;
    final v = result.rows.first['v'];
    return v == null ? 0 : (v as num).toInt();
  }

  /// Applies all pending migrations up to [targetVersion] (or all, if null).
  Future<List<MigrationResult>> migrate({int? targetVersion}) async {
    await _ensureInitialized();
    final current = await currentVersion();
    final results = <MigrationResult>[];
    for (final migration in _migrations) {
      if (migration.version <= current) {
        results.add(
          MigrationResult(
            version: migration.version,
            name: migration.name,
            status: MigrationStatus.skipped,
          ),
        );
        continue;
      }
      if (targetVersion != null && migration.version > targetVersion) break;
      results.add(await _applyMigration(migration));
      if (results.last.status == MigrationStatus.failed) break;
    }
    return results;
  }

  /// Rolls back migrations down to (but not including) [targetVersion].
  Future<List<MigrationResult>> rollback({int targetVersion = 0}) async {
    await _ensureInitialized();
    final current = await currentVersion();
    final toRollback =
        _migrations
            .where((m) => m.version <= current && m.version > targetVersion)
            .toList()
          ..sort((a, b) => b.version.compareTo(a.version)); // descending

    final results = <MigrationResult>[];
    for (final migration in toRollback) {
      results.add(await _rollbackMigration(migration));
      if (results.last.status == MigrationStatus.failed) break;
    }
    return results;
  }

  /// Returns the status of all known migrations relative to current version.
  Future<List<MigrationResult>> status() async {
    await _ensureInitialized();
    final current = await currentVersion();
    return _migrations.map((m) {
      final s = m.version <= current
          ? MigrationStatus.applied
          : MigrationStatus.pending;
      return MigrationResult(version: m.version, name: m.name, status: s);
    }).toList();
  }

  // ---------------------------------------------------------------------------
  // Private implementation
  // ---------------------------------------------------------------------------

  Future<MigrationResult> _applyMigration(Migration migration) async {
    final start = DateTime.now();
    try {
      await migration.up(_executor);
      await _recordApplied(migration);
      return MigrationResult(
        version: migration.version,
        name: migration.name,
        status: MigrationStatus.applied,
        duration: DateTime.now().difference(start),
      );
    } catch (e) {
      return MigrationResult(
        version: migration.version,
        name: migration.name,
        status: MigrationStatus.failed,
        errorMessage: e.toString(),
        duration: DateTime.now().difference(start),
      );
    }
  }

  Future<MigrationResult> _rollbackMigration(Migration migration) async {
    final start = DateTime.now();
    try {
      await migration.down(_executor);
      await _executor.executeSQL(
        'DELETE FROM $_migrationsTable WHERE version = ${migration.version}',
      );
      return MigrationResult(
        version: migration.version,
        name: migration.name,
        status: MigrationStatus.skipped,
        duration: DateTime.now().difference(start),
      );
    } catch (e) {
      return MigrationResult(
        version: migration.version,
        name: migration.name,
        status: MigrationStatus.failed,
        errorMessage: e.toString(),
        duration: DateTime.now().difference(start),
      );
    }
  }

  Future<void> _recordApplied(Migration migration) async {
    final appliedAt = DateTime.now().toIso8601String();
    final checksum = migration.checksum ?? 'null';
    final stmt = Parser.parseSQL(
      "INSERT INTO $_migrationsTable (version, name, checksum, applied_at) "
      "VALUES (${migration.version}, '${_escape(migration.name)}', "
      "'${_escape(checksum)}', '$appliedAt')",
    );
    final result = await _executor.execute(stmt);
    if (!result.success) {
      throw StateError('Failed to record migration: ${result.errorMessage}');
    }
  }

  Future<void> _ensureInitialized() async {
    // Check if migrations table exists; initialize lazily
    final result = await _executor.executeSQL(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='$_migrationsTable'",
    );
    // If query fails (unknown table), initialize
    if (!result.success || result.rows.isEmpty) {
      await initialize();
    }
  }

  static String _escape(String s) => s.replaceAll("'", "''");
}

/// Simple DTO describing a recorded migration.
class AppliedMigration {
  final int version;
  final String name;
  final String? checksum;
  final DateTime appliedAt;

  const AppliedMigration({
    required this.version,
    required this.name,
    this.checksum,
    required this.appliedAt,
  });

  factory AppliedMigration.fromRow(Map<String, dynamic> row) =>
      AppliedMigration(
        version: row['version'] as int,
        name: row['name'] as String,
        checksum: row['checksum'] as String?,
        appliedAt: DateTime.parse(row['applied_at'] as String),
      );
}

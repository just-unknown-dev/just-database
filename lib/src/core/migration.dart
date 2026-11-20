import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'just_database.dart';

/// The state of one migration.
enum MigrationStatus {
  /// Not applied yet.
  pending,

  /// Applied (by this run, or before).
  applied,

  /// Rolled back by this run.
  rolledBack,

  /// Failed; nothing it did was kept.
  failed,
}

/// The outcome of one migration step.
final class MigrationResult {
  /// Creates a result.
  const MigrationResult({
    required this.version,
    required this.name,
    required this.status,
    this.errorMessage,
    this.duration,
  });

  final int version;
  final String name;
  final MigrationStatus status;

  /// Why it failed.
  final String? errorMessage;

  /// How long it took, for steps this run performed.
  final Duration? duration;

  /// Whether the step did not fail.
  bool get success => status != MigrationStatus.failed;

  @override
  String toString() =>
      'MigrationResult(v$version "$name" ${status.name}'
      '${errorMessage != null ? ': $errorMessage' : ''})';
}

/// A migration problem that stops every step: a changed migration, one
/// added below the applied version, or duplicate versions.
final class MigrationException implements Exception {
  /// Creates the exception.
  const MigrationException(this.message);

  /// What is wrong.
  final String message;

  @override
  String toString() => 'MigrationException: $message';
}

/// One schema change, identified by its [version] (1 and up).
abstract class Migration {
  /// The schema version this migration upgrades to.
  int get version;

  /// A human-readable name.
  String get name;

  /// Applies the migration. Runs in a transaction: if it throws, nothing it
  /// did is kept.
  Future<void> up(Transaction tx);

  /// Reverts the migration. The default throws [UnsupportedError].
  Future<void> down(Transaction tx) =>
      throw UnsupportedError('migration v$version has no down()');

  /// A fingerprint of the migration. When it is non-null and differs from
  /// the one stored when the migration was applied, [MigrationRunner]
  /// stops with a [MigrationException].
  String? get checksum => null;
}

/// A migration written as SQL scripts.
class SqlMigration extends Migration {
  /// Creates a migration from SQL.
  SqlMigration({
    required this.version,
    required this.name,
    required this.upSql,
    this.downSql,
  });

  @override
  final int version;
  @override
  final String name;

  /// The statements that apply it, separated by `;`.
  final String upSql;

  /// The statements that revert it.
  final String? downSql;

  @override
  Future<void> up(Transaction tx) => tx.executeScript(upSql);

  @override
  Future<void> down(Transaction tx) {
    final sql = downSql;
    if (sql == null) {
      throw UnsupportedError('migration v$version has no downSql');
    }
    return tx.executeScript(sql);
  }

  /// The SHA-256 of [upSql].
  @override
  String get checksum => sha256.convert(utf8.encode(upSql)).toString();
}

/// A migration written as Dart callbacks.
class CallbackMigration extends Migration {
  /// Creates a migration from callbacks.
  CallbackMigration({
    required this.version,
    required this.name,
    required this.upCallback,
    this.downCallback,
  });

  @override
  final int version;
  @override
  final String name;
  final Future<void> Function(Transaction tx) upCallback;
  final Future<void> Function(Transaction tx)? downCallback;

  @override
  Future<void> up(Transaction tx) => upCallback(tx);

  @override
  Future<void> down(Transaction tx) {
    final cb = downCallback;
    if (cb == null) {
      throw UnsupportedError('migration v$version has no downCallback');
    }
    return cb(tx);
  }
}

/// Applies and reverts [Migration]s on a database, recording the applied
/// versions in the `_migrations` table.
class MigrationRunner {
  /// Creates a runner. Throws [ArgumentError] when two migrations share a
  /// version or a version is below 1.
  MigrationRunner(this.database, List<Migration> migrations)
    : _migrations = List.of(migrations)
        ..sort((a, b) => a.version.compareTo(b.version)) {
    final seen = <int>{};
    for (final m in _migrations) {
      if (m.version < 1) {
        throw ArgumentError.value(
          m.version,
          'version',
          'migration versions start at 1',
        );
      }
      if (!seen.add(m.version)) {
        throw ArgumentError.value(
          m.version,
          'version',
          'two migrations have version ${m.version}',
        );
      }
    }
  }

  static const _table = '_migrations';

  /// The database migrated.
  final JustDatabase database;
  final List<Migration> _migrations;

  Future<void> _initialize() async {
    final r = await database.execute(
      'CREATE TABLE IF NOT EXISTS $_table ('
      'version INTEGER PRIMARY KEY, name TEXT NOT NULL, checksum TEXT, '
      'applied_at TEXT NOT NULL)',
    );
    r.orThrow();
  }

  /// Applied versions with their stored checksums.
  Future<Map<int, String?>> _applied() async {
    await _initialize();
    final r = (await database.query(
      'SELECT version, checksum FROM $_table',
    )).orThrow();
    return {
      for (final row in r.values)
        row[0] as int: (row[1] == null || row[1] == 'null')
            ? null
            : row[1] as String,
    };
  }

  /// The highest applied version, or 0.
  Future<int> currentVersion() async {
    final applied = await _applied();
    return applied.isEmpty ? 0 : applied.keys.reduce((a, b) => a > b ? a : b);
  }

  void _verify(Map<int, String?> applied) {
    for (final m in _migrations) {
      if (!applied.containsKey(m.version)) continue;
      final stored = applied[m.version];
      final now = m.checksum;
      if (stored != null && now != null && stored != now) {
        throw MigrationException(
          'migration v${m.version} "${m.name}" was changed after it was applied',
        );
      }
    }
  }

  /// Applies every pending migration up to [targetVersion] (all when
  /// null), in version order, each in its own transaction. Stops at the
  /// first that fails (it then left nothing behind) and returns a result
  /// per migration that ran. Saves before returning.
  ///
  /// Throws [MigrationException] when an applied migration changed or a
  /// pending one is older than the newest applied one.
  Future<List<MigrationResult>> migrate({int? targetVersion}) async {
    final applied = await _applied();
    _verify(applied);
    final newest = applied.isEmpty
        ? 0
        : applied.keys.reduce((a, b) => a > b ? a : b);
    final pending = [
      for (final m in _migrations)
        if (!applied.containsKey(m.version) &&
            (targetVersion == null || m.version <= targetVersion))
          m,
    ];
    for (final m in pending) {
      if (m.version < newest) {
        throw MigrationException(
          'migration v${m.version} "${m.name}" is older than the applied v$newest; '
          'give it a higher version',
        );
      }
    }
    final results = <MigrationResult>[];
    for (final m in pending) {
      final watch = Stopwatch()..start();
      try {
        await database.transaction((tx) async {
          await m.up(tx);
          await tx.execute(
            'INSERT INTO $_table (version, name, checksum, applied_at) VALUES (?, ?, ?, ?)',
            [
              m.version,
              m.name,
              m.checksum,
              DateTime.now().toUtc().toIso8601String(),
            ],
          );
        });
        results.add(
          MigrationResult(
            version: m.version,
            name: m.name,
            status: MigrationStatus.applied,
            duration: watch.elapsed,
          ),
        );
      } catch (e) {
        results.add(
          MigrationResult(
            version: m.version,
            name: m.name,
            status: MigrationStatus.failed,
            errorMessage: '$e',
            duration: watch.elapsed,
          ),
        );
        break;
      }
    }
    await database.flush();
    return results;
  }

  /// Reverts applied migrations above [targetVersion], newest first, each
  /// in its own transaction. Stops at the first that fails. Saves before
  /// returning.
  Future<List<MigrationResult>> rollback({int targetVersion = 0}) async {
    final applied = await _applied();
    _verify(applied);
    final todo = [
      for (final m in _migrations.reversed)
        if (applied.containsKey(m.version) && m.version > targetVersion) m,
    ];
    final results = <MigrationResult>[];
    for (final m in todo) {
      final watch = Stopwatch()..start();
      try {
        await database.transaction((tx) async {
          await m.down(tx);
          await tx.execute('DELETE FROM $_table WHERE version = ?', [
            m.version,
          ]);
        });
        results.add(
          MigrationResult(
            version: m.version,
            name: m.name,
            status: MigrationStatus.rolledBack,
            duration: watch.elapsed,
          ),
        );
      } catch (e) {
        results.add(
          MigrationResult(
            version: m.version,
            name: m.name,
            status: MigrationStatus.failed,
            errorMessage: '$e',
            duration: watch.elapsed,
          ),
        );
        break;
      }
    }
    await database.flush();
    return results;
  }

  /// Every known migration with whether it is applied.
  Future<List<MigrationResult>> status() async {
    final applied = await _applied();
    return [
      for (final m in _migrations)
        MigrationResult(
          version: m.version,
          name: m.name,
          status: applied.containsKey(m.version)
              ? MigrationStatus.applied
              : MigrationStatus.pending,
        ),
    ];
  }
}

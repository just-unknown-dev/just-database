import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// Points path_provider at fresh temporary directories, so file-backed
/// databases in tests never touch the real ones.
class TempPaths extends PathProviderPlatform {
  TempPaths._(this.root);

  /// Creates the directories and installs them as path_provider's.
  static Future<TempPaths> install() async {
    final root = await Directory.systemTemp.createTemp('just_database_test_');
    final paths = TempPaths._(root);
    await Directory(paths.support).create(recursive: true);
    await Directory(paths.documents).create(recursive: true);
    PathProviderPlatform.instance = paths;
    return paths;
  }

  final Directory root;

  /// The application support directory (where 2.x keeps databases).
  String get support => '${root.path}${Platform.pathSeparator}support';

  /// The documents directory (where 1.x kept databases).
  String get documents => '${root.path}${Platform.pathSeparator}documents';

  /// The 2.x database directory.
  String get databases => '$support${Platform.pathSeparator}just_database';

  /// The 1.x database directory.
  String get legacyDatabases =>
      '$documents${Platform.pathSeparator}just_database';

  /// The 2.x file of database [name].
  File file(String name) =>
      File('$databases${Platform.pathSeparator}$name.jdb');

  /// Deletes everything.
  Future<void> dispose() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {
      // Windows may still hold a handle for a moment.
    }
  }

  @override
  Future<String?> getApplicationSupportPath() async => support;

  @override
  Future<String?> getApplicationDocumentsPath() async => documents;

  @override
  Future<String?> getTemporaryPath() async => root.path;
}

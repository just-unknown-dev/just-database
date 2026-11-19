// Checks on the admin UI's sources and public surface.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_database/ui.dart';

void main() {
  final sources = [
    for (final f in Directory(
      'lib/src/ui',
    ).listSync(recursive: true).whereType<File>())
      if (f.path.endsWith('.dart')) f,
    File('lib/ui.dart'),
  ];

  test('ui.dart exports the screen, its controller and the seed callback', () {
    // Compiles only while every type is exported.
    const types = [
      JustDatabaseAdminScreen,
      JustDatabaseAdminController,
      SeedDatabaseCallback,
    ];
    expect(types, hasLength(3));
    final exported = RegExp(r"^export '([^']+)'", multiLine: true)
        .allMatches(File('lib/src/ui/ui.dart').readAsStringSync())
        .map((m) => m.group(1)!)
        .toList();
    expect(exported, [
      'just_database_admin_controller.dart',
      'just_database_admin_screen.dart',
    ]);
  });

  test('the admin UI needs no just_signals', () {
    for (final f in sources) {
      expect(
        f.readAsStringSync(),
        isNot(contains('just_signals')),
        reason: f.path,
      );
    }
    expect(
      File('pubspec.yaml').readAsStringSync(),
      isNot(contains('just_signals')),
    );
  });

  test('the core library does not export the UI', () {
    final exports = RegExp(r"^export '([^']+)'", multiLine: true)
        .allMatches(File('lib/just_database.dart').readAsStringSync())
        .map((m) => m.group(1)!)
        .toList();
    expect(exports, isNotEmpty);
    expect(
      exports.where((e) => e.contains('/ui/') || e.endsWith('ui.dart')),
      isEmpty,
      reason: 'only package:just_database/ui.dart has the UI',
    );
  });

  test('UI files import the core relatively, never the public libraries', () {
    final bad = <String>[];
    final import = RegExp(r"^import '([^']+)'", multiLine: true);
    for (final f in sources.where((f) => f.path.contains('src'))) {
      final from = f.parent.uri;
      for (final m in import.allMatches(f.readAsStringSync())) {
        final uri = m.group(1)!;
        if (uri.startsWith('package:just_database/')) {
          bad.add('${f.path}: $uri');
          continue;
        }
        if (uri.startsWith('package:') || uri.startsWith('dart:')) continue;
        final target = from.resolve(uri).path;
        if (RegExp(r'(^|/)lib/(ui|just_database)\.dart$').hasMatch(target)) {
          bad.add('${f.path}: $uri');
        }
      }
    }
    expect(bad, isEmpty);
  });

  test('no BOM, no replacement characters, no hard-coded Colors', () {
    final problems = <String>[];
    for (final f in sources) {
      final bytes = f.readAsBytesSync();
      if (bytes.length >= 3 &&
          bytes[0] == 0xEF &&
          bytes[1] == 0xBB &&
          bytes[2] == 0xBF) {
        problems.add('${f.path}: BOM');
      }
      final text = f.readAsStringSync();
      if (text.contains(String.fromCharCode(0xFFFD))) {
        problems.add('${f.path}: U+FFFD');
      }
      if (RegExp(r'\bColors\.').hasMatch(text)) {
        problems.add('${f.path}: Colors.*');
      }
      if (text.contains('arrow_back_ios')) {
        problems.add('${f.path}: custom back arrow');
      }
    }
    expect(problems, isEmpty);
  });
}

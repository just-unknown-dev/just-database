/// Export files on native platforms: a `just_database` folder in the
/// Downloads folder (the Documents folder where there is none).
@internal
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show internal;
import 'package:path_provider/path_provider.dart';

import '../persistence/export_file.dart';

/// Whether [pickTextFile] can show a file picker here (it cannot on
/// native platforms without a plugin).
const bool canPickFiles = false;

/// Whether a file can be read from a path the user types.
bool get canReadTypedPaths =>
    Platform.isWindows || Platform.isLinux || Platform.isMacOS;

Future<Directory> _folder() async {
  Directory? base;
  try {
    base = await getDownloadsDirectory();
  } catch (_) {
    // Not every platform (or test double) has a Downloads folder.
  }
  base ??= await getApplicationDocumentsDirectory();
  final dir = Directory('${base.path}${Platform.pathSeparator}just_database');
  await dir.create(recursive: true);
  return dir;
}

/// The folder exports are saved in.
Future<String?> exportsLocation() async => (await _folder()).path;

/// Saves [content] as [fileName] in the exports folder, replacing a file of
/// that name, and returns its path.
Future<String> saveExport(String fileName, String content) async {
  final dir = await _folder();
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  final temp = File('${file.path}.tmp');
  await temp.writeAsString(content, flush: true);
  if (await file.exists()) await file.delete();
  await temp.rename(file.path);
  return file.path;
}

/// The files in the exports folder, newest first.
Future<List<ExportFile>> listExports() async {
  final dir = await _folder();
  final out = <ExportFile>[];
  await for (final e in dir.list(followLinks: false)) {
    if (e is! File || e.path.endsWith('.tmp')) continue;
    final stat = await e.stat();
    out.add(
      ExportFile(
        name: e.uri.pathSegments.last,
        path: e.path,
        sizeBytes: stat.size,
        modified: stat.modified,
      ),
    );
  }
  out.sort((a, b) => b.modified.compareTo(a.modified));
  return out;
}

/// The text of the file at [path].
Future<String> readExport(String path) => File(path).readAsString();

/// Lets the user pick a text file; never available here (see
/// [canPickFiles]).
Future<PickedTextFile?> pickTextFile() async => null;

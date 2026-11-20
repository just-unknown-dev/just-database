/// Export files in the browser: a download to save, a file picker to read.
@internal
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter/foundation.dart' show internal;
import 'package:web/web.dart' as web;

import '../persistence/export_file.dart';

/// Whether [pickTextFile] can show a file picker here.
const bool canPickFiles = true;

/// Whether a file can be read from a path the user types (never in a
/// browser).
bool get canReadTypedPaths => false;

/// Where exports go: the browser's downloads, so there is no folder.
Future<String?> exportsLocation() async => null;

/// Downloads [content] as [fileName] and says where it went.
Future<String> saveExport(String fileName, String content) async {
  final blob = web.Blob(
    <web.BlobPart>[content.toJS].toJS,
    web.BlobPropertyBag(type: 'text/plain;charset=utf-8'),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = fileName
    ..style.display = 'none';
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
  // Give the browser a moment to start the download before freeing it.
  Timer(const Duration(seconds: 30), () => web.URL.revokeObjectURL(url));
  return "your browser's downloads ($fileName)";
}

/// No folder to list in a browser.
Future<List<ExportFile>> listExports() async => const [];

/// A browser cannot read a file by path.
Future<String> readExport(String path) =>
    Future.error(UnsupportedError('a browser cannot read files by path'));

/// Shows the browser's file picker and reads the chosen file as text;
/// null when nothing was chosen.
Future<PickedTextFile?> pickTextFile() async {
  final input = web.HTMLInputElement()
    ..type = 'file'
    ..accept = '.sql,.json,.txt,text/plain,application/json';
  final chosen = Completer<web.File?>();
  input.onchange = ((web.Event _) {
    if (!chosen.isCompleted) chosen.complete(input.files?.item(0));
  }).toJS;
  input.addEventListener(
    'cancel',
    ((web.Event _) {
      if (!chosen.isCompleted) chosen.complete(null);
    }).toJS,
  );
  input.click();
  final file = await chosen.future;
  if (file == null) return null;
  final text = (await file.text().toDart).toDart;
  return (name: file.name, content: text);
}

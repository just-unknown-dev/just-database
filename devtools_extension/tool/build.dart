// Builds this extension into ../extension/devtools/build, ready to publish
// with just_database:
//
//   dart run tool/build.dart
//
// It runs `flutter build web` (the flutter on PATH) with CanvasKit served
// from the build itself, so the DevTools tab works offline, and leaves out
// what a JavaScript CanvasKit build never loads: debug symbols and the
// Wasm-only and experimental renderers. That keeps the package small.
import 'dart:io';

/// Files of build/web that are not copied.
bool _unused(String path) {
  final p = path.replaceAll(r'\', '/');
  return p.endsWith('.symbols') ||
      p == '.last_build_id' ||
      p.startsWith('canvaskit/skwasm') ||
      p.startsWith('canvaskit/wimp') ||
      p.startsWith('canvaskit/webparagraph/');
}

Future<void> main() async {
  final build = await Process.start(
    'flutter',
    [
      'build',
      'web',
      '--release',
      '--no-web-resources-cdn',
      '--no-wasm-dry-run',
    ],
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
  );
  if (await build.exitCode != 0) {
    stderr.writeln('flutter build web failed');
    exit(1);
  }

  final from = Directory('build/web');
  final to = Directory('../extension/devtools/build');
  if (to.existsSync()) to.deleteSync(recursive: true);
  var files = 0;
  var bytes = 0;
  for (final entity in from.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = entity.path.substring(from.path.length + 1);
    if (_unused(relative)) continue;
    final target = File('${to.path}/${relative.replaceAll(r'\', '/')}');
    target.parent.createSync(recursive: true);
    entity.copySync(target.path);
    files++;
    bytes += entity.lengthSync();
  }
  final mb = (bytes / (1024 * 1024)).toStringAsFixed(1);
  stdout.writeln('Copied $files files ($mb MB) to ${to.path}.');
}

// How lib/ is laid out, checked from the directives of every file (the
// rules follow just_game_engine's test/library_layout_test.dart):
// - every file under a top-level folder of lib/src is exported by a public
//   library, through its folder's barrel, or is internal: each of its
//   public declarations is `@internal` (or the file says `@internal
//   library;`);
// - only a folder's barrel or a public library exports, and a barrel only
//   its own folder; a library that holds parts is not a barrel;
// - no file imports a barrel that leads back to it;
// - io/ never reaches the web (package:web, dart:js_interop), and web/
//   never reaches dart:io: each compiles only on its own platforms;
// - only ui/ imports Flutter's widgets, and only ui.dart exports it;
// - no import loop crosses from one feature (a top-level folder of lib/src)
//   to another, and no feature imports one in a layer above its own.
// It only reads files.

import 'dart:io';
import 'dart:math' show min;

import 'package:flutter_test/flutter_test.dart';

const _package = 'package:just_database/';

/// The public libraries, under lib/.
const _public = ['just_database.dart', 'ui.dart'];

/// Files no public library exports and that are not `@internal` either,
/// with why. Empty: an internal helper says so on its declarations.
const Map<String, String> _internalByList = {};

/// The features — the top-level folders of lib/src — in layers, bottom to
/// top. A feature imports features in its own layer or below, never above;
/// within a layer imports go one way only (no loops). A new top-level
/// folder takes its place here.
const _layers = [
  // SQL text, and the data structures it runs on.
  ['sql', 'storage'],
  // The engine; the file format and the store interface.
  ['engine', 'persistence'],
  // The platforms: files through dart:io, the browser through package:web.
  ['io', 'web'],
  // JustDatabase and the rest of the API.
  ['core'],
  // Built on the API.
  ['orm', 'benchmark'],
  // The admin screen.
  ['ui'],
];

/// What only web/ may import.
const _webOnly = ['package:web/', 'dart:js_interop'];

/// What only io/ may import.
const _ioOnly = ['dart:io', 'dart:isolate', 'package:path_provider/'];

/// The Flutter libraries only ui/ may import: everything but foundation.
bool _isFlutterUi(String uri) =>
    uri.startsWith('package:flutter/') &&
    uri != 'package:flutter/foundation.dart';

final _directive = RegExp(
  r'^[ \t]*(import|export|part[ \t]+of|part)\b([^;]*);',
  multiLine: true,
);
final _uri = RegExp(r"'([^']+)'");

/// One `import`, `export`, `part` or `part of` of a file, resolved.
final class _Directive {
  _Directive(this.kind, this.uri, this.target);

  final String kind;
  final String uri;

  /// The file it names, relative to lib/; null for another package's.
  final String? target;
}

/// A file under lib/: its path from lib/, text and directives.
final class _File {
  _File(this.path, this.text, this.directives);

  final String path;
  final String text;
  final List<_Directive> directives;

  Iterable<_Directive> of(String kind) =>
      directives.where((d) => d.kind == kind);

  /// The library it is part of, or itself.
  String get library =>
      of('part of').map((d) => d.target).nonNulls.firstOrNull ?? path;

  bool get holdsParts => of('part').isNotEmpty;

  /// A top-level folder's barrel: `src/<folder>/<folder>.dart`.
  bool get isBarrel {
    final parts = path.split('/');
    return parts.length == 3 &&
        parts[0] == 'src' &&
        parts[2] == '${parts[1]}.dart';
  }

  bool get isPublic => _public.contains(path);

  /// Whether the whole library is marked `@internal library;`.
  bool get isInternalLibrary =>
      RegExp(r'^@internal\s+library\s*;', multiLine: true).hasMatch(text);
}

String? _resolve(String from, String uri) {
  if (uri.startsWith(_package)) {
    return uri.substring(_package.length);
  }
  if (uri.startsWith('package:') || uri.startsWith('dart:')) return null;
  final segments = from.split('/')..removeLast();
  for (final s in uri.split('/')) {
    if (s == '..') {
      segments.removeLast();
    } else if (s != '.') {
      segments.add(s);
    }
  }
  return segments.join('/');
}

/// Every Dart file under lib/, by path from lib/.
Map<String, _File> _readLib() {
  final root = Directory('lib');
  final files = <String, _File>{};
  for (final f in root.listSync(recursive: true).whereType<File>()) {
    if (!f.path.endsWith('.dart')) continue;
    final path = f.path.substring(root.path.length + 1).replaceAll(r'\', '/');
    var text = f.readAsStringSync();
    if (text.startsWith('﻿')) text = text.substring(1);
    files[path] = _File(path, text, [
      for (final m in _directive.allMatches(text))
        for (final u in _uri.allMatches(m.group(2)!))
          _Directive(
            m.group(1)!.replaceAll(RegExp(r'\s+'), ' '),
            u.group(1)!,
            _resolve(path, u.group(1)!),
          ),
    ]);
  }
  return files;
}

/// What [from] exports, itself included, following exports onward.
Set<String> _exportedFrom(Map<String, _File> files, Iterable<String> from) {
  final seen = <String>{};
  final stack = [...from];
  while (stack.isNotEmpty) {
    final path = stack.removeLast();
    if (!seen.add(path)) continue;
    for (final d in files[path]?.of('export') ?? const <_Directive>[]) {
      if (d.target != null) stack.add(d.target!);
    }
  }
  return seen;
}

final _typeDeclaration = RegExp(
  r'^(?:(?:abstract|base|final|interface|sealed|mixin)\s+)*'
  r'(?:class|mixin|enum|typedef|extension\s+type|extension)\s+([A-Za-z_]\w*)',
);

/// The public top-level declarations of [text]: their line and name, and
/// whether `@internal` is among their annotations.
List<({int line, String name, bool internal})> _publicDeclarations(
  String text,
) {
  final lines = text.split('\n');
  final found = <({int line, String name, bool internal})>[];
  var depth = 0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimRight();
    if (depth == 0 &&
        line.isNotEmpty &&
        !line.startsWith(RegExp(r'[\s/*@})\]]')) &&
        !line.startsWith(RegExp(r'(import|export|part|library)\b')) &&
        !line.startsWith(RegExp(r'extension\s+on\b'))) {
      final type = _typeDeclaration.firstMatch(line);
      String? name;
      if (type != null) {
        name = type.group(1);
      } else {
        // A function or variable: the last name before its parameters or
        // value, past any type arguments of its own.
        final head = line
            .split(RegExp(r'[(=;{]'))
            .first
            .trim()
            .replaceFirst(RegExp(r'<[^<>]*>$'), '');
        name = RegExp(r'[A-Za-z_]\w*').allMatches(head).lastOrNull?.group(0);
      }
      if (name != null && !name.startsWith('_')) {
        var internal = false;
        for (var j = i - 1; j >= 0; j--) {
          final above = lines[j].trim();
          if (above.startsWith('@')) {
            internal |= RegExp(r'^@internal\b').hasMatch(above);
          } else if (!above.startsWith('///')) {
            break;
          }
        }
        found.add((line: i + 1, name: name, internal: internal));
      }
    }
    // Brace depth, outside strings and comments, so only top-level lines
    // are read as declarations.
    final code = line
        .replaceAll(RegExp(r"'(?:[^'\\]|\\.)*'"), '')
        .replaceAll(RegExp(r'"(?:[^"\\]|\\.)*"'), '')
        .split('//')
        .first;
    depth += '{'.allMatches(code).length - '}'.allMatches(code).length;
    if (depth < 0) depth = 0;
  }
  return found;
}

/// The feature a file under lib/ belongs to — its top-level folder of
/// lib/src — or null for a public library.
String? _featureOf(String path) {
  final parts = path.split('/');
  return parts.length > 2 && parts[0] == 'src' ? parts[1] : null;
}

/// Every import and export from one feature to another (parts are inside
/// their library's), by (from, to): the directives that make it.
Map<(String, String), List<String>> _featureEdges(Map<String, _File> files) {
  final edges = <(String, String), List<String>>{};
  for (final file in files.values) {
    final from = _featureOf(file.path);
    if (from == null) continue;
    for (final d in [...file.of('import'), ...file.of('export')]) {
      final target = d.target;
      final to = target == null ? null : _featureOf(target);
      if (to == null || to == from) continue;
      (edges[(from, to)] ??= []).add('${file.path} ${d.kind}s ${d.uri}');
    }
  }
  return edges;
}

/// The loops of [graph]: its strongly connected parts of more than one
/// node, each sorted (Tarjan's algorithm).
List<List<String>> _loops(Map<String, Set<String>> graph) {
  final index = <String, int>{};
  final low = <String, int>{};
  final stack = <String>[];
  final onStack = <String>{};
  final loops = <List<String>>[];
  var next = 0;
  void visit(String v) {
    index[v] = low[v] = next++;
    stack.add(v);
    onStack.add(v);
    for (final w in graph[v] ?? const <String>{}) {
      if (!index.containsKey(w)) {
        visit(w);
        low[v] = min(low[v]!, low[w]!);
      } else if (onStack.contains(w)) {
        low[v] = min(low[v]!, index[w]!);
      }
    }
    if (low[v] != index[v]) return;
    final loop = <String>[];
    String w;
    do {
      w = stack.removeLast();
      onStack.remove(w);
      loop.add(w);
    } while (w != v);
    if (loop.length > 1) loops.add(loop..sort());
  }

  final nodes = {...graph.keys, for (final to in graph.values) ...to}.toList()
    ..sort();
  for (final v in nodes) {
    if (!index.containsKey(v)) visit(v);
  }
  return loops;
}

void main() {
  final files = _readLib();
  final exported = _exportedFrom(files, _public);

  test('every file is exported by a public library or is internal', () {
    final problems = <String>[];
    for (final file in files.values) {
      if (!file.path.startsWith('src/')) continue;
      if (exported.contains(file.library)) continue;
      if (_internalByList.containsKey(file.library)) continue;
      if (files[file.library]?.isInternalLibrary ?? false) continue;
      for (final d in _publicDeclarations(file.text)) {
        if (!d.internal) {
          problems.add(
            '${file.path}:${d.line} ${d.name} — exported by no public '
            'library: export it from its barrel, or mark it @internal',
          );
        }
      }
    }
    expect(problems, isEmpty);
  });

  test('the explicit internal list names files that exist', () {
    expect([
      for (final path in _internalByList.keys)
        if (!files.containsKey(path)) path,
    ], isEmpty);
  });

  test('only a barrel or a public library exports, a barrel only its '
      'own folder', () {
    final problems = <String>[];
    for (final file in files.values) {
      final exports = file.of('export').toList();
      if (exports.isEmpty || file.isPublic) continue;
      if (!file.isBarrel) {
        problems.add('${file.path} exports, but is not a barrel');
        continue;
      }
      final folder = '${file.path.substring(0, file.path.lastIndexOf('/'))}/';
      for (final d in exports) {
        if (d.target != null && !d.target!.startsWith(folder)) {
          problems.add('${file.path} exports ${d.uri}, outside its folder');
        }
      }
    }
    expect(problems, isEmpty);
  });

  test('every top-level folder has its barrel', () {
    final folders = files.keys.map(_featureOf).nonNulls.toSet();
    expect([
      for (final folder in folders)
        if (!files.containsKey('src/$folder/$folder.dart'))
          'src/$folder has no barrel src/$folder/$folder.dart',
    ], isEmpty);
  });

  test('a library that holds parts is not a barrel', () {
    expect([
      for (final file in files.values)
        if (file.holdsParts && file.of('export').isNotEmpty) file.path,
    ], isEmpty);
  });

  test('no file imports a barrel that leads back to it', () {
    final problems = <String>[];
    for (final file in files.values) {
      for (final d in file.of('import')) {
        final target = d.target;
        if (target == null || files[target]?.of('export').isEmpty != false) {
          continue;
        }
        final reached = _exportedFrom(files, [target]);
        if (reached.contains(file.library) && target != file.library) {
          problems.add('${file.path} imports ${d.uri}, which exports it');
        }
      }
    }
    expect(problems, isEmpty);
  });

  test('io/ never reaches the web, web/ never reaches dart:io', () {
    final problems = <String>[];
    for (final file in files.values) {
      final feature = _featureOf(file.path);
      for (final d in file.of('import')) {
        if (feature != 'web' && _webOnly.any(d.uri.startsWith)) {
          problems.add('${file.path} imports ${d.uri}, which is web-only');
        }
        if (feature != 'io' && _ioOnly.any(d.uri.startsWith)) {
          problems.add('${file.path} imports ${d.uri}, which is native-only');
        }
        final target = d.target;
        if (target == null || d.kind != 'import') continue;
        final to = _featureOf(target);
        if ((feature == 'io' && to == 'web') ||
            (feature == 'web' && to == 'io')) {
          problems.add('${file.path} imports ${d.uri}, the other platform');
        }
      }
    }
    expect(problems, isEmpty);
  });

  test('only ui/ uses Flutter widgets, and only ui.dart exports it', () {
    final problems = <String>[
      for (final file in files.values)
        if (!file.path.startsWith('src/ui/'))
          for (final d in file.of('import'))
            if (_isFlutterUi(d.uri)) '${file.path} imports ${d.uri}',
      for (final path in _exportedFrom(files, ['just_database.dart']))
        if (path.startsWith('src/ui/')) 'just_database.dart exports $path',
    ];
    expect(problems, isEmpty);
  });

  final features = _featureEdges(files);
  final layerOf = {
    for (var i = 0; i < _layers.length; i++)
      for (final feature in _layers[i]) feature: i,
  };

  test('every feature has one layer, and every layer names a feature', () {
    final folders = files.keys.map(_featureOf).nonNulls.toSet();
    final listed = [for (final layer in _layers) ...layer];
    expect([
      for (final f in folders)
        if (!listed.contains(f)) '$f has no layer',
      for (final f in listed.toSet())
        if (listed.where((l) => l == f).length > 1) '$f is in two layers',
      for (final f in listed)
        if (!folders.contains(f)) '$f is no folder of lib/src',
    ], isEmpty);
  });

  test('no import loop crosses from one feature to another', () {
    final graph = <String, Set<String>>{};
    for (final (from, to) in features.keys) {
      (graph[from] ??= {}).add(to);
    }
    final problems = <String>[];
    for (final loop in _loops(graph)) {
      problems.add('a loop of ${loop.join(', ')}:');
      for (final MapEntry(key: (from, to), value: why) in features.entries) {
        if (loop.contains(from) && loop.contains(to)) {
          problems.addAll(['  $from -> $to', for (final w in why) '    $w']);
        }
      }
    }
    expect(problems, isEmpty);
  });

  test('no feature imports one in a layer above its own', () {
    expect([
      for (final MapEntry(key: (from, to), value: why) in features.entries)
        if ((layerOf[to] ?? -1) > (layerOf[from] ?? _layers.length))
          for (final w in why)
            '$from (layer ${layerOf[from]}) imports $to '
                '(layer ${layerOf[to]}): $w',
    ], isEmpty);
  });

  test('the scanner reads declarations and their annotations', () {
    final found = _publicDeclarations('''
/// Doc.
@internal
final class Kept {
  void method() {}
  static const x = 1;
}

class Plain {}

@internal
Future<int> load() async => 1;

const int limit = 3;

T pick<T>(T a) => a;

extension on int {}

final class _Hidden {}
''');
    expect(found.map((d) => '${d.name}:${d.internal}'), [
      'Kept:true',
      'Plain:false',
      'load:true',
      'limit:false',
      'pick:false',
    ]);
  });

  test('the loop finder finds a loop', () {
    expect(
      _loops({
        'a': {'b'},
        'b': {'a'},
        'c': {'a'},
      }),
      [
        ['a', 'b'],
      ],
    );
  });
}

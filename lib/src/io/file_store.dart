import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show internal;
import 'package:path_provider/path_provider.dart';

import '../persistence/crypto.dart';
import '../persistence/store.dart';

/// Payloads at least this large are encrypted on a background isolate.
const int _isolateThreshold = 64 * 1024;

/// Database files on native platforms: `<app support>/just_database/<name>.jdb`.
///
/// 1.x kept them in the documents directory, which on desktop is shared by
/// every app. A database found only there is copied over the first time it
/// is opened (moved on Android and iOS, where that directory is private to
/// the app); other files there are left alone.
@internal
final class FileStore implements DatabaseStore {
  static const _dirName = 'just_database';
  static const _extension = '.jdb';

  Directory? _dir;
  Directory? _legacyDir;
  bool _legacyChecked = false;
  int _tmpCounter = 0;

  Future<Directory> _directory() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}$_dirName');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return _dir = dir;
  }

  Future<Directory?> _legacy() async {
    if (_legacyChecked) return _legacyDir;
    _legacyChecked = true;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}${Platform.pathSeparator}$_dirName');
      final current = await _directory();
      if (dir.existsSync() && dir.absolute.path != current.absolute.path) {
        _legacyDir = dir;
      }
    } catch (_) {
      // No documents directory on this platform.
    }
    return _legacyDir;
  }

  File _file(Directory dir, String name) =>
      File('${dir.path}${Platform.pathSeparator}$name$_extension');

  bool get _legacyIsPrivate => Platform.isAndroid || Platform.isIOS;

  /// Brings a 1.x file for [name] over from the documents directory.
  Future<void> _adoptLegacy(String name) async {
    final dir = await _directory();
    final target = _file(dir, name);
    if (target.existsSync()) return;
    final legacy = await _legacy();
    if (legacy == null) return;
    final old = _file(legacy, name);
    if (!old.existsSync()) return;
    if (_legacyIsPrivate) {
      try {
        await old.rename(target.path);
        return;
      } on FileSystemException {
        // Another volume: copy below.
      }
    }
    await _writeAtomically(target, await old.readAsBytes());
    if (_legacyIsPrivate) {
      try {
        await old.delete();
      } catch (_) {}
    }
  }

  @override
  String describe(String name) {
    final d = _dir;
    return d == null ? '$name$_extension' : _file(d, name).path;
  }

  @override
  Future<Uint8List?> read(String name) async {
    await _adoptLegacy(name);
    final f = _file(await _directory(), name);
    if (!f.existsSync()) return null;
    return f.readAsBytes();
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    await _writeAtomically(_file(await _directory(), name), bytes);
  }

  @override
  Future<void> delete(String name) async {
    final dir = await _directory();
    final f = _file(dir, name);
    if (f.existsSync()) await f.delete();
    final lockFile = File(
      '${dir.path}${Platform.pathSeparator}$name$_extension-lock',
    );
    try {
      if (lockFile.existsSync()) lockFile.deleteSync();
    } catch (_) {
      // Held by another process: leave it.
    }
    if (_legacyIsPrivate) {
      final legacy = await _legacy();
      if (legacy != null) {
        final old = _file(legacy, name);
        if (old.existsSync()) await old.delete();
      }
    }
  }

  @override
  Future<List<String>> list() async {
    final names = <String>{};
    void scan(Directory d) {
      if (!d.existsSync()) return;
      for (final f in d.listSync().whereType<File>()) {
        final base = f.uri.pathSegments.last;
        if (base.endsWith(_extension)) {
          names.add(base.substring(0, base.length - _extension.length));
        }
      }
    }

    scan(await _directory());
    if (_legacyIsPrivate) {
      final legacy = await _legacy();
      if (legacy != null) scan(legacy);
    }
    return names.toList()..sort();
  }

  @override
  Future<Uint8List?> peek(String name, int length) async {
    await _adoptLegacy(name);
    final f = _file(await _directory(), name);
    if (!f.existsSync()) return null;
    final raf = await f.open();
    try {
      return await raf.read(length);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<int> size(String name) async {
    final f = _file(await _directory(), name);
    return f.existsSync() ? f.lengthSync() : 0;
  }

  @override
  Future<Future<void> Function()> lock(String name) async {
    final dir = await _directory();
    final lockFile = File(
      '${dir.path}${Platform.pathSeparator}$name$_extension-lock',
    );
    final raf = await lockFile.open(mode: FileMode.append);
    try {
      await raf.lock(FileLock.exclusive);
    } on FileSystemException {
      await raf.close();
      throw StateError(
        'database $name is open in another process (${lockFile.path} is locked)',
      );
    }
    _cleanTemporaries(dir, name);
    return () async {
      try {
        raf.unlockSync();
        raf.closeSync();
      } catch (_) {}
    };
  }

  /// Removes `.tmp` files a crash left behind for [name].
  void _cleanTemporaries(Directory dir, String name) {
    final prefix = '$name$_extension.';
    try {
      for (final f in dir.listSync().whereType<File>()) {
        final base = f.uri.pathSegments.last;
        if (base.startsWith(prefix) && base.endsWith('.tmp')) f.deleteSync();
      }
    } catch (_) {}
  }

  /// Writes [bytes] to a uniquely named temporary file next to [target],
  /// flushes it, then renames it over [target], so a crash leaves the old
  /// file or the new one, never a mix.
  Future<void> _writeAtomically(File target, List<int> bytes) async {
    final tmp = File(
      '${target.path}.$pid-${DateTime.now().microsecondsSinceEpoch}'
      '-${_tmpCounter++}.tmp',
    );
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await _renameOver(tmp, target);
    } catch (_) {
      try {
        if (tmp.existsSync()) await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _renameOver(File tmp, File target) async {
    for (var attempt = 1; ; attempt++) {
      try {
        await tmp.rename(target.path);
        return;
      } on FileSystemException {
        // Windows refuses to replace a file that another process (a virus
        // scanner, the search indexer) has open; those handles are brief.
        if (!Platform.isWindows || attempt == 5) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 20 * attempt));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Cryptography, off the UI isolate
  // ---------------------------------------------------------------------------

  @override
  Future<Uint8List> deriveKey(
    String passphrase,
    Uint8List salt,
    int iterations,
  ) => Isolate.run(() => pbkdf2Sha256(passphrase, salt, iterations));

  @override
  Future<Uint8List> seal(
    Uint8List key,
    Uint8List nonce,
    Uint8List plain,
    Uint8List aad,
  ) {
    if (plain.length < _isolateThreshold) {
      return Future.value(aesGcmSeal(key, nonce, plain, aad));
    }
    return Isolate.run(() => aesGcmSeal(key, nonce, plain, aad));
  }

  @override
  Future<Uint8List> open(
    Uint8List key,
    Uint8List nonce,
    Uint8List sealed,
    Uint8List aad,
  ) {
    if (sealed.length < _isolateThreshold) {
      return Future.value(aesGcmOpen(key, nonce, sealed, aad));
    }
    final s = Uint8List.fromList(sealed);
    return Isolate.run(() => aesGcmOpen(key, nonce, s, aad));
  }
}

/// The store for this platform.
@internal
DatabaseStore createPlatformStore() => FileStore();

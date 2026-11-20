/// OPFS-based synchronous byte-level storage driver for web.
///
/// Wraps `FileSystemSyncAccessHandle` from the Origin Private File System API
/// to provide synchronous, in-place reads and writes to `.jdb` files.
/// This driver is intended to run **inside a dedicated Web Worker** only.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Low-level synchronous byte I/O driver backed by OPFS.
///
/// Each instance manages a single file within the `just_database/` OPFS
/// subdirectory. The underlying `FileSystemSyncAccessHandle` holds an exclusive
/// lock on the file for the lifetime of this driver.
class OpfsStorageDriver {
  final String _fileName;
  final web.FileSystemSyncAccessHandle _handle;

  OpfsStorageDriver._({
    required String fileName,
    required web.FileSystemSyncAccessHandle handle,
    required web.FileSystemDirectoryHandle dir,
  }) : _fileName = fileName,
       _handle = handle;

  /// Opens (or creates) a file named `<dbName>.jdb` in the OPFS
  /// `just_database/` directory and acquires a synchronous access handle.
  ///
  /// This takes an **exclusive lock** on the file — no other tab or worker
  /// can open the same file concurrently.
  static Future<OpfsStorageDriver> open(String dbName) async {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    final dir = await root
        .getDirectoryHandle(
          'just_database',
          web.FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;
    final fileName = '$dbName.jdb';
    final fileHandle = await dir
        .getFileHandle(fileName, web.FileSystemGetFileOptions(create: true))
        .toDart;
    final handle = await fileHandle.createSyncAccessHandle().toDart;
    return OpfsStorageDriver._(fileName: fileName, handle: handle, dir: dir);
  }

  /// Returns the name of the underlying file.
  String get fileName => _fileName;

  /// Reads the entire file content.
  Uint8List readAll() {
    final size = _handle.getSize();
    if (size == 0) return Uint8List(0);
    final buffer = Uint8List(size);
    _handle.read(buffer.toJS, web.FileSystemReadWriteOptions(at: 0));
    return buffer;
  }

  /// Overwrites the entire file with [data], truncating to the exact size.
  void writeAll(Uint8List data) {
    _handle.truncate(data.length);
    if (data.isNotEmpty) {
      _handle.write(data.toJS, web.FileSystemReadWriteOptions(at: 0));
    }
    _handle.flush();
  }

  /// Reads [length] bytes starting at byte [offset].
  Uint8List readBytes(int offset, int length) {
    final buffer = Uint8List(length);
    _handle.read(buffer.toJS, web.FileSystemReadWriteOptions(at: offset));
    return buffer;
  }

  /// Writes [data] starting at byte [offset] (in-place, no truncation).
  void writeBytes(int offset, Uint8List data) {
    _handle.write(data.toJS, web.FileSystemReadWriteOptions(at: offset));
    _handle.flush();
  }

  /// Appends [data] at the end of the file.
  void append(Uint8List data) {
    final size = _handle.getSize();
    _handle.write(data.toJS, web.FileSystemReadWriteOptions(at: size));
    _handle.flush();
  }

  /// Returns the current file size in bytes.
  int fileSize() => _handle.getSize();

  /// Truncates the file to [newSize] bytes.
  void truncate(int newSize) {
    _handle.truncate(newSize);
    _handle.flush();
  }

  /// Flushes pending writes to the underlying storage.
  void flush() => _handle.flush();

  /// Releases the exclusive lock and closes the sync access handle.
  void close() => _handle.close();

  /// Deletes a database file from the OPFS `just_database/` directory.
  ///
  /// This is a static method that does not require an open handle.
  static Future<void> deleteFile(String dbName) async {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    try {
      final dir = await root
          .getDirectoryHandle(
            'just_database',
            web.FileSystemGetDirectoryOptions(create: false),
          )
          .toDart;
      await dir.removeEntry('$dbName.jdb').toDart;
    } catch (_) {
      // Directory or file doesn't exist — nothing to delete.
    }
  }

  /// Lists all `.jdb` database file names in the OPFS directory.
  ///
  /// Returns base names without the `.jdb` extension.
  static Future<List<String>> listDatabases() async {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    try {
      final dir = await root
          .getDirectoryHandle(
            'just_database',
            web.FileSystemGetDirectoryOptions(create: false),
          )
          .toDart;
      return _listJdbFiles(dir);
    } catch (_) {
      return [];
    }
  }

  /// Enumerates `.jdb` files in the given directory handle using the
  /// async iterator protocol via JS interop.
  static Future<List<String>> _listJdbFiles(
    web.FileSystemDirectoryHandle dir,
  ) async {
    final names = <String>[];
    // Use the values() async iterator on the directory handle.
    // FileSystemDirectoryHandle is an async iterable of
    // [name, FileSystemHandle] entries. We use the JS `entries()` method.
    final entries = _callEntries(dir);
    while (true) {
      final next = await (entries.callMethod('next'.toJS) as JSPromise).toDart;
      final nextObj = next as JSObject;
      final done = nextObj.getProperty('done'.toJS) as JSBoolean;
      if (done.toDart) break;
      final value = nextObj.getProperty('value'.toJS) as JSArray<JSAny>;
      final name = (value.toDart[0] as JSString).toDart;
      if (name.endsWith('.jdb')) {
        names.add(name.substring(0, name.length - 4));
      }
    }
    return names;
  }

  /// Calls `entries()` on a FileSystemDirectoryHandle to get an async iterator.
  static JSObject _callEntries(web.FileSystemDirectoryHandle dir) {
    return (dir as JSObject).callMethod('entries'.toJS) as JSObject;
  }
}

/// Opens a separate OPFS sync access handle specifically for a WAL file.
///
/// WAL files use the naming convention `<dbName>.wal`.
class OpfsWalDriver {
  final web.FileSystemSyncAccessHandle _handle;

  OpfsWalDriver._(this._handle);

  /// Opens (or creates) the WAL file for [dbName].
  static Future<OpfsWalDriver> open(String dbName) async {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    final dir = await root
        .getDirectoryHandle(
          'just_database',
          web.FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;
    final fileHandle = await dir
        .getFileHandle(
          '$dbName.wal',
          web.FileSystemGetFileOptions(create: true),
        )
        .toDart;
    final handle = await fileHandle.createSyncAccessHandle().toDart;
    return OpfsWalDriver._(handle);
  }

  Uint8List readAll() {
    final size = _handle.getSize();
    if (size == 0) return Uint8List(0);
    final buffer = Uint8List(size);
    _handle.read(buffer.toJS, web.FileSystemReadWriteOptions(at: 0));
    return buffer;
  }

  void writeAll(Uint8List data) {
    _handle.truncate(data.length);
    if (data.isNotEmpty) {
      _handle.write(data.toJS, web.FileSystemReadWriteOptions(at: 0));
    }
    _handle.flush();
  }

  void append(Uint8List data) {
    final size = _handle.getSize();
    _handle.write(data.toJS, web.FileSystemReadWriteOptions(at: size));
    _handle.flush();
  }

  int fileSize() => _handle.getSize();

  void truncate(int newSize) {
    _handle.truncate(newSize);
    _handle.flush();
  }

  void close() => _handle.close();

  /// Deletes a WAL file from the OPFS directory.
  static Future<void> deleteFile(String dbName) async {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    try {
      final dir = await root
          .getDirectoryHandle(
            'just_database',
            web.FileSystemGetDirectoryOptions(create: false),
          )
          .toDart;
      await dir.removeEntry('$dbName.wal').toDart;
    } catch (_) {}
  }
}

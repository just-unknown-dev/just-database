import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:path_provider/path_provider.dart';
import '../core/database_mode.dart';
import 'serialization.dart';
import 'table.dart';

/// A snapshot of a persisted database loaded from disk.
class DatabaseSnapshot {
  final String name;
  final DatabaseMode mode;
  final Map<String, Table> tables;

  const DatabaseSnapshot({
    required this.name,
    required this.mode,
    required this.tables,
  });
}

/// Handles reading and writing database files to device storage.
///
/// Within an isolate, operations on the same database run one at a time, in
/// call order, so a load or delete never sees a save half done. Saves write a
/// uniquely named temporary file and rename it over the database file, so the
/// file always holds a complete snapshot, even after a crash mid-save.
class PersistenceManager {
  static const String _dirName = 'just_database';
  static const String _extension = '.jdb';

  /// Tail of the operation queue for each database, keyed by lower-cased name
  /// (file names are case-insensitive on Windows and macOS).
  static final Map<String, Future<void>> _queues = {};

  static int _tmpCounter = 0;

  /// Runs [operation] once every earlier operation on [name] has finished.
  static Future<T> _serialised<T>(String name, Future<T> Function() operation) {
    final key = name.toLowerCase();
    final result = (_queues[key] ?? Future<void>.value()).then(
      (_) => operation(),
    );
    final tail = result.then<void>((_) {}, onError: (Object _) {});
    _queues[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_queues[key], tail)) _queues.remove(key);
      }),
    );
    return result;
  }

  static Future<Directory> _getDatabaseDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}$_dirName');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  static String _fileName(String name) => '$name$_extension';

  /// Saves all tables of [name] to `<docs>/just_database/<name>.jdb`.
  ///
  /// The snapshot is taken when this is called; the write itself waits for
  /// earlier operations on [name] and replaces the file atomically.
  ///
  /// When [encryptionKey] is provided the file is AES-256-GCM encrypted.
  /// The 12-byte randomly generated IV is prepended to the ciphertext so each
  /// save produces a unique file even for identical data.
  static Future<void> save(
    String name,
    Map<String, Table> tables,
    DatabaseMode mode, {
    String? encryptionKey,
  }) async {
    // Encode before the first await, so later changes to [tables] cannot
    // leak into this snapshot.
    final plain = utf8.encode(jsonEncode(_encodeDatabase(tables, mode)));
    final bytes = encryptionKey != null
        ? _encrypt(plain, encryptionKey)
        : plain;
    await _serialised(name, () async {
      final dir = await _getDatabaseDir();
      await _writeAtomically(_file(dir, name), bytes);
    });
  }

  /// Loads a database from disk. Returns null if the file does not exist.
  ///
  /// When [encryptionKey] is provided the file is AES-256-GCM decrypted before
  /// parsing. Throws a [StateError] when the file exists but cannot be read,
  /// decrypted (e.g. a wrong key) or decoded; the file is left untouched.
  static Future<DatabaseSnapshot?> load(String name, {String? encryptionKey}) {
    return _serialised(name, () async {
      final dir = await _getDatabaseDir();
      final file = _file(dir, name);
      if (!file.existsSync()) return null;

      final List<int> raw;
      try {
        raw = await file.readAsBytes();
      } on FileSystemException catch (e) {
        throw _loadError(name, file, 'it could not be read ($e)');
      }

      String content;
      if (encryptionKey != null) {
        try {
          content = utf8.decode(_decrypt(raw, encryptionKey));
        } catch (_) {
          throw StateError(
            'Failed to decrypt database "$name". '
            'The encryption key may be incorrect or the file is corrupt.',
          );
        }
      } else {
        try {
          content = utf8.decode(raw);
        } on FormatException {
          throw _loadError(
            name,
            file,
            'it is not UTF-8 text. It may be an encrypted (secure-mode) '
            'database opened without its key',
          );
        }
      }

      try {
        final json = jsonDecode(content) as Map<String, dynamic>;

        final modeStr = json['mode'] as String? ?? 'standard';
        final mode = DatabaseMode.values.firstWhere(
          (m) => m.name == modeStr,
          orElse: () => DatabaseMode.standard,
        );

        final tables = _decodeTables(
          json['tables'] as Map<String, dynamic>? ?? {},
        );

        return DatabaseSnapshot(name: name, mode: mode, tables: tables);
      } catch (e) {
        throw _loadError(name, file, 'it is corrupt ($e)');
      }
    });
  }

  static StateError _loadError(String name, File file, String reason) =>
      StateError(
        'Cannot load database "$name" from ${file.path}: $reason. '
        'The file was left untouched; restore it from a backup, or move or '
        'delete it to start with an empty database.',
      );

  /// Reads the [DatabaseMode] stored in a persisted file without fully loading
  /// all table data.
  ///
  /// For plain (unencrypted) databases the mode is read from the JSON header.
  /// For encrypted (secure) databases the content is not valid UTF-8 JSON, so
  /// [DatabaseMode.secure] is returned automatically — no key required.
  /// Returns [DatabaseMode.standard] if the file does not exist or cannot be
  /// parsed.
  static Future<DatabaseMode> peekMode(String name) {
    return _serialised(name, () async {
      final dir = await _getDatabaseDir();
      final file = _file(dir, name);
      if (!file.existsSync()) return DatabaseMode.standard;
      try {
        final content = await file.readAsString();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final modeStr = json['mode'] as String? ?? 'standard';
        return DatabaseMode.values.firstWhere(
          (m) => m.name == modeStr,
          orElse: () => DatabaseMode.standard,
        );
      } catch (_) {
        // Content is not valid UTF-8 JSON → encrypted secure-mode file.
        return DatabaseMode.secure;
      }
    });
  }

  /// Deletes the database file. Does nothing if the file does not exist.
  ///
  /// Runs after any save of [name] already queued, so that save cannot bring
  /// the file back.
  static Future<void> delete(String name) {
    return _serialised(name, () async {
      final dir = await _getDatabaseDir();
      final file = _file(dir, name);
      if (file.existsSync()) await file.delete();
    });
  }

  /// Lists all database names that have a persisted file.
  static Future<List<String>> listPersistedNames() async {
    final dir = await _getDatabaseDir();
    if (!dir.existsSync()) return [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith(_extension))
        .toList();
    return files.map((f) {
      final base = f.path.split(Platform.pathSeparator).last;
      return base.substring(0, base.length - _extension.length);
    }).toList();
  }

  /// Returns file size in bytes, or 0 if the file does not exist.
  static Future<int> getFileSize(String name) async {
    final dir = await _getDatabaseDir();
    final file = _file(dir, name);
    if (!file.existsSync()) return 0;
    return file.lengthSync();
  }

  static File _file(Directory dir, String name) =>
      File('${dir.path}${Platform.pathSeparator}${_fileName(name)}');

  /// Writes [bytes] to a uniquely named temporary file next to [target], then
  /// renames it over [target]. Readers see the old file or the new one, never
  /// a partial write. The name ends in `.tmp`, so [listPersistedNames]
  /// ignores it.
  static Future<void> _writeAtomically(File target, List<int> bytes) async {
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

  static Future<void> _renameOver(File tmp, File target) async {
    for (var attempt = 1; ; attempt++) {
      try {
        await tmp.rename(target.path);
        return;
      } on FileSystemException {
        // Windows refuses to replace a file that another process (a virus
        // scanner, the search indexer) has open. Those handles are short-lived.
        if (!Platform.isWindows || attempt == 5) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 20 * attempt));
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Encode / Decode
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // AES-256-GCM helpers
  // ---------------------------------------------------------------------------

  /// Encrypts [plainBytes] with AES-256-GCM derived from [password].
  /// Returns [IV (12 bytes)] + [ciphertext + GCM auth tag].
  /// 12-byte nonce is the standard / recommended size for AES-GCM.
  static Uint8List _encrypt(List<int> plainBytes, String password) {
    final keyBytes = sha256.convert(utf8.encode(password)).bytes;
    final key = enc.Key(Uint8List.fromList(keyBytes));
    final iv = enc.IV.fromSecureRandom(
      12,
    ); // 12-byte (96-bit) nonce for AES-GCM
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    final encrypted = encrypter.encryptBytes(
      Uint8List.fromList(plainBytes),
      iv: iv,
    );
    return Uint8List.fromList([...iv.bytes, ...encrypted.bytes]);
  }

  /// Decrypts data produced by [_encrypt] using [password].
  /// Throws if the auth tag is invalid (wrong key or tampered file).
  static List<int> _decrypt(List<int> cipherWithIv, String password) {
    if (cipherWithIv.length < 12) {
      throw const FormatException('Encrypted data is too short.');
    }
    final keyBytes = sha256.convert(utf8.encode(password)).bytes;
    final key = enc.Key(Uint8List.fromList(keyBytes));
    final iv = enc.IV(
      Uint8List.fromList(cipherWithIv.sublist(0, 12)),
    ); // 12-byte nonce
    final cipherBytes = enc.Encrypted(
      Uint8List.fromList(cipherWithIv.sublist(12)),
    );
    final encrypter = enc.Encrypter(enc.AES(key, mode: enc.AESMode.gcm));
    return encrypter.decryptBytes(cipherBytes, iv: iv);
  }

  static Map<String, dynamic> _encodeDatabase(
    Map<String, Table> tables,
    DatabaseMode mode,
  ) => DatabaseSerializer.encodeDatabase(tables, mode);

  static Map<String, Table> _decodeTables(Map<String, dynamic> json) =>
      DatabaseSerializer.decodeTables(json);
}

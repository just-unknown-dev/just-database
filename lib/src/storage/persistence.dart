import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:path_provider/path_provider.dart';
import '../core/database_mode.dart';
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
class PersistenceManager {
  static const String _dirName = 'just_database';
  static const String _extension = '.jdb';

  static Future<Directory> _getDatabaseDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}${Platform.pathSeparator}$_dirName');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  static String _fileName(String name) => '$name$_extension';

  /// Saves all tables of [name] to `<docs>/just_database/<name>.jdb`.
  ///
  /// When [encryptionKey] is provided the file is AES-256-GCM encrypted.
  /// The 16-byte randomly generated IV is prepended to the ciphertext so each
  /// save produces a unique file even for identical data.
  static Future<void> save(
    String name,
    Map<String, Table> tables,
    DatabaseMode mode, {
    String? encryptionKey,
  }) async {
    final dir = await _getDatabaseDir();
    final file = File('${dir.path}${Platform.pathSeparator}${_fileName(name)}');
    final json = _encodeDatabase(tables, mode);
    final jsonString = jsonEncode(json);
    if (encryptionKey != null) {
      final encrypted = _encrypt(utf8.encode(jsonString), encryptionKey);
      await file.writeAsBytes(encrypted, flush: true);
    } else {
      await file.writeAsString(jsonString, flush: true);
    }
  }

  /// Loads a database from disk. Returns null if the file does not exist.
  ///
  /// When [encryptionKey] is provided the file is AES-256-GCM decrypted before
  /// parsing. Supplying the wrong key will throw a [StateError].
  static Future<DatabaseSnapshot?> load(
    String name, {
    String? encryptionKey,
  }) async {
    final dir = await _getDatabaseDir();
    final file = File('${dir.path}${Platform.pathSeparator}${_fileName(name)}');
    if (!file.existsSync()) return null;

    String content;
    if (encryptionKey != null) {
      final raw = await file.readAsBytes();
      try {
        content = utf8.decode(_decrypt(raw, encryptionKey));
      } catch (_) {
        throw StateError(
          'Failed to decrypt database "$name". '
          'The encryption key may be incorrect or the file is corrupt.',
        );
      }
    } else {
      content = await file.readAsString();
    }

    final json = jsonDecode(content) as Map<String, dynamic>;

    final modeStr = json['mode'] as String? ?? 'standard';
    final mode = DatabaseMode.values.firstWhere(
      (m) => m.name == modeStr,
      orElse: () => DatabaseMode.standard,
    );

    final tables = _decodeTables(json['tables'] as Map<String, dynamic>? ?? {});

    return DatabaseSnapshot(name: name, mode: mode, tables: tables);
  }

  /// Reads the [DatabaseMode] stored in a persisted file without fully loading
  /// all table data.
  ///
  /// For plain (unencrypted) databases the mode is read from the JSON header.
  /// For encrypted (secure) databases the content is not valid UTF-8 JSON, so
  /// [DatabaseMode.secure] is returned automatically — no key required.
  /// Returns [DatabaseMode.standard] if the file does not exist or cannot be
  /// parsed.
  static Future<DatabaseMode> peekMode(String name) async {
    final dir = await _getDatabaseDir();
    final file = File('${dir.path}${Platform.pathSeparator}${_fileName(name)}');
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
  }

  /// Deletes the database file. Does nothing if the file does not exist.
  static Future<void> delete(String name) async {
    final dir = await _getDatabaseDir();
    final file = File('${dir.path}${Platform.pathSeparator}${_fileName(name)}');
    if (file.existsSync()) await file.delete();
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
    final file = File('${dir.path}${Platform.pathSeparator}${_fileName(name)}');
    if (!file.existsSync()) return 0;
    return file.lengthSync();
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
  ) {
    return {
      'version': 1,
      'mode': mode.name,
      'tables': {
        for (final entry in tables.entries) entry.key: entry.value.toJson(),
      },
    };
  }

  static Map<String, Table> _decodeTables(Map<String, dynamic> json) {
    return {
      for (final entry in json.entries)
        entry.key: Table.fromJson(entry.value as Map<String, dynamic>),
    };
  }
}

import 'dart:async';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:just_storage/just_storage.dart';

import '../persistence/crypto.dart' show randomBytes;
import '../io/file_store.dart'
    if (dart.library.js_interop) '../web/idb_store.dart';

/// Keys for encrypted databases, kept in `just_storage`'s encrypted store.
///
/// A database already derives its AES key from the `encryptionKey`
/// passphrase (PBKDF2, random salt per file), so you can pass a user's
/// password straight to `JustDatabase.open`. This class covers two other
/// cases:
///
/// * [resolveAutoKey]: a random key generated once and stored, for
///   encryption without asking the user anything.
/// * [resolveKey]: a key derived from a password with a salt stored
///   per database (the 1.x way; still needed to open databases created
///   with it).
///
/// What the stored key protects against: someone who copies the `.jdb`
/// file alone. `just_storage` keeps its own key in the app's private
/// storage (not in a hardware keystore), so someone with full access to
/// the app's data directory can recover the database key too.
abstract final class SecureKeyManager {
  static const int _legacyIterations = 310000;
  static const int _keyLength = 32;
  static const int _saltLength = 16;
  static const String _saltV2 = 'v2:';

  static final Map<String, Future<Object?>> _queues = {};

  /// Runs [action] after every earlier call for [dbName] has finished, so
  /// two first calls cannot both create a key or salt.
  static Future<T> _serialized<T>(String dbName, Future<T> Function() action) {
    final key = dbName.toLowerCase();
    final previous = _queues[key] ?? Future<Object?>.value();
    final result = previous.then(
      (_) => action(),
      onError: (Object _) => action(),
    );
    _queues[key] = result.then<Object?>((v) => v, onError: (Object _) => null);
    return result;
  }

  static String _saltStorageKey(String dbName) => 'just_database_salt_$dbName';
  static String _autoKeyStorageKey(String dbName) =>
      'just_database_auto_key_$dbName';

  /// The key for [dbName] derived from [password] by PBKDF2-HMAC-SHA256
  /// with a salt stored on first use, as a 64-character hex string.
  ///
  /// The derivation runs off the UI thread (an isolate on native,
  /// WebCrypto on the web). Throws [ArgumentError] for an empty password.
  static Future<String> resolveKey({
    required String dbName,
    required String password,
  }) {
    if (password.isEmpty) {
      throw ArgumentError('The password must not be empty.', 'password');
    }
    return _serialized(dbName, () async {
      final secure = await JustStorage.encrypted();
      final saltKey = _saltStorageKey(dbName);
      var stored = await secure.read(saltKey);
      if (stored == null) {
        stored = '$_saltV2${_hex(randomBytes(_saltLength))}';
        await secure.write(saltKey, stored);
      }
      if (stored.startsWith(_saltV2)) {
        final salt = _unhex(stored.substring(_saltV2.length));
        final key = await createPlatformStore().deriveKey(
          password,
          salt,
          _legacyIterations,
        );
        return _hex(key);
      }
      // A 1.x salt: derive as 1.x did (password code units as bytes), so
      // existing databases still open.
      final salt = _unhex(stored);
      final key = await compute(_legacyPbkdf2, (
        password: password,
        salt: salt,
      ));
      return _hex(key);
    });
  }

  /// Deletes the stored salt for [dbName]. A database encrypted with a key
  /// from [resolveKey] cannot be opened afterwards.
  static Future<void> clearSalt({required String dbName}) =>
      _serialized(dbName, () async {
        final secure = await JustStorage.encrypted();
        await secure.delete(_saltStorageKey(dbName));
      });

  /// A random key for [dbName], generated and stored on first use, as a
  /// 64-character hex string.
  static Future<String> resolveAutoKey({required String dbName}) =>
      _serialized(dbName, () async {
        final secure = await JustStorage.encrypted();
        final storageKey = _autoKeyStorageKey(dbName);
        var key = await secure.read(storageKey);
        if (key == null) {
          final rng = Random.secure();
          key = _hex(
            Uint8List.fromList(
              List.generate(_keyLength, (_) => rng.nextInt(256)),
            ),
          );
          await secure.write(storageKey, key);
        }
        return key;
      });

  /// Deletes the stored key for [dbName]. Its database cannot be opened
  /// afterwards; call this when deleting the database.
  static Future<void> clearAutoKey({required String dbName}) =>
      _serialized(dbName, () async {
        final secure = await JustStorage.encrypted();
        await secure.delete(_autoKeyStorageKey(dbName));
      });

  /// Whether [resolveAutoKey] has stored a key for [dbName].
  static Future<bool> hasAutoKey({required String dbName}) =>
      _serialized(dbName, () async {
        final secure = await JustStorage.encrypted();
        return await secure.read(_autoKeyStorageKey(dbName)) != null;
      });

  /// Whether a key or salt is stored for [dbName].
  static Future<bool> hasStoredKey({required String dbName}) =>
      _serialized(dbName, () async {
        final secure = await JustStorage.encrypted();
        return await secure.read(_autoKeyStorageKey(dbName)) != null ||
            await secure.read(_saltStorageKey(dbName)) != null;
      });

  // ---------------------------------------------------------------------------

  static Uint8List _legacyPbkdf2(({String password, Uint8List salt}) a) {
    // 1.x used the password's UTF-16 code units truncated to bytes.
    final hmac = Hmac(sha256, Uint8List.fromList(a.password.codeUnits));
    final block = Uint8List(a.salt.length + 4)
      ..setAll(0, a.salt)
      ..[a.salt.length + 3] = 1;
    var u = Uint8List.fromList(hmac.convert(block).bytes);
    final t = Uint8List.fromList(u);
    for (var j = 1; j < _legacyIterations; j++) {
      u = Uint8List.fromList(hmac.convert(u).bytes);
      for (var k = 0; k < t.length; k++) {
        t[k] ^= u[k];
      }
    }
    return t;
  }

  static String _hex(Uint8List bytes) {
    const digits = '0123456789abcdef';
    final b = StringBuffer();
    for (final x in bytes) {
      b
        ..writeCharCode(digits.codeUnitAt(x >> 4))
        ..writeCharCode(digits.codeUnitAt(x & 15));
    }
    return b.toString();
  }

  static Uint8List _unhex(String hex) => Uint8List.fromList([
    for (var i = 0; i + 1 < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

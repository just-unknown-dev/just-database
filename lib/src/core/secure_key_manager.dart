import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:just_storage/just_storage.dart';

/// Manages the lifecycle of a database encryption key derived from a user
/// password via **PBKDF2-HMAC-SHA256**.
///
/// The random salt is generated once (on first use) and persisted in
/// [JustSecureStorage] — an AES-256-GCM encrypted key-value store provided by
/// the `just_storage` companion package.  Only the salt is stored; the
/// password and the derived key are **never** written to disk.
///
/// **Typical usage:**
/// ```dart
/// final key = await SecureKeyManager.resolveKey(
///   dbName: 'vault',
///   password: 'user-entered-password',
/// );
/// final db = await JustDatabase.open(
///   'vault',
///   mode: DatabaseMode.secure,
///   encryptionKey: key,
/// );
/// ```
///
/// To discard the salt (e.g. when the user changes their password or the
/// database is deleted) call [clearSalt]:
/// ```dart
/// await SecureKeyManager.clearSalt(dbName: 'vault');
/// ```
class SecureKeyManager {
  SecureKeyManager._();

  // Number of PBKDF2 iterations — NIST recommends ≥ 310 000 for SHA-256
  // but 100 000 is a reasonable default that doesn't block the UI noticeably
  // on low-end devices when called once at login time.
  static const int _iterations = 100000;

  // Output key length in bytes (32 bytes = 256-bit AES key).
  static const int _keyLength = 32;

  // Salt length in bytes.
  static const int _saltLength = 16;

  /// Returns the storage key under which the salt for [dbName] is saved.
  static String _saltStorageKey(String dbName) => 'just_database_salt_$dbName';

  /// Resolves (or creates) the AES-256 encryption key for [dbName].
  ///
  /// On first call a fresh [_saltLength]-byte random salt is generated and
  /// persisted via [JustSecureStorage]. On all subsequent calls the stored
  /// salt is loaded and the same password produces the same key deterministically.
  ///
  /// Throws [ArgumentError] if [password] is empty.
  static Future<String> resolveKey({
    required String dbName,
    required String password,
  }) async {
    if (password.isEmpty) {
      throw ArgumentError.value(
        password,
        'password',
        'Password cannot be empty.',
      );
    }

    final secure = await JustStorage.encrypted();
    final saltKey = _saltStorageKey(dbName);

    String? saltHex = await secure.read(saltKey);
    if (saltHex == null) {
      // First run — generate and persist a random salt.
      final rng = Random.secure();
      final saltBytes = Uint8List.fromList(
        List.generate(_saltLength, (_) => rng.nextInt(256)),
      );
      saltHex = _bytesToHex(saltBytes);
      await secure.write(saltKey, saltHex);
    }

    final salt = _hexToBytes(saltHex);
    final keyBytes = _pbkdf2HmacSha256(password, salt, _iterations, _keyLength);
    return _bytesToHex(keyBytes);
  }

  /// Deletes the persisted salt for [dbName].
  ///
  /// After calling this, [resolveKey] will generate a new salt on its next
  /// invocation.  **This makes the old derived key irrecoverable** — any
  /// existing encrypted `.jdb` file for [dbName] will be unreadable unless you
  /// still have the old salt.  Use before deleting or resetting a database.
  static Future<void> clearSalt({required String dbName}) async {
    final secure = await JustStorage.encrypted();
    await secure.delete(_saltStorageKey(dbName));
  }

  // ---------------------------------------------------------------------------
  // Auto-key API — no user password required
  // ---------------------------------------------------------------------------

  static String _autoKeyStorageKey(String dbName) =>
      'just_database_auto_key_$dbName';

  /// Returns a fully-managed AES-256 encryption key for [dbName].
  ///
  /// On first call a cryptographically random 32-byte key is generated with
  /// [Random.secure] and stored in [JustSecureStorage] (AES-256-GCM encrypted
  /// by `just_storage`).  On every subsequent call the stored key is returned
  /// as-is — no password is ever required from the user.
  ///
  /// Use this when you want transparent encryption without user interaction.
  static Future<String> resolveAutoKey({required String dbName}) async {
    final secure = await JustStorage.encrypted();
    final storageKey = _autoKeyStorageKey(dbName);

    String? keyHex = await secure.read(storageKey);
    if (keyHex == null) {
      // First run — generate a random 32-byte key and persist it.
      final rng = Random.secure();
      final keyBytes = Uint8List.fromList(
        List.generate(_keyLength, (_) => rng.nextInt(256)),
      );
      keyHex = _bytesToHex(keyBytes);
      await secure.write(storageKey, keyHex);
    }
    return keyHex;
  }

  /// Deletes the auto-managed key for [dbName] from secure storage.
  ///
  /// **This makes the database permanently unreadable** unless you still hold
  /// the key value.  Call this when the database file is also being deleted.
  static Future<void> clearAutoKey({required String dbName}) async {
    final secure = await JustStorage.encrypted();
    await secure.delete(_autoKeyStorageKey(dbName));
  }

  // ---------------------------------------------------------------------------
  // PBKDF2-HMAC-SHA256 implementation using the `crypto` package.
  // ---------------------------------------------------------------------------

  /// Derives a [dkLen]-byte key from [password] and [salt] using
  /// PBKDF2-HMAC-SHA256 with [c] iterations.
  static Uint8List _pbkdf2HmacSha256(
    String password,
    Uint8List salt,
    int c,
    int dkLen,
  ) {
    final passwordBytes = Uint8List.fromList(password.codeUnits);
    final hmac = Hmac(sha256, passwordBytes);

    // Number of 32-byte blocks needed.
    final blockCount = (dkLen / 32).ceil();
    final result = Uint8List(blockCount * 32);

    for (var i = 1; i <= blockCount; i++) {
      // U1 = PRF(Password, Salt || INT(i))
      final saltBlock = Uint8List(salt.length + 4);
      saltBlock.setAll(0, salt);
      saltBlock[salt.length] = (i >> 24) & 0xff;
      saltBlock[salt.length + 1] = (i >> 16) & 0xff;
      saltBlock[salt.length + 2] = (i >> 8) & 0xff;
      saltBlock[salt.length + 3] = i & 0xff;

      var u = Uint8List.fromList(hmac.convert(saltBlock).bytes);
      final t = Uint8List.fromList(u); // T_i starts as U1

      // U2..Uc = PRF(Password, U_{j-1});  T_i = XOR of all U_j
      for (var j = 1; j < c; j++) {
        u = Uint8List.fromList(hmac.convert(u).bytes);
        for (var k = 0; k < t.length; k++) {
          t[k] ^= u[k];
        }
      }

      result.setAll((i - 1) * 32, t);
    }

    return result.sublist(0, dkLen);
  }

  // ---------------------------------------------------------------------------
  // Hex helpers
  // ---------------------------------------------------------------------------

  static String _bytesToHex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static Uint8List _hexToBytes(String hex) {
    final length = hex.length ~/ 2;
    return Uint8List.fromList(
      List.generate(
        length,
        (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16),
      ),
    );
  }
}

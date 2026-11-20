import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show internal;
import 'package:pointycastle/export.dart';

/// PBKDF2-HMAC-SHA256 iterations for new files (OWASP 2023).
@internal
const int defaultKdfIterations = 600000;

/// The bytes an encrypted file of format 2 starts with: `JDB` and 2.
@internal
const List<int> encryptedMagic = [0x4A, 0x44, 0x42, 0x02];

const int _kdfPbkdf2Sha256 = 1;
const int _saltLength = 16;
const int _nonceLength = 12;

final _random = Random.secure();

/// [length] cryptographically random bytes.
@internal
Uint8List randomBytes(int length) =>
    Uint8List.fromList([for (var i = 0; i < length; i++) _random.nextInt(256)]);

/// The cryptography a platform provides: key derivation and AES-256-GCM.
/// Native code runs it on a background isolate; the web uses WebCrypto.
@internal
abstract interface class CryptoBackend {
  /// PBKDF2-HMAC-SHA256 of [passphrase] (UTF-8) with [salt]: 32 bytes.
  Future<Uint8List> deriveKey(
    String passphrase,
    Uint8List salt,
    int iterations,
  );

  /// AES-256-GCM: the ciphertext with its 16-byte tag appended.
  Future<Uint8List> seal(
    Uint8List key,
    Uint8List nonce,
    Uint8List plain,
    Uint8List aad,
  );

  /// Opens what [seal] made. Throws [StateError] when the tag does not
  /// match (wrong key, or the data was changed).
  Future<Uint8List> open(
    Uint8List key,
    Uint8List nonce,
    Uint8List sealed,
    Uint8List aad,
  );
}

/// PBKDF2-HMAC-SHA256 in pure Dart.
@internal
Uint8List pbkdf2Sha256(String passphrase, Uint8List salt, int iterations) {
  final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(salt, iterations, 32));
  return d.process(Uint8List.fromList(utf8.encode(passphrase)));
}

/// AES-256-GCM in pure Dart; see [CryptoBackend.seal].
@internal
Uint8List aesGcmSeal(
  Uint8List key,
  Uint8List nonce,
  Uint8List plain,
  Uint8List aad,
) {
  final c = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), 128, nonce, aad));
  return c.process(plain);
}

/// AES-256-GCM in pure Dart; see [CryptoBackend.open].
@internal
Uint8List aesGcmOpen(
  Uint8List key,
  Uint8List nonce,
  Uint8List sealed,
  Uint8List aad,
) {
  try {
    final c = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), 128, nonce, aad));
    return c.process(sealed);
  } on InvalidCipherTextException {
    throw StateError('authentication failed');
  } on ArgumentError {
    throw StateError('authentication failed');
  }
}

/// The key of one encrypted database: its salt, iteration count and the
/// derived AES key.
@internal
final class FileKey {
  /// Wraps a derived key.
  FileKey(this.salt, this.iterations, this.key);

  final Uint8List salt;
  final int iterations;
  final Uint8List key;

  /// Derives a key for [passphrase] with a new random salt.
  static Future<FileKey> create(CryptoBackend c, String passphrase) async {
    final salt = randomBytes(_saltLength);
    final key = await c.deriveKey(passphrase, salt, defaultKdfIterations);
    return FileKey(salt, defaultKdfIterations, key);
  }
}

/// Whether [bytes] look like an encrypted database rather than JSON.
@internal
bool looksEncrypted(Uint8List bytes) {
  for (final b in bytes) {
    if (b == 0x20 ||
        b == 0x09 ||
        b == 0x0A ||
        b == 0x0D ||
        b == 0xEF ||
        b == 0xBB ||
        b == 0xBF) {
      continue;
    }
    return b != 0x7B; // '{'
  }
  return false;
}

/// Encrypts [plain] as format 2:
///
/// `JDB\x02` | kdf (1) | iterations (4, big-endian) | salt length (1) | salt
/// | nonce (12) | ciphertext with tag. The whole header is authenticated.
@internal
Future<Uint8List> sealDatabase(
  CryptoBackend c,
  FileKey k,
  Uint8List plain,
) async {
  final nonce = randomBytes(_nonceLength);
  final header = BytesBuilder()
    ..add(encryptedMagic)
    ..addByte(_kdfPbkdf2Sha256)
    ..add([
      (k.iterations >> 24) & 0xFF,
      (k.iterations >> 16) & 0xFF,
      (k.iterations >> 8) & 0xFF,
      k.iterations & 0xFF,
    ])
    ..addByte(k.salt.length)
    ..add(k.salt)
    ..add(nonce);
  final h = header.toBytes();
  final sealed = await c.seal(k.key, nonce, plain, h);
  return (BytesBuilder()
        ..add(h)
        ..add(sealed))
      .toBytes();
}

/// Decrypts an encrypted database file with [passphrase]. Returns the plain
/// bytes and the key to save with: [cached] when it still fits, a freshly
/// derived one otherwise, or null for a 1.x file (whose key is a bare
/// SHA-256 of the passphrase; the next save writes format 2).
///
/// Throws [StateError] when the passphrase is wrong or the file damaged.
@internal
Future<(Uint8List, FileKey?)> openDatabase(
  CryptoBackend c,
  String passphrase,
  Uint8List bytes, {
  FileKey? cached,
}) async {
  if (bytes.length > 4 &&
      bytes[0] == encryptedMagic[0] &&
      bytes[1] == encryptedMagic[1] &&
      bytes[2] == encryptedMagic[2] &&
      bytes[3] == encryptedMagic[3]) {
    final parsed = _parseHeader(bytes);
    if (parsed != null) {
      final (iterations, salt, nonce, headerLength) = parsed;
      var key = cached;
      if (key == null ||
          key.iterations != iterations ||
          !_sameBytes(key.salt, salt)) {
        key = FileKey(
          salt,
          iterations,
          await c.deriveKey(passphrase, salt, iterations),
        );
      }
      final plain = await c.open(
        key.key,
        nonce,
        Uint8List.sublistView(bytes, headerLength),
        Uint8List.sublistView(bytes, 0, headerLength),
      );
      return (plain, key);
    }
  }
  // Format 1: IV (12) | ciphertext | tag, key = SHA-256(passphrase).
  if (bytes.length < _nonceLength + 16) {
    throw StateError('encrypted database file is too short');
  }
  final legacyKey = Uint8List.fromList(
    crypto.sha256.convert(utf8.encode(passphrase)).bytes,
  );
  final plain = await c.open(
    legacyKey,
    Uint8List.sublistView(bytes, 0, _nonceLength),
    Uint8List.sublistView(bytes, _nonceLength),
    Uint8List(0),
  );
  return (plain, null);
}

(int, Uint8List, Uint8List, int)? _parseHeader(Uint8List b) {
  if (b.length < 4 + 1 + 4 + 1) return null;
  if (b[4] != _kdfPbkdf2Sha256) return null;
  final iterations = (b[5] << 24) | (b[6] << 16) | (b[7] << 8) | b[8];
  final saltLength = b[9];
  final headerLength = 10 + saltLength + _nonceLength;
  if (iterations < 1 || saltLength < 8 || b.length < headerLength + 16) {
    return null;
  }
  return (
    iterations,
    Uint8List.fromList(b.sublist(10, 10 + saltLength)),
    Uint8List.fromList(b.sublist(10 + saltLength, headerLength)),
    headerLength,
  );
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Compares two strings in time that does not depend on where they differ.
@internal
bool constantTimeEquals(String a, String b) {
  final x = utf8.encode(a), y = utf8.encode(b);
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length && i < y.length; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

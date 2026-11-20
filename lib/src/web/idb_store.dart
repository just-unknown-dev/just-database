import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show internal;
import 'package:web/web.dart' as web;

import '../persistence/crypto.dart';
import '../persistence/store.dart';

/// Database files in IndexedDB (database `just_database`, store
/// `databases`, keyed by name). 1.x stored JSON strings there; they are
/// read as they are and replaced by bytes on the next save.
@internal
final class IdbStore implements DatabaseStore {
  static const _idbName = 'just_database';
  static const _storeName = 'databases';

  // One connection for every IdbStore: they all use the same database.
  static web.IDBDatabase? _db;

  Future<web.IDBDatabase> _open() async {
    final cached = _db;
    if (cached != null) return cached;
    web.IDBOpenDBRequest request;
    try {
      request = web.window.indexedDB.open(_idbName, 1);
    } catch (e) {
      throw StorageUnavailableException('IndexedDB is not available: $e');
    }
    request.onupgradeneeded = ((web.Event _) {
      final db = request.result as web.IDBDatabase;
      if (!db.objectStoreNames.contains(_storeName)) {
        db.createObjectStore(_storeName);
      }
    }).toJS;
    try {
      final db = (await _await(request)) as web.IDBDatabase;
      db.onversionchange = ((web.Event _) {
        db.close();
        _db = null;
      }).toJS;
      return _db = db;
    } catch (e) {
      throw StorageUnavailableException('IndexedDB could not be opened: $e');
    }
  }

  static Future<JSAny?> _await(web.IDBRequest request) {
    final c = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) {
      if (!c.isCompleted) c.complete(request.result);
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!c.isCompleted) {
        c.completeError(
          StateError('IndexedDB request failed: ${request.error?.message}'),
        );
      }
    }).toJS;
    return c.future;
  }

  /// Runs [body] in a transaction and waits until it commits (or fails or
  /// aborts, which surface as errors rather than a hang).
  Future<JSAny?> _transaction(
    String mode,
    web.IDBRequest Function(web.IDBObjectStore store) body,
  ) async {
    final db = await _open();
    final tx = db.transaction(_storeName.toJS, mode);
    final done = Completer<void>();
    tx.oncomplete = ((web.Event _) {
      if (!done.isCompleted) done.complete();
    }).toJS;
    tx.onerror = ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(
          StateError('IndexedDB transaction failed: ${tx.error?.message}'),
        );
      }
    }).toJS;
    tx.onabort = ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(
          StateError('IndexedDB transaction aborted: ${tx.error?.message}'),
        );
      }
    }).toJS;
    final request = body(tx.objectStore(_storeName));
    final result = await _await(request);
    await done.future;
    return result;
  }

  @override
  String describe(String name) => 'IndexedDB $_idbName/$_storeName/$name';

  @override
  Future<Uint8List?> read(String name) async {
    final value = await _transaction('readonly', (s) => s.get(name.toJS));
    if (value == null) return null;
    if (value.isA<JSString>()) {
      return Uint8List.fromList(utf8.encode((value as JSString).toDart));
    }
    if (value.isA<JSUint8Array>()) return (value as JSUint8Array).toDart;
    if (value.isA<JSArrayBuffer>()) {
      return (value as JSArrayBuffer).toDart.asUint8List();
    }
    throw StateError('unexpected value stored for database $name');
  }

  @override
  Future<void> write(String name, Uint8List bytes) async {
    await _transaction('readwrite', (s) => s.put(bytes.toJS, name.toJS));
  }

  @override
  Future<void> delete(String name) async {
    await _transaction('readwrite', (s) => s.delete(name.toJS));
  }

  @override
  Future<List<String>> list() async {
    final keys = await _transaction('readonly', (s) => s.getAllKeys());
    if (keys == null || !keys.isA<JSArray>()) return const [];
    return [
      for (final k in (keys as JSArray<JSAny?>).toDart)
        if (k != null && k.isA<JSString>()) (k as JSString).toDart,
    ]..sort();
  }

  @override
  Future<int> size(String name) async => (await read(name))?.length ?? 0;

  @override
  Future<Uint8List?> peek(String name, int length) async {
    final bytes = await read(name);
    if (bytes == null || bytes.length <= length) return bytes;
    return Uint8List.sublistView(bytes, 0, length);
  }

  @override
  Future<Future<void> Function()> lock(String name) async {
    final web.LockManager locks;
    try {
      locks = web.window.navigator.locks;
    } catch (_) {
      return () async {}; // No Web Locks: last writer wins between tabs.
    }
    final granted = Completer<bool>();
    final released = Completer<void>();
    JSPromise<JSAny?> onGrant(web.Lock? lock) {
      if (lock == null) {
        granted.complete(false);
        return Future<JSAny?>.value().toJS;
      }
      granted.complete(true);
      return released.future.then<JSAny?>((_) => null).toJS;
    }

    JSPromise<JSAny?> request;
    try {
      request = locks.request(
        'just_database:$name',
        web.LockOptions(ifAvailable: true),
        onGrant.toJS,
      );
    } catch (_) {
      return () async {};
    }
    if (!await granted.future) {
      throw StateError('database $name is open in another browser tab');
    }
    return () async {
      if (!released.isCompleted) released.complete();
      // The browser frees the lock once the callback's promise settles;
      // the request's own promise settles after that.
      try {
        await request.toDart;
      } catch (_) {}
    };
  }

  // ---------------------------------------------------------------------------
  // WebCrypto (pure Dart where the page is not a secure context)
  // ---------------------------------------------------------------------------

  static web.SubtleCrypto? get _subtle {
    try {
      return web.window.isSecureContext ? web.window.crypto.subtle : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List> deriveKey(
    String passphrase,
    Uint8List salt,
    int iterations,
  ) async {
    final subtle = _subtle;
    if (subtle == null) return pbkdf2Sha256(passphrase, salt, iterations);
    final base = await subtle
        .importKey(
          'raw',
          Uint8List.fromList(utf8.encode(passphrase)).toJS,
          _Algorithm(name: 'PBKDF2'),
          false,
          <JSString>['deriveBits'.toJS].toJS,
        )
        .toDart;
    final bits = await subtle
        .deriveBits(
          _Pbkdf2Params(
            name: 'PBKDF2',
            salt: salt.toJS,
            iterations: iterations,
            hash: 'SHA-256',
          ),
          base,
          256,
        )
        .toDart;
    return bits.toDart.asUint8List();
  }

  Future<web.CryptoKey> _aesKey(web.SubtleCrypto subtle, Uint8List key) =>
      subtle
          .importKey(
            'raw',
            key.toJS,
            _Algorithm(name: 'AES-GCM'),
            false,
            <JSString>['encrypt'.toJS, 'decrypt'.toJS].toJS,
          )
          .toDart;

  @override
  Future<Uint8List> seal(
    Uint8List key,
    Uint8List nonce,
    Uint8List plain,
    Uint8List aad,
  ) async {
    final subtle = _subtle;
    if (subtle == null) return aesGcmSeal(key, nonce, plain, aad);
    final k = await _aesKey(subtle, key);
    final result = await subtle
        .encrypt(
          _AesGcmParams(
            name: 'AES-GCM',
            iv: nonce.toJS,
            additionalData: aad.toJS,
          ),
          k,
          plain.toJS,
        )
        .toDart;
    return (result as JSArrayBuffer).toDart.asUint8List();
  }

  @override
  Future<Uint8List> open(
    Uint8List key,
    Uint8List nonce,
    Uint8List sealed,
    Uint8List aad,
  ) async {
    final subtle = _subtle;
    if (subtle == null) return aesGcmOpen(key, nonce, sealed, aad);
    final k = await _aesKey(subtle, key);
    try {
      final result = await subtle
          .decrypt(
            _AesGcmParams(
              name: 'AES-GCM',
              iv: nonce.toJS,
              additionalData: aad.toJS,
            ),
            k,
            sealed.toJS,
          )
          .toDart;
      return (result as JSArrayBuffer).toDart.asUint8List();
    } catch (_) {
      throw StateError('authentication failed');
    }
  }
}

/// The store for this platform.
@internal
DatabaseStore createPlatformStore() => IdbStore();

extension type _Algorithm._(JSObject _) implements JSObject {
  external factory _Algorithm({required String name});
}

extension type _Pbkdf2Params._(JSObject _) implements JSObject {
  external factory _Pbkdf2Params({
    required String name,
    required JSUint8Array salt,
    required int iterations,
    required String hash,
  });
}

extension type _AesGcmParams._(JSObject _) implements JSObject {
  external factory _AesGcmParams({
    required String name,
    required JSUint8Array iv,
    required JSUint8Array additionalData,
  });
}

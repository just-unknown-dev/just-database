import 'dart:typed_data';

import 'package:flutter/foundation.dart' show internal;

import 'crypto.dart';

/// Thrown by a [DatabaseStore] whose storage cannot be used at all (no
/// IndexedDB in a private window, blocked storage); `JustDatabase.open`
/// then falls back to an in-memory database.
@internal
final class StorageUnavailableException implements Exception {
  /// Creates the exception.
  StorageUnavailableException(this.reason);

  /// What went wrong.
  final String reason;

  @override
  String toString() => 'StorageUnavailableException: $reason';
}

/// Where a platform keeps database files, and its cryptography.
///
/// Native code stores `<name>.jdb` files in the app's support directory;
/// the web stores them in IndexedDB.
@internal
abstract interface class DatabaseStore implements CryptoBackend {
  /// The stored bytes of [name], or null when there is none.
  Future<Uint8List?> read(String name);

  /// Replaces the stored bytes of [name] atomically: a reader sees the old
  /// bytes or the new ones, never a mix.
  Future<void> write(String name, Uint8List bytes);

  /// Removes [name]. Does nothing when it does not exist.
  Future<void> delete(String name);

  /// The names that have stored bytes.
  Future<List<String>> list();

  /// The stored size of [name] in bytes (0 when none).
  Future<int> size(String name);

  /// The first [length] stored bytes of [name] (fewer when it is shorter),
  /// or null when there is none.
  Future<Uint8List?> peek(String name, int length);

  /// Claims [name] for this process, so that another process (or browser
  /// tab) cannot open it at the same time. Returns the release function,
  /// whose future completes once the claim is really given up. Throws
  /// [StateError] when it is held elsewhere.
  Future<Future<void> Function()> lock(String name);

  /// A human-readable place, for messages (a path, or `IndexedDB`).
  String describe(String name);
}

/// Why [name] is not a valid database name, or null when it is. A name is
/// 1-128 letters, digits, `_`, `.` or `-`, does not start with `.` or `-`,
/// has no `..`, does not end with `.`, and is not a Windows device name
/// such as `CON`.
@internal
String? databaseNameProblem(String name) {
  if (name.isEmpty) return 'Enter a name.';
  if (name.length > 128) return 'Use at most 128 characters.';
  if (!RegExp(r'^[A-Za-z0-9_.\-]+$').hasMatch(name)) {
    return 'Use only letters, digits, "_", "." and "-".';
  }
  if (name.startsWith('.') || name.startsWith('-')) {
    return 'The name must not start with "." or "-".';
  }
  if (name.contains('..')) return 'The name must not contain "..".';
  if (name.endsWith('.')) return 'The name must not end with ".".';
  if (RegExp(
    r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(\..*)?$',
    caseSensitive: false,
  ).hasMatch(name)) {
    return '"$name" is reserved by the operating system.';
  }
  return null;
}

/// Throws [ArgumentError] unless [name] is a valid database name (see
/// [databaseNameProblem]).
@internal
void validateDatabaseName(String name) {
  final problem = databaseNameProblem(name);
  if (problem != null) throw ArgumentError.value(name, 'name', problem);
}

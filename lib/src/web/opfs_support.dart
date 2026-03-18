/// OPFS (Origin Private File System) feature detection for web.
///
/// Determines the level of OPFS support available in the current browser
/// environment. This is used to select the appropriate storage strategy.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// The level of OPFS support available in the current environment.
enum OpfsCapability {
  /// Full synchronous access via `createSyncAccessHandle` inside a worker.
  full,

  /// OPFS directory is available but only with async APIs (no sync handles).
  asyncOnly,

  /// OPFS is not available at all.
  none,
}

/// Detects the current environment's OPFS capability.
///
/// Must be called from any context (main thread or worker). The [full]
/// capability is only meaningful inside a dedicated Web Worker.
Future<OpfsCapability> detectOpfsCapability() async {
  try {
    // Check if navigator.storage.getDirectory exists
    final storage = web.window.navigator.storage;
    final root = await storage.getDirectory().toDart;

    // Try to create a temporary probe file and get a sync handle
    const probeName = '.just_db_probe';
    try {
      final fileHandle = await root
          .getFileHandle(probeName, web.FileSystemGetFileOptions(create: true))
          .toDart;
      final syncHandle = await fileHandle.createSyncAccessHandle().toDart;
      syncHandle.close();
      // Clean up probe file
      await root.removeEntry(probeName).toDart;
      return OpfsCapability.full;
    } catch (_) {
      // Sync handle not available (e.g. main thread or restricted env)
      // But OPFS directory access is available
      try {
        await root.removeEntry(probeName).toDart;
      } catch (_) {}
      return OpfsCapability.asyncOnly;
    }
  } catch (_) {
    return OpfsCapability.none;
  }
}

/// Returns `true` if the current environment supports OPFS at all.
Future<bool> isOpfsAvailable() async {
  final cap = await detectOpfsCapability();
  return cap != OpfsCapability.none;
}

import 'package:flutter/foundation.dart' show internal;

/// A backup or export file the admin UI saved earlier.
@internal
final class ExportFile {
  /// Creates an entry.
  const ExportFile({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modified,
  });

  /// The file name.
  final String name;

  /// Where it is.
  final String path;

  /// Its size in bytes.
  final int sizeBytes;

  /// When it was last written.
  final DateTime modified;
}

/// A text file the user picked.
@internal
typedef PickedTextFile = ({String name, String content});

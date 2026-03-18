/// Write-Ahead Log (WAL) manager for web OPFS persistence.
///
/// Provides crash-safe write performance by appending statement deltas to a
/// separate `.wal` file, avoiding full database rewrites on every mutation.
/// On `open()`, the WAL is replayed on top of the main `.jdb` snapshot.
/// Periodic checkpointing compacts the WAL back into the main file.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'opfs_storage.dart';

/// A single WAL entry representing a mutation applied to the database.
class WalEntry {
  /// Monotonically increasing sequence number.
  final int sequence;

  /// The type of this entry.
  final WalEntryType type;

  /// JSON-encoded payload describing the mutation.
  ///
  /// For [WalEntryType.statement], this contains:
  /// ```json
  /// { "table": "name", "op": "insert|update|delete|ddl",
  ///   "sql": "original SQL", "affected": <int> }
  /// ```
  /// For [WalEntryType.checkpoint], payload is empty.
  final Map<String, dynamic> payload;

  const WalEntry({
    required this.sequence,
    required this.type,
    required this.payload,
  });
}

/// The type of a WAL entry.
enum WalEntryType {
  /// A DML/DDL statement delta.
  statement(0),

  /// A checkpoint marker — all preceding entries have been merged into `.jdb`.
  checkpoint(1);

  final int code;
  const WalEntryType(this.code);

  static WalEntryType fromCode(int code) {
    switch (code) {
      case 0:
        return WalEntryType.statement;
      case 1:
        return WalEntryType.checkpoint;
      default:
        return WalEntryType.statement;
    }
  }
}

/// Manages the Write-Ahead Log file for a single database.
///
/// Binary WAL format per entry:
/// ```
/// [4 bytes: payload length (uint32 LE)]
/// [4 bytes: CRC32 checksum of payload]
/// [8 bytes: sequence number (uint64 LE)]
/// [1 byte:  entry type code]
/// [N bytes: UTF-8 JSON payload]
/// ```
///
/// Header size: 17 bytes per entry.
class WalManager {
  static const int _headerSize = 17;
  static const int _maxWalSize = 1024 * 1024; // 1 MB
  static const int _maxWalEntries = 1000;

  final OpfsWalDriver _driver;
  int _nextSequence = 0;
  int _entryCount = 0;

  WalManager._(this._driver);

  /// Opens the WAL driver for [dbName].
  static Future<WalManager> open(String dbName) async {
    final driver = await OpfsWalDriver.open(dbName);
    return WalManager._(driver);
  }

  /// Current number of WAL entries since the last checkpoint.
  int get entryCount => _entryCount;

  /// Whether the WAL should be checkpointed (size or entry count exceeded).
  bool get shouldCheckpoint =>
      _driver.fileSize() > _maxWalSize || _entryCount > _maxWalEntries;

  /// Appends a statement entry to the WAL.
  void append(Map<String, dynamic> payload) {
    _writeEntry(WalEntryType.statement, payload);
    _entryCount++;
  }

  /// Replays all valid WAL entries from the file.
  ///
  /// Stops at the first corrupt or truncated entry. Invalid entries at the tail
  /// are silently discarded (incomplete writes from a crash).
  List<WalEntry> replay() {
    final raw = _driver.readAll();
    if (raw.isEmpty) return const [];

    final entries = <WalEntry>[];
    int offset = 0;

    while (offset + _headerSize <= raw.length) {
      // Read header
      final payloadLength = _readUint32(raw, offset);
      final storedCrc = _readUint32(raw, offset + 4);
      final sequence = _readUint64(raw, offset + 8);
      final typeCode = raw[offset + 16];

      // Validate we have enough bytes for the payload
      if (offset + _headerSize + payloadLength > raw.length) {
        break; // Truncated entry — stop replay
      }

      // Extract and validate payload
      final payloadBytes = Uint8List.sublistView(
        raw,
        offset + _headerSize,
        offset + _headerSize + payloadLength,
      );
      final computedCrc = _crc32(payloadBytes);
      if (computedCrc != storedCrc) {
        break; // Corrupt entry — stop replay
      }

      final payloadJson =
          jsonDecode(utf8.decode(payloadBytes)) as Map<String, dynamic>;

      entries.add(
        WalEntry(
          sequence: sequence,
          type: WalEntryType.fromCode(typeCode),
          payload: payloadJson,
        ),
      );

      offset += _headerSize + payloadLength;
    }

    _nextSequence = entries.isEmpty ? 0 : entries.last.sequence + 1;
    _entryCount = entries.length;
    return entries;
  }

  /// Checkpoints: truncates the WAL file (caller should write the full `.jdb`
  /// first).
  void checkpoint() {
    _writeEntry(WalEntryType.checkpoint, const {});
    _driver.truncate(0);
    _entryCount = 0;
  }

  /// Closes the WAL file handle.
  void close() => _driver.close();

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  void _writeEntry(WalEntryType type, Map<String, dynamic> payload) {
    final payloadBytes = utf8.encode(jsonEncode(payload));
    final crc = _crc32(Uint8List.fromList(payloadBytes));
    final sequence = _nextSequence++;

    final header = Uint8List(_headerSize);
    _writeUint32(header, 0, payloadBytes.length);
    _writeUint32(header, 4, crc);
    _writeUint64(header, 8, sequence);
    header[16] = type.code;

    // Write header + payload as a single append
    final entry = Uint8List(_headerSize + payloadBytes.length);
    entry.setAll(0, header);
    entry.setAll(_headerSize, payloadBytes);
    _driver.append(entry);
  }

  // ---------------------------------------------------------------------------
  // Binary helpers
  // ---------------------------------------------------------------------------

  static int _readUint32(Uint8List buf, int offset) {
    return buf[offset] |
        (buf[offset + 1] << 8) |
        (buf[offset + 2] << 16) |
        (buf[offset + 3] << 24);
  }

  static void _writeUint32(Uint8List buf, int offset, int value) {
    buf[offset] = value & 0xFF;
    buf[offset + 1] = (value >> 8) & 0xFF;
    buf[offset + 2] = (value >> 16) & 0xFF;
    buf[offset + 3] = (value >> 24) & 0xFF;
  }

  static int _readUint64(Uint8List buf, int offset) {
    // JS integers are 53-bit safe; sufficient for sequence numbers.
    return buf[offset] |
        (buf[offset + 1] << 8) |
        (buf[offset + 2] << 16) |
        (buf[offset + 3] << 24) |
        (buf[offset + 4] << 32) |
        (buf[offset + 5] << 40) |
        (buf[offset + 6] << 48);
    // Bit 7 intentionally omitted — stays within safe integer range.
  }

  static void _writeUint64(Uint8List buf, int offset, int value) {
    buf[offset] = value & 0xFF;
    buf[offset + 1] = (value >> 8) & 0xFF;
    buf[offset + 2] = (value >> 16) & 0xFF;
    buf[offset + 3] = (value >> 24) & 0xFF;
    buf[offset + 4] = (value >> 32) & 0xFF;
    buf[offset + 5] = (value >> 40) & 0xFF;
    buf[offset + 6] = (value >> 48) & 0xFF;
    buf[offset + 7] = 0; // High byte always 0 for safe integers.
  }

  // ---------------------------------------------------------------------------
  // CRC-32 (IEEE 802.3 — same polynomial as gzip/PNG)
  // ---------------------------------------------------------------------------

  static final List<int> _crc32Table = _buildCrc32Table();

  static List<int> _buildCrc32Table() {
    final table = List<int>.filled(256, 0);
    for (int i = 0; i < 256; i++) {
      int crc = i;
      for (int j = 0; j < 8; j++) {
        if (crc & 1 == 1) {
          crc = (crc >> 1) ^ 0xEDB88320;
        } else {
          crc = crc >> 1;
        }
      }
      table[i] = crc;
    }
    return table;
  }

  static int _crc32(Uint8List data) {
    int crc = 0xFFFFFFFF;
    for (int i = 0; i < data.length; i++) {
      crc = _crc32Table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFF;
  }
}

/// The concurrency mode for a [JustDatabase] instance.
enum DatabaseMode {
  /// Balanced read/write: a simple mutex per table.
  /// Both reads and writes acquire an exclusive lock.
  /// Correct and simple — good for general-purpose use.
  standard,

  /// Read-optimized: readers-writer lock per table.
  /// Many readers can hold the lock simultaneously.
  /// Writers are exclusive and writer-preference prevents starvation.
  readFast,

  /// Write-optimized: writes are buffered and committed in batches.
  /// A timer (100ms) drains the buffer automatically.
  /// Reads that target a buffered table flush it first.
  writeFast,

  /// Encrypted at rest: the persisted `.jdb` file is AES-256-GCM encrypted
  /// before being written to disk and decrypted on load.
  /// Requires an [encryptionKey] to be supplied to [JustDatabase.open].
  /// Uses the same concurrency model as [standard].
  secure,
}

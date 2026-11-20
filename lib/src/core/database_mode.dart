/// How a database orders statements and when it saves.
///
/// Every mode runs statements one at a time: the engine is synchronous and
/// in memory, so a statement never sees another half done.
/// `JustDatabase.transaction` holds the database for the whole
/// transaction, and other callers wait their turn. Encryption is not a
/// mode: pass an `encryptionKey` to `JustDatabase.open` with any of them.
enum DatabaseMode {
  /// Statements run in the order they are called, and each committed
  /// change starts a save (saves that pile up merge into one).
  standard,

  /// As [standard], but a SELECT runs at once instead of queueing behind
  /// writes that were called before it (it still waits for an open
  /// `transaction()`).
  readFast,

  /// As [standard], but saves are batched: committed changes are written
  /// at most once per `JustDatabase.writeFastDelay` (250 ms). A crash can
  /// lose the changes of that window; call `flush()` to save at once.
  writeFast,
}

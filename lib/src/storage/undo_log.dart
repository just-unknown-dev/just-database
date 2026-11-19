import 'package:flutter/foundation.dart' show internal;

/// The log that makes statements, savepoints and transactions undoable.
///
/// Every change to the catalog or a table records how to undo itself.
/// A statement takes a [mark] before it runs and [rollbackTo]s it if it
/// fails; a transaction keeps the log until COMMIT ([clear]) or ROLLBACK.
/// Outside a statement or transaction nothing is recorded.
@internal
final class UndoLog {
  final List<void Function()> _entries = [];
  int _holds = 0;

  /// How many changes were made, ever (undos do not count). Compared
  /// before and after to tell whether anything changed.
  int mutations = 0;

  /// Whether changes are being recorded.
  bool get recording => _holds > 0;

  /// The number of recorded entries.
  int get length => _entries.length;

  /// Starts recording (nestable); returns the current position.
  int hold() {
    _holds++;
    return _entries.length;
  }

  /// Stops one [hold]. When the last hold ends, the log is cleared.
  void release() {
    if (_holds == 0) throw StateError('UndoLog.release without hold');
    _holds--;
    if (_holds == 0) _entries.clear();
  }

  /// The current position, to roll back to later.
  int mark() => _entries.length;

  /// Records [undo], if recording.
  void record(void Function() undo) {
    mutations++;
    if (_holds > 0) _entries.add(undo);
  }

  /// Undoes every entry recorded after [mark], newest first.
  void rollbackTo(int mark) {
    // Undone changes no longer count, so a rolled-back statement leaves
    // [mutations] where it was.
    mutations -= _entries.length - mark;
    while (_entries.length > mark) {
      _entries.removeLast()();
    }
  }
}

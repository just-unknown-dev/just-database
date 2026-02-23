import 'dart:async';
import 'dart:collection';
import '../core/database_mode.dart';

/// Abstract lock manager interface.
/// Controls concurrent access to table resources.
abstract class LockManager {
  Future<void> acquireRead(String resource);
  void releaseRead(String resource);
  Future<void> acquireWrite(String resource);
  void releaseWrite(String resource);

  Future<T> withRead<T>(String resource, Future<T> Function() action) async {
    await acquireRead(resource);
    try {
      return await action();
    } finally {
      releaseRead(resource);
    }
  }

  Future<T> withWrite<T>(String resource, Future<T> Function() action) async {
    await acquireWrite(resource);
    try {
      return await action();
    } finally {
      releaseWrite(resource);
    }
  }

  /// Factory: creates the appropriate manager for [mode].
  factory LockManager.forMode(DatabaseMode mode) {
    switch (mode) {
      case DatabaseMode.standard:
      case DatabaseMode
          .secure: // Encryption is a storage concern; use standard locks.
        return StandardLockManager();
      case DatabaseMode.readFast:
        return ReadFastLockManager();
      case DatabaseMode.writeFast:
        return WriteFastLockManager();
    }
  }
}

// =============================================================================
// STANDARD — simple mutex per resource
// Both reads and writes acquire an exclusive lock.
// =============================================================================

class StandardLockManager implements LockManager {
  final Map<String, _Mutex> _mutexes = {};

  _Mutex _getMutex(String r) => _mutexes.putIfAbsent(r, () => _Mutex());

  @override
  Future<void> acquireRead(String r) => _getMutex(r).acquire();

  @override
  void releaseRead(String r) => _getMutex(r).release();

  @override
  Future<void> acquireWrite(String r) => _getMutex(r).acquire();

  @override
  void releaseWrite(String r) => _getMutex(r).release();

  @override
  Future<T> withRead<T>(String r, Future<T> Function() action) async {
    await acquireRead(r);
    try {
      return await action();
    } finally {
      releaseRead(r);
    }
  }

  @override
  Future<T> withWrite<T>(String r, Future<T> Function() action) async {
    await acquireWrite(r);
    try {
      return await action();
    } finally {
      releaseWrite(r);
    }
  }
}

/// Simple async mutex backed by a queue of Completers.
class _Mutex {
  bool _locked = false;
  final Queue<Completer<void>> _queue = Queue();

  Future<void> acquire() {
    if (!_locked) {
      _locked = true;
      return Future.value();
    }
    final c = Completer<void>();
    _queue.add(c);
    return c.future;
  }

  void release() {
    if (_queue.isNotEmpty) {
      _queue.removeFirst().complete();
    } else {
      _locked = false;
    }
  }
}

// =============================================================================
// READ FAST — readers-writer lock with writer preference
// Many concurrent readers; writers are exclusive and preferred over new readers.
// =============================================================================

class ReadFastLockManager implements LockManager {
  final Map<String, _ReadWriteLock> _locks = {};

  _ReadWriteLock _getLock(String r) =>
      _locks.putIfAbsent(r, () => _ReadWriteLock());

  @override
  Future<void> acquireRead(String r) => _getLock(r).acquireRead();

  @override
  void releaseRead(String r) => _getLock(r).releaseRead();

  @override
  Future<void> acquireWrite(String r) => _getLock(r).acquireWrite();

  @override
  void releaseWrite(String r) => _getLock(r).releaseWrite();

  @override
  Future<T> withRead<T>(String r, Future<T> Function() action) async {
    await acquireRead(r);
    try {
      return await action();
    } finally {
      releaseRead(r);
    }
  }

  @override
  Future<T> withWrite<T>(String r, Future<T> Function() action) async {
    await acquireWrite(r);
    try {
      return await action();
    } finally {
      releaseWrite(r);
    }
  }
}

class _ReadWriteLock {
  int _activeReaders = 0;
  bool _writerActive = false;
  int _waitingWriters = 0;

  final Queue<Completer<void>> _readerQueue = Queue();
  final Queue<Completer<void>> _writerQueue = Queue();

  Future<void> acquireRead() {
    // Allow immediately if no writer active or queued (writer-preference)
    if (!_writerActive && _waitingWriters == 0) {
      _activeReaders++;
      return Future.value();
    }
    final c = Completer<void>();
    _readerQueue.add(c);
    return c.future;
  }

  void releaseRead() {
    _activeReaders--;
    if (_activeReaders == 0 && _writerQueue.isNotEmpty) {
      _writerActive = true;
      _waitingWriters--;
      _writerQueue.removeFirst().complete();
    }
  }

  Future<void> acquireWrite() {
    if (!_writerActive && _activeReaders == 0) {
      _writerActive = true;
      return Future.value();
    }
    _waitingWriters++;
    final c = Completer<void>();
    _writerQueue.add(c);
    return c.future;
  }

  void releaseWrite() {
    _writerActive = false;
    if (_writerQueue.isNotEmpty) {
      // Writer preference: wake next writer first
      _writerActive = true;
      _waitingWriters--;
      _writerQueue.removeFirst().complete();
    } else {
      // Wake all queued readers simultaneously
      while (_readerQueue.isNotEmpty) {
        _activeReaders++;
        _readerQueue.removeFirst().complete();
      }
    }
  }
}

// =============================================================================
// WRITE FAST — buffered writes with periodic batch flush
// Writes are collected in a buffer and committed on a 100ms timer.
// Reads flush the buffer for the target table before executing.
// =============================================================================

class WriteFastLockManager implements LockManager {
  final Duration flushInterval;
  final Map<String, List<_PendingFlush>> _buffer = {};
  final Map<String, _Mutex> _flushMutexes = {};
  Timer? _flushTimer;

  WriteFastLockManager({Duration? flushInterval})
    : flushInterval = flushInterval ?? const Duration(milliseconds: 100);

  _Mutex _getFlushMutex(String r) =>
      _flushMutexes.putIfAbsent(r, () => _Mutex());

  /// Acquires a read lock: flushes any pending writes for [resource] first.
  @override
  Future<void> acquireRead(String resource) async {
    await _flushResource(resource);
  }

  @override
  void releaseRead(String resource) {
    // No-op for reads in write-fast mode
  }

  /// Acquires a write lock: adds a pending flush entry for [resource].
  /// The returned future completes when the write has been flushed.
  @override
  Future<void> acquireWrite(String resource) async {
    // For write-fast, writes proceed immediately — buffering is at a higher level.
    // The lock here is used to prevent writes during a flush.
    await _getFlushMutex(resource).acquire();
  }

  @override
  void releaseWrite(String resource) {
    _getFlushMutex(resource).release();
    _scheduleFlush();
  }

  /// Registers that a write was performed for [resource], returning a future
  /// that completes when the write is acknowledged (after flush).
  Future<void> notifyWrite(String resource) {
    final c = Completer<void>();
    _buffer.putIfAbsent(resource, () => []).add(_PendingFlush(c));
    _scheduleFlush();
    return c.future;
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(flushInterval, _flushAll);
  }

  void _flushAll() {
    _flushTimer = null;
    for (final resource in List.of(_buffer.keys)) {
      _flushResource(resource);
    }
  }

  Future<void> _flushResource(String resource) async {
    final pending = _buffer.remove(resource);
    if (pending == null || pending.isEmpty) return;

    await _getFlushMutex(resource).acquire();
    try {
      for (final p in pending) {
        p.complete();
      }
    } finally {
      _getFlushMutex(resource).release();
    }
  }

  @override
  Future<T> withRead<T>(String r, Future<T> Function() action) async {
    await acquireRead(r);
    try {
      return await action();
    } finally {
      releaseRead(r);
    }
  }

  @override
  Future<T> withWrite<T>(String r, Future<T> Function() action) async {
    await acquireWrite(r);
    try {
      return await action();
    } finally {
      releaseWrite(r);
    }
  }

  void dispose() {
    _flushTimer?.cancel();
    _flushAll();
  }
}

class _PendingFlush {
  final Completer<void> _completer;

  _PendingFlush(this._completer);

  void complete() {
    if (!_completer.isCompleted) _completer.complete();
  }
}

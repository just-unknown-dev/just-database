import 'dart:async';

import 'package:flutter/foundation.dart' show internal;

/// A first-come, first-served async mutex.
@internal
final class AsyncLock {
  Future<void> _tail = Future<void>.value();
  int _waiting = 0;

  /// Whether anything holds or waits for the lock.
  bool get isBusy => _waiting > 0;

  /// Runs [action] once every earlier holder has finished.
  Future<T> run<T>(FutureOr<T> Function() action) {
    _waiting++;
    final result = _tail.then((_) => action());
    _tail = result
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _waiting--);
    return result;
  }
}

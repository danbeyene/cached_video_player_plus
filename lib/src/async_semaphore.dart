import 'dart:async';
import 'dart:collection';

/// A global semaphore to control concurrent pre-cache operations.
/// 
/// It supports dynamic resizing of the concurrency limit based on the system state
/// (e.g., reducing concurrency when a video is actively playing).
class AsyncSemaphore {
  AsyncSemaphore._();
  static final AsyncSemaphore instance = AsyncSemaphore._();

  int _maxConcurrent = 4; // Default to High (Idle state)
  int _inUse = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  /// Updates the maximum number of concurrent tasks.
  /// 
  /// If the limit is increased, waiting tasks are released immediately.
  void setMaxConcurrent(int newMax) {
    if (newMax < 0) newMax = 0; // Minimum strictness
    _maxConcurrent = newMax;
    
    // Release waiters if we have capacity
    while (_inUse < _maxConcurrent && _waiters.isNotEmpty) {
      _inUse++;
      _waiters.removeFirst().complete();
    }
  }

  /// Acquires a permit. Returns a Future that completes when the permit is granted.
  Future<void> acquire() {
    if (_inUse < _maxConcurrent) {
      _inUse++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  /// Releases a permit, potentially allowing a waiting task to proceed.
  void release() {
    _inUse--;
    if (_inUse < 0) _inUse = 0; // Safety net

    if (_waiters.isNotEmpty && _inUse < _maxConcurrent) {
      _inUse++;
      _waiters.removeFirst().complete();
    }
  }
}

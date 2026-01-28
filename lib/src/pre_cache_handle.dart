import 'dart:async';

/// Handle for a pre-cache operation that can be cancelled.
///
/// When [CachedVideoPlayerPlus.preCacheVideo] is called, it returns a
/// [PreCacheHandle] that allows you to:
/// - Check if the pre-cache is still in progress via [isActive]
/// - Cancel the pre-cache operation via [cancel]
/// - Wait for the pre-cache to complete via [done]
///
/// Example:
/// ```dart
/// final handle = CachedVideoPlayerPlus.preCacheVideo(
///   Uri.parse('https://example.com/video.mp4'),
/// );
///
/// // Later, if user starts playing before pre-cache completes:
/// handle.cancel();
/// ```
class PreCacheHandle {
  /// Creates a new [PreCacheHandle].
  PreCacheHandle({
    required this.cacheKey,
    required Future<void> Function(bool Function() checkCancelled) downloadTask,
  }) {
    _startDownload(downloadTask);
  }

  /// The cache key for this pre-cache operation.
  final String cacheKey;

  /// Completer that signals when the download is complete or cancelled.
  final Completer<void> _completer = Completer<void>();

  /// Whether this pre-cache has been cancelled.
  bool _isCancelled = false;

  /// Whether this pre-cache is still active (not completed and not cancelled).
  bool _isActive = true;

  /// Returns true if this pre-cache has been cancelled.
  bool get isCancelled => _isCancelled;

  /// Returns true if the pre-cache is still in progress.
  bool get isActive => _isActive;

  /// A future that completes when the pre-cache is done or cancelled.
  Future<void> get done => _completer.future;

  /// Cancels the pre-cache operation.
  ///
  /// After calling this method, [isCancelled] will return true and [isActive]
  /// will return false. The download will be stopped as soon as possible.
  void cancel() {
    if (_isActive) {
      _isCancelled = true;
      _isActive = false;
      if (!_completer.isCompleted) {
        _completer.complete();
      }
    }
  }

  /// Marks the pre-cache as complete.
  void _complete() {
    if (_isActive) {
      _isActive = false;
      if (!_completer.isCompleted) {
        _completer.complete();
      }
    }
  }

  /// Marks the pre-cache as failed with an error.
  void _fail(Object error) {
    if (_isActive) {
      _isActive = false;
      if (!_completer.isCompleted) {
        _completer.completeError(error);
      }
    }
  }

  /// Starts the download task.
  Future<void> _startDownload(Future<void> Function(bool Function() checkCancelled) downloadTask) async {
    try {
      await downloadTask(() => _isCancelled);
      _complete();
    } catch (e) {
      if (!_isCancelled) {
        _fail(e);
      }
    }
  }
}

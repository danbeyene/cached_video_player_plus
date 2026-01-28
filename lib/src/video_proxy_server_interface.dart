import 'pre_cache_handle.dart';

/// Interface for the VideoProxyServer to allow for platform-specific implementations.
abstract class VideoProxyServerInterface {
  /// Returns the singleton instance.
  static VideoProxyServerInterface get instance => throw UnimplementedError();

  /// Whether the server is currently running.
  bool get isRunning;

  /// The base URL for the proxy server.
  String get baseUrl;

  /// Starts the proxy server.
  Future<void> start();

  /// Stops the proxy server and cancels all active downloads.
  Future<void> stop();

  /// Handle app lifecycle changes.
  void handleAppLifecycle(dynamic state);

  /// Generates a proxy URL for the given video URL.
  String getProxyUrl({
    required String originalUrl,
    required String cacheKey,
    Map<String, String> headers = const {},
  });

  /// Registers a pre-cache handle for tracking.
  void registerPreCacheHandle(PreCacheHandle handle);

  /// Cancels any in-progress pre-cache for the given cache key.
  void cancelPreCache(String cacheKey);

  /// Checks if a pre-cache is in progress for the given cache key.
  bool isPreCaching(String cacheKey);

  /// Cancels any in-progress proxy download for the given cache key.
  void cancelDownload(String cacheKey);

  /// Checks if there's an active shared download for the given cache key.
  bool hasActiveDownload(String cacheKey);

  /// Starts a pre-cache download using the shared download mechanism.
  Future<void> startPreCacheDownload({
    required String url,
    required String cacheKey,
    required Map<String, String> headers,
  });

  /// Suspends all active pre-cache downloads to prioritize active playback.
  void suspendAllPreCacheDownloads();

  /// Resumes all suspended pre-cache downloads.
  void resumePreCacheDownloads();
}



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

  /// Starts a pre-cache download using the shared download mechanism.
  Future<void> startPreCacheDownload({
    required String url,
    required String cacheKey,
    required Map<String, String> headers,
  });

  /// Removes the cache for the given URL.
  Future<void> removeCache(String url);
}

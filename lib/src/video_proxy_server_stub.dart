
import 'video_proxy_server_interface.dart';

/// Web/Stub implementation of VideoProxyServer.
/// Returns no-ops for all methods as proxy is not supported on Web.
class VideoProxyServer implements VideoProxyServerInterface {
  VideoProxyServer._();
  
  static final VideoProxyServer instance = VideoProxyServer._();

  @override
  bool get isRunning => false;

  @override
  String get baseUrl => '';

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  void handleAppLifecycle(dynamic state) {}

  @override
  String getProxyUrl({
    required String originalUrl,
    required String cacheKey,
    Map<String, String> headers = const {},
  }) => originalUrl;

  @override
  Future<void> startPreCacheDownload({
    required String url,
    required String cacheKey,
    required Map<String, String> headers,
  }) async {}

  @override
  Future<void> removeCache(String url) async {}
}

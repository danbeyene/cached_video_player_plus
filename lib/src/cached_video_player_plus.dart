import 'dart:io' if (dart.library.html) 'stub_file.dart';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'package:http_cache_stream/http_cache_stream.dart';
import 'cache_key_helpers.dart';
// ignore: unused_import
import 'video_proxy_server.dart' if (dart.library.html) 'video_proxy_server_stub.dart';
import 'cvpp_logger.dart';

/// A video player that wraps [VideoPlayerController] with intelligent
/// caching capabilities using http_cache_stream.
///
/// It provides the same functionality as the standard video player but with the
/// added benefit of caching network videos locally using a local proxy server.
class CachedVideoPlayerPlus {
  /// Constructs a [CachedVideoPlayerPlus] playing a video from an asset.
  CachedVideoPlayerPlus.asset(
    this.dataSource, {
    this.package,
    this.closedCaptionFile,
    this.videoPlayerOptions,
    this.viewType = VideoViewType.textureView,
  })  : dataSourceType = DataSourceType.asset,
        formatHint = null,
        httpHeaders = const <String, String>{},

        skipCache = true,
        _cacheKey = '';

  /// Constructs a [CachedVideoPlayerPlus] playing a video from a network URL.
  CachedVideoPlayerPlus.networkUrl(
    Uri url, {
    this.formatHint,
    this.closedCaptionFile,
    this.videoPlayerOptions,
    this.httpHeaders = const <String, String>{},
    Map<String, String>? downloadHeaders,
    this.viewType = VideoViewType.textureView,
    this.skipCache = false,
    String? cacheKey,
  })  : dataSource = url.toString(),
        dataSourceType = DataSourceType.network,
        package = null,
        // _authHeaders = downloadHeaders ?? httpHeaders,
        _cacheKey = cacheKey != null
            ? getCustomCacheKey(cacheKey)
            : getCacheKey(url.toString());

  /// Constructs a [CachedVideoPlayerPlus] playing a video from a file.
  CachedVideoPlayerPlus.file(
    File file, {
    this.closedCaptionFile,
    this.videoPlayerOptions,
    this.httpHeaders = const <String, String>{},
    this.viewType = VideoViewType.textureView,
  })  : dataSource = file.absolute.path,
        dataSourceType = DataSourceType.file,
        package = null,
        formatHint = null,
        skipCache = true,
        _cacheKey = '';

  /// Constructs a [CachedVideoPlayerPlus] playing a video from a contentUri.
  CachedVideoPlayerPlus.contentUri(
    Uri contentUri, {
    this.closedCaptionFile,
    this.videoPlayerOptions,
    this.viewType = VideoViewType.textureView,
  })  : assert(
          defaultTargetPlatform == TargetPlatform.android,
          'CachedVideoPlayerPlus.contentUri is only supported on Android.',
        ),
        dataSource = contentUri.toString(),
        dataSourceType = DataSourceType.contentUri,
        package = null,
        formatHint = null,
        httpHeaders = const <String, String>{},

        skipCache = true,
        _cacheKey = '';

  final String dataSource;
  final Map<String, String> httpHeaders;
  // final Map<String, String> _authHeaders;
  final VideoFormat? formatHint;
  final DataSourceType dataSourceType;
  final VideoPlayerOptions? videoPlayerOptions;
  final String? package;
  final Future<ClosedCaptionFile>? closedCaptionFile;
  final VideoViewType viewType;
  final bool skipCache;

  final String _cacheKey;
  
  VideoPlayerController? _videoPlayerController;
  HttpCacheStream? _cacheStream;

  VideoPlayerController get controller {
    if (_videoPlayerController == null) {
      throw StateError(
        'CachedVideoPlayerPlus is not initialized. '
        'Call initialize() before accessing the controller.',
      );
    }
    return _videoPlayerController!;
  }

  bool _isInitialized = false;
  bool _isDisposed = false;

  bool get isInitialized => _isInitialized;

  bool get _shouldUseCache {
    return dataSourceType == DataSourceType.network && !kIsWeb && !skipCache;
  }

  /// Initializes the video player and sets up caching if applicable.
  Future<void> initialize() async {
    if (_isInitialized) {
      cvppLog('CachedVideoPlayerPlus is already initialized.');
      return;
    }

    // Ensure proxy is started if we need caching
    if (_shouldUseCache) {
      await VideoProxyServer.instance.start();
    }

    String realDataSource = dataSource;
    final Map<String, String> controllerHeaders = Map.from(httpHeaders);

    if (_shouldUseCache) {
      // Create a cache stream for the specific URL
      final sourceUrl = Uri.parse(dataSource);
      _cacheStream = HttpCacheManager.instance.createStream(sourceUrl);
      
      // Get the local cache URL
      realDataSource = _cacheStream!.cacheUrl.toString();
      
      cvppLog('Using content URL: $realDataSource (proxy active: true)');

      // Inject custom cache key header if needed?
      // http_cache_stream doesn't seem to support custom cache keys via headers directly for identity,
      // it uses the URL. But we can configure headers.
      if (_cacheKey != dataSource) {
        // controllerHeaders['CUSTOM-CACHE-ID'] = _cacheKey;
      }
    }

    _videoPlayerController = switch (dataSourceType) {
      DataSourceType.asset => VideoPlayerController.asset(
          dataSource,
          package: package,
          closedCaptionFile: closedCaptionFile,
          videoPlayerOptions: videoPlayerOptions,
          viewType: viewType,
        ),
      DataSourceType.network => VideoPlayerController.networkUrl(
          Uri.parse(realDataSource),
          formatHint: formatHint,
          closedCaptionFile: closedCaptionFile,
          videoPlayerOptions: videoPlayerOptions,
          httpHeaders: controllerHeaders,
          viewType: viewType,
        ),
      DataSourceType.contentUri => VideoPlayerController.contentUri(
          Uri.parse(dataSource),
          closedCaptionFile: closedCaptionFile,
          videoPlayerOptions: videoPlayerOptions,
          viewType: viewType,
        ),
      _ => VideoPlayerController.file(
          File(dataSource),
          closedCaptionFile: closedCaptionFile,
          videoPlayerOptions: videoPlayerOptions,
          httpHeaders: httpHeaders,
          viewType: viewType,
        ),
    };

    await _videoPlayerController!.initialize();
    
    if (_isDisposed) {
       // Was disposed during initialization
       await _videoPlayerController!.dispose();
       await _cacheStream?.dispose();
       return;
    }
    _isInitialized = true;
  }

  Future<void> dispose() async {
    if (_isDisposed) return Future.value();
    _isDisposed = true;
    _isInitialized = false; // Mark as not initialized to prevent usage
    
    // Dispose resources even if not fully initialized (race condition fix)
    await _cacheStream?.dispose();
    await _videoPlayerController?.dispose();
  }

  Future<void> removeFromCache() async {
    if (_shouldUseCache) {
       await VideoProxyServer.instance.removeCache(dataSource);
    }
  }

  static Future<void> removeFileFromCache(Uri url) async {
     // Forward to proxy
     await VideoProxyServer.instance.removeCache(url.toString());
  }

  static Future<void> removeFileFromCacheByKey(String cacheKey) async {
    // Current implementation assumes key == url for removal if not using headers?
    // This is tricky without knowing the URL if key is different.
    // We log a warning or try to remove assuming key might be url.
    await VideoProxyServer.instance.removeCache(cacheKey); 
  }

  static Future<void> clearAllCache() async {
    // Not directly exposed by simple wrapper yet, but safe to no-op or log.
    // http_cache_stream manages its own internal cache.
    cvppLog('Warning: clearAllCache is not fully supported with the new caching mechanism.');
  }

  static Future<void> preCacheVideo(
    Uri url, {
    Map<String, String> downloadHeaders = const <String, String>{},
    String? cacheKey,
  }) async {
    // Use VideoProxyServer for pre-caching
    final effectiveCacheKey = cacheKey != null
        ? getCustomCacheKey(cacheKey)
        : getCacheKey(url.toString());

    await VideoProxyServer.instance.startPreCacheDownload(
      url: url.toString(),
      cacheKey: effectiveCacheKey,
      headers: downloadHeaders,
    );
  }

  /// Enforces a maximum cache size by deleting oldest inactive cache files.
  ///
  /// [maxCacheSize] is the maximum allowed cache size in bytes.
  /// Default is 500MB. Files are sorted by last access time, oldest deleted first.
  static Future<void> enforceCacheLimit({int maxCacheSize = 500 * 1024 * 1024}) async {
    await VideoProxyServer.instance.enforceCacheLimit(maxCacheSize);
  }
}

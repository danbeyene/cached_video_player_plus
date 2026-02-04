import 'dart:async';
import 'dart:io';

import 'package:http_cache_stream/http_cache_stream.dart';

import 'cvpp_logger.dart';
import 'video_proxy_server_interface.dart';

/// A wrapper around http_cache_stream to maintain consistent initialization.
///
/// This implementation delegates actual caching to the
/// http_cache_stream package.
class VideoProxyServer implements VideoProxyServerInterface {
  VideoProxyServer._();

  /// The singleton instance of [VideoProxyServer].
  static final VideoProxyServer instance = VideoProxyServer._();

  /// Whether the server is currently initialized.
  bool _isInitialized = false;

  /// Maximum cache size in bytes. Defaults to 500MB.
  int maxCacheSize = 500 * 1024 * 1024;

  @override
  bool get isRunning => _isInitialized;

  /// The base URL for the proxy server.
  /// Not directly used with http_cache_stream as it provides per-stream URLs.
  @override
  String get baseUrl => 'http://127.0.0.1'; 

  /// Initialize the HttpCacheManager.
  @override
  Future<void> start() async {
    if (_isInitialized) return;

    try {
      cvppLog('Initializing HttpCacheManager...');
      await HttpCacheManager.init();
      _isInitialized = true;
      cvppLog('HttpCacheManager initialized');
      // Enforce cache limit on startup
      await enforceCacheLimit(maxCacheSize);
    } catch (e) {
      cvppLog('Error initializing HttpCacheManager: $e');
      rethrow;
    }
  }

  /// Stops the proxy server.
  /// HttpCacheManager doesn't need explicit stopping usually, but we can clear flag.
  @override
  Future<void> stop() async {
    _isInitialized = false;
    cvppLog('VideoProxyServer stopped (logical only)');
  }

  @override
  void handleAppLifecycle(dynamic state) {
    // No specific lifecycle handling needed for http_cache_stream currently
    cvppLog('App lifecycle changed: $state');
  }

  /// Deprecated: Logic moved to CachedVideoPlayerPlus to use individual streams.
  /// Throws error if used directly as we need to create a stream instance.
  @override
  String getProxyUrl({
    required String originalUrl,
    required String cacheKey,
    Map<String, String> headers = const {},
  }) {
    // This pattern doesn't fit http_cache_stream 1:1 because we need a stream instance
    // to get the cache URL. The controller needs to create the stream.
    // For backward compatibility or internal logic, we might need to rethink this interface
    // or return originalUrl and handle stream creation in the player.
    cvppLog('Warning: getProxyUrl called but http_cache_stream requires stream creation.');
    return originalUrl;
  }

  @override
  Future<void> startPreCacheDownload({
    required String url,
    required String cacheKey,
    required Map<String, String> headers,
  }) async {
    if (!_isInitialized) await start();
    
    cvppLog('Pre-caching video: $url');
    
    try {
      final sourceUrl = Uri.parse(url);
      final cacheStream = HttpCacheManager.instance.createStream(sourceUrl);
      
      // Start download and wait for it to complete
      await cacheStream.download();
      
      // Release resources when done
      await cacheStream.dispose();
      cvppLog('Pre-caching completed for: $url');
      // Enforce cache limit after pre-caching
      await enforceCacheLimit(maxCacheSize);
    } catch (e) {
      cvppLog('Error pre-caching: $e');
    }
  }

  @override
  Future<void> removeCache(String url) async {
    try {
      final uri = Uri.parse(url);
      final metadata = HttpCacheManager.instance.getCacheMetadata(uri);
      if (metadata != null) {
        await metadata.cacheFiles.delete();
        cvppLog('Removed cache for: $url');
      }
    } catch (e) {
      cvppLog('Error removing cache for $url: $e');
    }
  }

  /// Enforces a maximum cache size by deleting oldest inactive cache files.
  ///
  /// [maxCacheSize] is the maximum allowed cache size in bytes.
  /// Files are sorted by last access time, and oldest files are deleted first.
  Future<void> enforceCacheLimit(int maxCacheSize) async {
    if (!_isInitialized) await start();

    final Set<String> metadataPaths = {};
    final List<_CacheFileStat> cacheFileStats = [];
    int cacheSize = 0;

    await for (final file in HttpCacheManager.instance.inactiveCacheFiles()) {
      if (file.path.endsWith('.metadata')) {
        metadataPaths.add(file.path);
      } else {
        final fileStat = file.statSync();
        if (fileStat.size >= 0) {
          cacheFileStats.add(_CacheFileStat(file, fileStat));
          cacheSize += fileStat.size;
        }
      }
    }

    if (maxCacheSize >= cacheSize) {
      cvppLog('Cache size ($cacheSize bytes) is within limit ($maxCacheSize bytes).');
      return;
    }

    cvppLog('Cache size ($cacheSize bytes) exceeds limit ($maxCacheSize bytes). Cleaning up...');

    // Sort by last accessed time (oldest first)
    cacheFileStats.sort((a, b) => a.stat.accessed.compareTo(b.stat.accessed));

    for (final cacheFileStat in cacheFileStats) {
      if (maxCacheSize >= cacheSize) break;
      final file = cacheFileStat.file;
      try {
        await file.delete();
        final metaDataPath = '${file.path}.metadata';
        if (metadataPaths.contains(metaDataPath)) {
          await File(metaDataPath).delete();
        }
        cacheSize -= cacheFileStat.stat.size;
        cvppLog('Deleted cache file: ${file.path}');
      } catch (e) {
        cvppLog('Error deleting cache file ${file.path}: $e');
      }
    }
    cvppLog('Cache cleanup complete. New size: $cacheSize bytes.');
  }
}

/// Helper class for sorting cache files by stat.
class _CacheFileStat {
  final File file;
  final FileStat stat;
  const _CacheFileStat(this.file, this.stat);
}

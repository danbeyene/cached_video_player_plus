import 'dart:io' if (dart.library.html) 'stub_file.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';


import 'cvpp_logger.dart';
import 'ios_platform_interface.dart';
import 'android_platform_interface.dart';

/// A video player that wraps [VideoPlayerController] with intelligent
/// native caching capabilities.
///
/// It provides the same functionality as the standard video player but with the
/// added benefit of caching network videos locally using native platform APIs.
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

        skipCache = true;

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
        package = null;

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
        skipCache = true;

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

        skipCache = true;

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


  
  VideoPlayerController? _videoPlayerController;


  VideoPlayerController get controller {
    if (_videoPlayerController == null) {
      throw StateError(
        'CachedVideoPlayerPlus is not initialized. '
        'Call initialize() before accessing the controller.',
      );
    }
    return _videoPlayerController!;
  }

  static bool _platformRegistered = false;
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

    // Register iOS/Android platform interface if needed once
    if (!CachedVideoPlayerPlus._platformRegistered) {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        CachedVideoPlayerPlusPlatformWithEvents.registerWith();
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        CachedVideoPlayerPlusPlatformAndroid.registerWith();
      }
      CachedVideoPlayerPlus._platformRegistered = true;
    }

    String realDataSource = dataSource;
    final Map<String, String> controllerHeaders = Map.from(httpHeaders);

    // Prepare the data source with native caching if applicable
    if (_shouldUseCache) {
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        // iOS Native Caching Logic
        final sourceUrl = Uri.parse(dataSource);
        if (sourceUrl.scheme == 'http' || sourceUrl.scheme == 'https') {
          // Use 'cache' scheme to trigger native ResourceLoader
          realDataSource = sourceUrl.replace(scheme: 'cache').toString();
          cvppLog('Using iOS native cache: $realDataSource');
        }
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        // Android Native Caching Logic (ExoPlayer CacheDataSource)
        // We typically just pass the http/https URL, and the native side wraps it in CacheDataSource.
        // No scheme change needed unless we want to enforce it explicitely, but our Kotlin code
        // checks for http/https in VideoPlayer.kt
        cvppLog('Using Android native cache (ExoPlayer): $realDataSource');
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
       return;
    }
    _isInitialized = true;
  }

  Future<void> dispose() async {
    if (_isDisposed) return Future.value();
    _isDisposed = true;
    _isInitialized = false; // Mark as not initialized to prevent usage
    
    // Dispose resources even if not fully initialized (race condition fix)
    await _videoPlayerController?.dispose();
  }

  Future<void> removeFromCache() async {
    if (_shouldUseCache && (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android)) {
      await const MethodChannel('cached_video_player_plus').invokeMethod('removeFile', {'url': dataSource});
    }
  }

  static Future<void> removeFileFromCache(Uri url) async {
     if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android) {
        await const MethodChannel('cached_video_player_plus').invokeMethod('removeFile', {'url': url.toString()});
     }
  }

  static Future<void> removeFileFromCacheByKey(String cacheKey) async {
    // Current implementation assumes key == url for removal if not using headers.
     if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android) {
        await const MethodChannel('cached_video_player_plus').invokeMethod('removeFile', {'url': cacheKey});
     }
  }

  static Future<void> clearAllCache() async {
    if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android) {
        await const MethodChannel('cached_video_player_plus').invokeMethod('clearAllCache');
        cvppLog('Cleared cache.');
        return;
    }
  }

  static Future<void> preCacheVideo(
    Uri url, {
    Map<String, String> downloadHeaders = const <String, String>{},
    String? cacheKey,
  }) async {
    if (url.scheme != 'http' && url.scheme != 'https') {
      cvppLog('Pre-caching skipped: Only http/https URLs are supported for caching ($url)');
      return;
    }

    if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android) {
        await const MethodChannel('cached_video_player_plus').invokeMethod('preCache', {
            'url': url.toString(),
            'headers': downloadHeaders,
        });
        cvppLog('Pre-caching completed for ${url.toString()}');
        return;
    }
  }

  /// Enforces a maximum cache size by deleting oldest inactive cache files.
  ///
  /// [maxCacheSize] is the maximum allowed cache size in bytes.
  /// Default is 500MB. Files are sorted by last access time, oldest deleted first.
  static Future<void> enforceCacheLimit({int maxCacheSize = 500 * 1024 * 1024}) async {
    if (defaultTargetPlatform == TargetPlatform.iOS || defaultTargetPlatform == TargetPlatform.android) {
        await const MethodChannel('cached_video_player_plus').invokeMethod('enforceCacheLimit', {'maxCacheSize': maxCacheSize});
        return;
    }
  }
}

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:shelf_plus/shelf_plus.dart';

import 'async_semaphore.dart';
import 'cvpp_logger.dart';
import 'i_video_player_metadata_storage.dart';
import 'pre_cache_handle.dart';
import 'video_cache_manager.dart';
import 'video_player_metadata_storage.dart';
import 'video_proxy_server_interface.dart';

/// A local HTTP proxy server that streams videos while caching them.
///
/// This server intercepts video requests and:
/// 1. Downloads the video from the original URL
/// 2. Streams bytes to the video player for immediate playback
/// 3. Simultaneously writes bytes to the cache for future use
///
/// This ensures only one download occurs per video, eliminating the
/// dual-download issue where video_player and cache manager download
/// the same video separately.
class VideoProxyServer implements VideoProxyServerInterface {
  VideoProxyServer._();

  /// The singleton instance of [VideoProxyServer].
  static final VideoProxyServer instance = VideoProxyServer._();

  /// The underlying HTTP server.
  HttpServer? _server;

  /// Whether the server is currently running.
  bool _isRunning = false;

  /// Completer to guard against concurrent start calls.
  Completer<void>? _startCompleter;

  @override
  bool get isRunning => _isRunning;

  /// The port the server is listening on. Returns 0 if not running.
  int get port => _server?.port ?? 0;

  @override
  String get baseUrl => 'http://127.0.0.1:$port';

  /// Active pre-cache handles, keyed by cache key.
  final Map<String, PreCacheHandle> _preCacheHandles = {};

  /// Active proxy downloads that are in progress.
  final Map<String, _ProxyDownload> _activeDownloads = {};

  /// Shared downloads: one upstream connection per URL, serving multiple range requests.
  final Map<String, _SharedDownload> _sharedDownloads = {};

  /// Tracks which shared active downloads are owned/read by pre-cache tasks.
  final Map<String, _SharedDownload> _preCacheDownloads = {};

  /// The cache manager to use for storing cached videos.
  CacheManager _cacheManager = VideoCacheManager();

  /// The metadata storage to use for cache expiration.
  IVideoPlayerMetadataStorage _metadataStorage = VideoPlayerMetadataStorage();

  /// Shared HTTP client for connection pooling (Keep-Alive).
  /// Required for fast iOS playback start (reuses SSL handshake).
  http.Client? _sharedClient;

  /// Sets the cache manager to use. Must be called before [start].
  set cacheManager(CacheManager manager) => _cacheManager = manager;

  /// Sets the metadata storage to use. Must be called before [start].
  set metadataStorage(IVideoPlayerMetadataStorage storage) =>
      _metadataStorage = storage;

  @override
  Future<void> start() async {
    // If start is in progress, wait for it
    if (_startCompleter != null) {
      return _startCompleter!.future;
    }

    if (_isRunning) {
      cvppLog('VideoProxyServer is already running on port $port');
      return;
    }

    _startCompleter = Completer<void>();

    try {
      _sharedClient = http.Client();
      final app = Router().plus;

      // Route: /video?url=<encoded_url>&key=<cache_key>&headers=<encoded_headers>
      app.get('/video', _handleVideoRequest);

      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _isRunning = true;

      // Start serving requests
      _server!.listen((HttpRequest request) async {
        // Convert HttpHeaders to Map<String, String>
        final headersMap = <String, String>{};
        request.headers.forEach((name, values) {
          headersMap[name] = values.join(',');
        });

        try {
          final response = await app.call(Request(
            request.method,
            request.requestedUri,
            headers: headersMap,
            body: request,
          ));

          // Write response back to the HttpRequest
          request.response.statusCode = response.statusCode;
          response.headers.forEach((key, value) {
            request.response.headers.set(key, value);
          });
          await response.read().pipe(request.response);
        } catch (error) {
          // Only log actual errors, not expected client disconnects/cancellations
          final errorStr = error.toString();
          if (!errorStr.contains('Connection closed') &&
              !errorStr.contains('Pipe broken') &&
              !errorStr.contains('Content size below specified contentLength')) {
            cvppLog('Error handling request: $error');
          }

          // Only attempt to send error status if headers haven't been sent
          try {
            request.response.statusCode = HttpStatus.internalServerError;
          } catch (_) {
            // Headers already sent (likely during streaming), ignore
          }

          try {
            await request.response.close();
          } catch (_) {
            // Response might already be closed
          }
        }
      });

      cvppLog('VideoProxyServer started on port $port');
      _startCompleter!.complete();
    } catch (e) {
      _startCompleter?.completeError(e);
      _startCompleter = null;
      rethrow;
    } finally {
      // Don't clear completer here if successful, serves as "started" marker until stopped?
      // Actually standard pattern is to clear it so subsequent calls return fast?
      // But we have _isRunning check.
      // So verify:
      // Call 1: _isRunning false. Create completer. logic. complete.
      // Call 2: (during 1) awaits completer. returns.
      // Call 3: (after 1) _isRunning true. returns.
      // So we need to keep _startCompleter? No, clear it so we don't leak logic.
      _startCompleter = null;
    }
  }

  @override
  Future<void> stop() async {
    if (!_isRunning) return;

    // Cancel all active downloads
    for (final download in _activeDownloads.values) {
      download.cancel();
    }
    _activeDownloads.clear();

    // Cancel all pre-cache handles
    for (final handle in _preCacheHandles.values) {
      handle.cancel();
    }
    _preCacheHandles.clear();
    // Also clear pre-cache readers mapping
    for (final download in _preCacheDownloads.values) {
      download.removeReader();
    }
    _preCacheDownloads.clear();

    _sharedClient?.close();
    _sharedClient = null;

    await _server?.close(force: true);
    _server = null;
    _isRunning = false;
    _startCompleter = null; // Reset completer just in case

    cvppLog('VideoProxyServer stopped');
  }

  @override
  void handleAppLifecycle(dynamic state) {
    // state is AppLifecycleState but we use dynamic to avoid flutter import
    final stateName = state.toString();

    if (stateName.contains('paused') || stateName.contains('inactive')) {
      // App going to background - pause all pre-cache downloads
      cvppLog('App backgrounded - pausing pre-cache downloads');
      for (final handle in _preCacheHandles.values) {
        if (handle.isActive) {
          handle.cancel();
        }
      }
      _preCacheHandles.clear();
      // _preCacheDownloads cleanup happens via cancelPreCache calling removeReader logic?
      // Actually we iterate handles calling cancel(). cancelPreCache also cleans up downloads.
      // But we need to ensure the _preCacheDownloads map is also cleared if handles are cleared directly.
      // Since we just called cancel() on handles, they should trigger logic IF logic is hooked up.
      // But PreCacheHandle logic is external (in the callback).
      // So we should manually clean up readers here too to be safe.
      for (final key in _preCacheDownloads.keys.toList()) {
        _preCacheDownloads[key]?.removeReader();
      }
      _preCacheDownloads.clear();

      // Note: Active playback downloads continue - the player needs them
      // They will be cleaned up by the abandon timer if player also pauses
    } else if (stateName.contains('resumed')) {
      cvppLog('App resumed');
    }
  }

  @override
  String getProxyUrl({
    required String originalUrl,
    required String cacheKey,
    Map<String, String> headers = const {},
  }) {
    final encodedUrl = Uri.encodeComponent(originalUrl);
    final encodedKey = Uri.encodeComponent(cacheKey);
    final encodedHeaders = Uri.encodeComponent(
      headers.entries.map((e) => '${e.key}:${e.value}').join('\n'),
    );
    return '$baseUrl/video?url=$encodedUrl&key=$encodedKey&headers=$encodedHeaders';
  }

  @override
  void registerPreCacheHandle(PreCacheHandle handle) {
    _preCacheHandles[handle.cacheKey] = handle;
    handle.done.whenComplete(() {
      _preCacheHandles.remove(handle.cacheKey);
    });
  }

  @override
  void cancelPreCache(String cacheKey) {
    final handle = _preCacheHandles[cacheKey];
    if (handle != null && handle.isActive) {
      cvppLog('Cancelling pre-cache for key: $cacheKey');
      handle.cancel();
      _preCacheHandles.remove(cacheKey);
    }
    
    // Explicitly remove reader count for pre-cache if it exists
    final download = _preCacheDownloads.remove(cacheKey);
    if (download != null) {
      download.removeReader();
    }
  }

  @override
  bool isPreCaching(String cacheKey) {
    final handle = _preCacheHandles[cacheKey];
    return handle != null && handle.isActive;
  }

  @override
  void cancelDownload(String cacheKey) {
    final download = _sharedDownloads[cacheKey];
    if (download != null && !download.isComplete && !download.isFailed) {
      cvppLog('Cancelling download on dispose: $cacheKey');
      download.cancel();
      download.cleanup();
      _sharedDownloads.remove(cacheKey);
      _activeDownloads.remove(cacheKey);
      _updateConcurrency();
    }
    
    // Also cleanup pre-cache references if any
    _preCacheDownloads.remove(cacheKey);
  }

  @override
  bool hasActiveDownload(String cacheKey) {
    final download = _sharedDownloads[cacheKey];
    return download != null && !download.isComplete && !download.isFailed;
  }

  /// Suspends all active pre-cache downloads to prioritize active playback.
  /// Call this when a video starts playing to give it full bandwidth.
  @override
  void suspendAllPreCacheDownloads() {
    if (_preCacheDownloads.isEmpty) return;
    
    cvppLog('Suspending ${_preCacheDownloads.length} pre-cache downloads for active playback');
    for (final download in _preCacheDownloads.values) {
      download.suspend();
    }
  }

  /// Resumes all suspended pre-cache downloads.
  /// Call this after active video initialization completes.
  @override
  void resumePreCacheDownloads() {
    int resumedCount = 0;
    for (final download in _preCacheDownloads.values) {
      if (download.isPaused) {
        download.resume();
        resumedCount++;
      }
    }
    if (resumedCount > 0) {
      cvppLog('Resumed $resumedCount pre-cache downloads');
    }
  }

  @override
  Future<void> startPreCacheDownload({
    required String url,
    required String cacheKey,
    required Map<String, String> headers,
  }) async {
    if (_sharedDownloads.containsKey(cacheKey)) {
      final existing = _sharedDownloads[cacheKey]!;
      if (!existing.isFailed) {
        cvppLog('Pre-cache reusing existing download: $url');
        
        // Add reader for pre-cache if not already tracked
        if (!_preCacheDownloads.containsKey(cacheKey)) {
             existing.addReader();
             _preCacheDownloads[cacheKey] = existing;
        }

        try {
          await existing.downloadComplete;
        } catch (e) {
          cvppLog('Pre-cache download failed (reused): $e');
        } finally {
             // Cleanup if we owned it
             if (_preCacheDownloads.containsKey(cacheKey)) {
                 existing.removeReader();
                 _preCacheDownloads.remove(cacheKey);
             }
        }
        return;
      }
    }

    cvppLog('Pre-cache starting shared download: $url');
    final sharedDownload = _SharedDownload(
      url: url,
      cacheKey: cacheKey,
      headers: headers,
      client: _sharedClient ?? http.Client(),
      onComplete: (download) => _onSharedDownloadComplete(download),
      onFailed: (download) {
        _sharedDownloads.remove(cacheKey);
      },
    );
    _sharedDownloads[cacheKey] = sharedDownload;
    _activeDownloads[cacheKey] = _ProxyDownload(cacheKey: cacheKey);
    _updateConcurrency();

    // Mark as pre-cache reader
    sharedDownload.addReader();
    _preCacheDownloads[cacheKey] = sharedDownload;

    await sharedDownload.start();

    try {
      await sharedDownload.downloadComplete;
    } catch (e) {
      cvppLog('Pre-cache download failed: $e');
    } finally {
        // Cleanup if we still own it (wasn't cancelled externally)
        if (_preCacheDownloads.containsKey(cacheKey)) {
            sharedDownload.removeReader();
            _preCacheDownloads.remove(cacheKey);
        }
    }
  }

  Future<Response> _handleVideoRequest(Request request) async {
    final url = request.requestedUri.queryParameters['url'];
    final cacheKey = request.requestedUri.queryParameters['key'];
    final headersParam = request.requestedUri.queryParameters['headers'] ?? '';

    if (url == null || cacheKey == null) {
      return Response.badRequest(body: 'Missing url or key parameter');
    }

    final decodedUrl = Uri.decodeComponent(url);
    final decodedKey = Uri.decodeComponent(cacheKey);

    // Cancel any active pre-cache for this video to prevent double downloading
    // This will remove the pre-cache reader count.
    // Ideally we'd do atomic handover, but the abandon timer covers the gap.
    cancelPreCache(decodedKey);

    // Check if video is already cached
    final fileInfo = await _cacheManager.getFileFromCache(decodedKey);
    if (fileInfo != null) {
      return _serveFromCacheFile(fileInfo.file, request.headers['range']);
    }

    // Suspend all pre-cache downloads to prioritize this active playback
    // Only done if not serving from cache
    suspendAllPreCacheDownloads();

    final headers = <String, String>{};
    if (headersParam.isNotEmpty) {
      final decodedHeaders = Uri.decodeComponent(headersParam);
      for (final line in decodedHeaders.split('\n')) {
        final colonIndex = line.indexOf(':');
        if (colonIndex > 0) {
          headers[line.substring(0, colonIndex)] =
              line.substring(colonIndex + 1);
        }
      }
    }

    final rangeHeader = request.headers['range'];
    int? requestedStart;
    int? requestedEnd;

    if (rangeHeader != null) {
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (match != null) {
        requestedStart = int.parse(match.group(1)!);
        final endStr = match.group(2);
        if (endStr != null && endStr.isNotEmpty) {
          requestedEnd = int.parse(endStr);
        }
      }
      cvppLog('Range request: $rangeHeader for $decodedUrl');
    } else {
      cvppLog('Full request for: $decodedUrl');
    }

    try {
      var sharedDownload = _sharedDownloads[decodedKey];

      if (sharedDownload == null || sharedDownload.isFailed) {
        cvppLog('Starting shared download: $decodedUrl');
        sharedDownload = _SharedDownload(
          url: decodedUrl,
          cacheKey: decodedKey,
          headers: headers,
          client: _sharedClient ?? http.Client(),
          onComplete: (download) => _onSharedDownloadComplete(download),
          onFailed: (download) {
            _sharedDownloads.remove(decodedKey);
          },
        );
        _sharedDownloads[decodedKey] = sharedDownload;
        _activeDownloads[decodedKey] = _ProxyDownload(cacheKey: decodedKey);
        _updateConcurrency();

        await sharedDownload.start();
      }

      await sharedDownload.metadataReady;

      final totalSize = sharedDownload.totalSize;
      final contentType = sharedDownload.contentType;

      if (totalSize == null) {
        return Response.internalServerError(
            body: 'Could not determine content length');
      }

      final start = requestedStart ?? 0;
      final end = requestedEnd ?? (totalSize - 1);
      final isRangeRequest = rangeHeader != null;

      cvppLog('Serving bytes $start-$end from shared buffer for $decodedUrl');

      final responseController = StreamController<List<int>>();

      _streamBytesFromSharedDownload(
        sharedDownload,
        start,
        end,
        responseController,
      );

      final responseHeaders = <String, String>{
        'content-type': contentType,
        'accept-ranges': 'bytes',
        'content-length': (end - start + 1).toString(),
      };

      if (isRangeRequest) {
        responseHeaders['content-range'] = 'bytes $start-$end/$totalSize';
      }

      return Response(
        isRangeRequest ? 206 : 200,
        body: responseController.stream,
        headers: responseHeaders,
      );
    } catch (e) {
      cvppLog('Proxy error: $e');
      return Response.internalServerError(body: 'Proxy error: $e');
    }
  }

  Future<Response> _serveFromCacheFile(File file, String? rangeHeader) async {
    final fileSize = await file.length();
    final contentType = 'video/mp4';

    int start = 0;
    int end = fileSize - 1;
    bool isRangeRequest = false;

    if (rangeHeader != null) {
      final match = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(rangeHeader);
      if (match != null) {
        start = int.parse(match.group(1)!);
        final endStr = match.group(2);
        if (endStr != null && endStr.isNotEmpty) {
          end = int.parse(endStr);
        }
        isRangeRequest = true;
      }
    }

    final length = end - start + 1;

    final raf = await file.open();
    await raf.setPosition(start);

    final controller = StreamController<List<int>>();

    () async {
      try {
        int remaining = length;
        while (remaining > 0) {
          final chunkSize = remaining > 65536 ? 65536 : remaining;
          final bytes = await raf.read(chunkSize);
          if (bytes.isEmpty) break;
          controller.add(bytes);
          remaining -= bytes.length;
        }
      } finally {
        await raf.close();
        controller.close();
      }
    }();

    final headers = <String, String>{
      'content-type': contentType,
      'accept-ranges': 'bytes',
      'content-length': length.toString(),
    };

    if (isRangeRequest) {
      headers['content-range'] = 'bytes $start-$end/$fileSize';
    }

    return Response(
      isRangeRequest ? 206 : 200,
      body: controller.stream,
      headers: headers,
    );
  }

  void _streamBytesFromSharedDownload(
    _SharedDownload download,
    int start,
    int end,
    StreamController<List<int>> controller,
  ) {
    download.addReader();

    () async {
      try {
        int position = start;
        final chunkSize = 65536; // 64KB chunks

        while (position <= end && !controller.isClosed) {
          final requestEnd = (position + chunkSize - 1).clamp(0, end);

          final bytes = await download.getBytes(position, requestEnd,
              waitForDownload: true);

          if (bytes.isEmpty) {
            cvppLog('No more bytes available at position $position');
            break;
          }

          controller.add(bytes);
          position += bytes.length;
        }
      } catch (e) {
        cvppLog('Error streaming from buffer: $e');
        controller.addError(e);
      } finally {
        download.removeReader();
        controller.close();
      }
    }();
  }

  Future<void> _onSharedDownloadComplete(_SharedDownload download) async {
    final decodedKey = download.cacheKey;
    final decodedUrl = download.url;

    cvppLog(
        'Shared download complete: $decodedUrl (${download.totalSize} bytes)');

    try {
      final tempPath = download.tempFilePath;
      if (tempPath != null) {
        final tempFile = File(tempPath);
        if (await tempFile.exists()) {
          final bytes = await tempFile.readAsBytes();

          await _cacheManager.putFile(
            decodedUrl,
            bytes,
            key: decodedKey,
            fileExtension: _getExtension(decodedUrl),
          );
          await _metadataStorage.write(
            decodedKey,
            DateTime.timestamp().millisecondsSinceEpoch,
          );
          cvppLog('Cached video: $decodedUrl');
        }
      }
    } catch (e) {
      cvppLog('Failed to cache video: $e');
    }

    _activeDownloads.remove(decodedKey);
    _updateConcurrency();

    // Resume pre-cache downloads only if this was an active playback download
    // (not if it was a pre-cache download completing)
    if (!_preCacheDownloads.containsKey(decodedKey)) {
      resumePreCacheDownloads();
    }

    // Delay cleanup to allow active streams to finish reading
    Future.delayed(const Duration(seconds: 30), () async {
      _sharedDownloads.remove(decodedKey);
      await download.cleanup();
    });
  }

  String _getExtension(String url) {
    final uri = Uri.parse(url);
    final path = uri.path;
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex > 0 && dotIndex < path.length - 1) {
      return path.substring(dotIndex + 1);
    }
    return 'mp4';
  }

  void _updateConcurrency() {
    // Check if we have any downloads that are NOT pre-cache downloads
    // This indicates an active user-initiated video playback
    bool hasActivePlayback = false;
    for (final key in _activeDownloads.keys) {
      if (!_preCacheDownloads.containsKey(key)) {
        hasActivePlayback = true;
        break;
      }
    }

    if (hasActivePlayback) {
      // STRICT Priority: Block all new pre-cache tasks
      AsyncSemaphore.instance.setMaxConcurrent(0);
    } else {
      // No active playback, allow limited concurrency (reduced to 2 to avoid strain)
      AsyncSemaphore.instance.setMaxConcurrent(2);
    }
  }
}

/// Internal class to track active proxy downloads.
class _ProxyDownload {
  _ProxyDownload({
    required this.cacheKey,
  });

  final String cacheKey;
  StreamSubscription? subscription;
  bool isCancelled = false;

  void cancel() {
    isCancelled = true;
    subscription?.cancel();
  }
}

/// Manages a single upstream HTTP connection for a video URL.
class _SharedDownload {
  _SharedDownload({
    required this.url,
    required this.cacheKey,
    required this.headers,
    required this.client,
    required this.onComplete,
    required this.onFailed,
  });

  final String url;
  final String cacheKey;
  final Map<String, String> headers;
  final http.Client client;
  final void Function(_SharedDownload) onComplete;
  final void Function(_SharedDownload) onFailed;

  static const int _maxMemoryBytes = 512 * 1024;

  final Completer<void> _metadataCompleter = Completer<void>();
  final Completer<void> _downloadCompleter = Completer<void>();

  int? _totalSize;
  int? get totalSize => _totalSize;

  String _contentType = 'video/mp4';
  String get contentType => _contentType;

  final BytesBuilder _memoryBuffer = BytesBuilder(copy: false);

  int _bytesDownloaded = 0;
  int get bytesDownloaded => _bytesDownloaded;

  RandomAccessFile? _file;
  String? _tempPath;
  String? get tempFilePath => _tempPath;

  bool _isFailed = false;
  bool get isFailed => _isFailed;

  String? _failureReason;
  String? get failureReason => _failureReason;

  bool _isComplete = false;
  bool get isComplete => _isComplete;

  StreamSubscription? _subscription;

  final _bytesAvailableController = StreamController<int>.broadcast();

  Future<void> _fileQueue = Future.value();

  int _activeReaders = 0;
  Timer? _abandonTimer;
  bool _isPaused = false;
  bool get isPaused => _isPaused;

  Future<void> get metadataReady => _metadataCompleter.future;

  Future<void> get downloadComplete => _downloadCompleter.future;

  void addReader() {
    _activeReaders++;
    _abandonTimer?.cancel();
    _abandonTimer = null;
  }

  void removeReader() {
    _activeReaders--;
    if (_activeReaders <= 0 && !_isComplete && !_isFailed) {
      _abandonTimer = Timer(const Duration(seconds: 5), () {
        if (_activeReaders <= 0 && !_isComplete && !_isFailed) {
          cvppLog('Abandoning download (no readers): $url');
          cancel();
          onFailed(this);
          cleanup();
        }
      });
    }
  }

  Future<void> start() async {
    try {
      final httpRequest = http.Request('GET', Uri.parse(url));
      httpRequest.headers.addAll(headers);

      final httpResponse = await client.send(httpRequest);

      if (httpResponse.statusCode != 200 && httpResponse.statusCode != 206) {
        httpResponse.stream.drain().catchError((_) {});
        _isFailed = true;
        _failureReason = 'HTTP ${httpResponse.statusCode}';
        if (!_metadataCompleter.isCompleted) {
          _metadataCompleter.completeError('Upstream error: ${httpResponse.statusCode}');
        }
        onFailed(this);
        return;
      }

      _contentType = httpResponse.headers['content-type'] ?? 'video/mp4';
      
      final contentRange = httpResponse.headers['content-range'];
      if (contentRange != null) {
        final match = RegExp(r'bytes \d+-\d+/(\d+)').firstMatch(contentRange);
        if (match != null) {
          _totalSize = int.parse(match.group(1)!);
        }
      }
      _totalSize ??= httpResponse.contentLength;

      if (_totalSize == null || _totalSize! <= 0) {
        _isFailed = true;
        if (!_metadataCompleter.isCompleted) {
          _metadataCompleter.completeError('Could not determine content length');
        }
        onFailed(this);
        return;
      }

      final tempDir = await Directory.systemTemp.createTemp('video_cache_');
      final safeName = cacheKey.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      _tempPath = '${tempDir.path}/$safeName.tmp';
      final file = File(_tempPath!);
      _file = await file.open(mode: FileMode.write);

      cvppLog('Shared download created temp file: $_tempPath');

      _metadataCompleter.complete();

      _subscription = httpResponse.stream.listen(
        (chunk) {
          if (_memoryBuffer.length < _maxMemoryBytes) {
            final bytesToAdd = (_maxMemoryBytes - _memoryBuffer.length).clamp(0, chunk.length);
            if (bytesToAdd > 0) {
              _memoryBuffer.add(chunk.sublist(0, bytesToAdd));
            }
          }
          
          _bytesDownloaded += chunk.length;
          
          if (_file != null) {
            final chunkCopy = Uint8List.fromList(chunk);
            _fileQueue = _fileQueue.then((_) async {
              if (_file != null) {
                await _file!.writeFrom(chunkCopy);
              }
            }).catchError((e) {
              cvppLog('Write error: $e');
            });
          }
          
          _bytesAvailableController.add(_bytesDownloaded);
        },
        onDone: () async {
          await _fileQueue;
          
          _isComplete = true;
          _bytesAvailableController.add(_bytesDownloaded);
          _bytesAvailableController.close();
          
          if (!_downloadCompleter.isCompleted) {
            _downloadCompleter.complete();
          }
          
          onComplete(this);
        },
        onError: (error) async {
          await _fileQueue;
          
          cvppLog('Shared download error: $error');
          _isFailed = true;
          _failureReason = error.toString();
          
          if (!_bytesAvailableController.isClosed) {
            _bytesAvailableController.close();
          }
          
          if (!_downloadCompleter.isCompleted) {
            _downloadCompleter.completeError(error);
          }
          
          onFailed(this);
        },
        cancelOnError: true,
      );
    } catch (e) {
      cvppLog('Shared download start error: $e');
      _isFailed = true;
      if (!_metadataCompleter.isCompleted) {
        _metadataCompleter.completeError(e);
      }
      onFailed(this);
    }
  }

  Future<List<int>> getBytes(int start, int end, {bool waitForDownload = false}) async {
    if (waitForDownload) {
      while (_bytesDownloaded <= end && !_isComplete && !_isFailed) {
        try {
          await _bytesAvailableController.stream.first;
        } catch (e) {
          break;
        }
      }
    }
    
    if (start < _memoryBuffer.length && end < _memoryBuffer.length) {
      final buffer = _memoryBuffer.toBytes();
      return buffer.sublist(start, end + 1);
    }
    
    if (end < _bytesDownloaded) {
      return _readFromDisk(start, end);
    }
    
    if (start < _bytesDownloaded) {
      if (start < _memoryBuffer.length) {
        final buffer = _memoryBuffer.toBytes();
        final memEnd = buffer.length - 1;
        return buffer.sublist(start, memEnd + 1);
      } else {
        return _readFromDisk(start, _bytesDownloaded - 1);
      }
    }
    
    if (!waitForDownload) {
      return _fetchDirect(start, end);
    }
    
    return [];
  }

  Future<List<int>> _readFromDisk(int start, int end) async {
    if (_tempPath == null) return [];
    
    final path = _tempPath!;
    
    // Wait for any pending writes to complete
    await _fileQueue;
    
    // Check if cleanup happened during await
    if (_tempPath == null) return [];
    
    try {
      // Open a fresh file handle for reading (separate from write handle)
      final file = File(path);
      if (!await file.exists()) return [];
      
      final raf = await file.open(mode: FileMode.read);
      try {
        await raf.setPosition(start);
        final length = end - start + 1;
        final bytes = await raf.read(length);
        return bytes;
      } finally {
        await raf.close();
      }
    } catch (e) {
      // Only log if not a race with cleanup
      if (_tempPath != null) {
        cvppLog('Disk read error: $e');
      }
      return [];
    }
  }

  Future<List<int>> _fetchDirect(int start, int end) async {
    try {
      final rangeEnd = end.clamp(0, (_totalSize ?? end) - 1);
      cvppLog('Direct fetch: bytes $start-$rangeEnd for $url');
      
      final request = http.Request('GET', Uri.parse(url));
      request.headers.addAll(headers);
      request.headers['range'] = 'bytes=$start-$rangeEnd';
      
      final response = await client.send(request);
      
      if (response.statusCode == 206 || response.statusCode == 200) {
        return await response.stream.toBytes();
      } else {
        cvppLog('Direct fetch failed: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      cvppLog('Direct fetch error: $e');
      return [];
    }
  }

  void cancel() {
    _abandonTimer?.cancel();
    _abandonTimer = null;
    _subscription?.cancel();
    _isFailed = true;
    _bytesAvailableController.close();
  }

  /// Pauses the download to yield bandwidth to active playback.
  void suspend() {
    if (_isPaused || _isComplete || _isFailed) return;
    _isPaused = true;
    _subscription?.pause();
  }

  /// Resumes a paused download.
  void resume() {
    if (!_isPaused) return;
    _isPaused = false;
    _subscription?.resume();
  }

  Future<void> cleanup() async {
    _subscription?.cancel();
    
    // Ensure we don't try to read anymore
    final pathToDelete = _tempPath;
    _tempPath = null;
    
    try {
      await _fileQueue;
      await _file?.close();
    } catch (_) {}
    _file = null;
    
    _memoryBuffer.clear();
    
    if (pathToDelete != null) {
      try {
        await File(pathToDelete).delete();
        final tempDir = File(pathToDelete).parent;
        if (await tempDir.exists()) {
          await tempDir.delete();
        }
      } catch (_) {}
    }
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cached_video_player_plus/cached_video_player_plus.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'dart:io';
import 'dart:async';

class MockVideoPlayerPlatform extends VideoPlayerPlatform
    with MockPlatformInterfaceMixin {
  final StreamController<VideoEvent> _eventStreamController =
      StreamController<VideoEvent>.broadcast();

  @override
  Future<void> init() async {}

  @override
  Future<void> dispose(int playerId) async {}

  @override
  Future<int?> create(DataSource dataSource) async {
    Timer(const Duration(milliseconds: 50), () {
      _eventStreamController.add(VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 1),
        size: const Size(1920, 1080),
      ));
    });
    return 1;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async {}

  @override
  Future<void> pause(int playerId) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async {
    return Duration.zero;
  }

  @override
  Widget buildView(int playerId) {
    return Container();
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    return _eventStreamController.stream;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CachedVideoPlayerPlus', () {
    const channel = MethodChannel('cached_video_player_plus');
    final List<MethodCall> log = <MethodCall>[];
    late MockVideoPlayerPlatform mockPlatform;

    setUp(() {
      mockPlatform = MockVideoPlayerPlatform();
      VideoPlayerPlatform.instance = mockPlatform;
      // Bypass platform registration in CachedVideoPlayerPlus.initialize()
      debugDefaultTargetPlatformOverride = TargetPlatform.fuchsia;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
        log.add(methodCall);
        switch (methodCall.method) {
          case 'init':
            return null;
          case 'create':
            return <String, dynamic>{'textureId': 1};
          case 'dispose':
            return null;
          case 'play':
            return null;
          case 'pause':
            return null;
          case 'setVolume':
            return null;
          case 'position':
            return 0;
          default:
            return null;
        }
      });
      log.clear();
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('asset constructor sets correct data source type', () {
      final player = CachedVideoPlayerPlus.asset('assets/video.mp4');
      expect(player.dataSource, 'assets/video.mp4');
      expect(player.dataSourceType, DataSourceType.asset);
    });

    test('networkUrl constructor sets correct data source type', () {
      final url = Uri.parse('https://example.com/video.mp4');
      final player = CachedVideoPlayerPlus.networkUrl(url);
      expect(player.dataSource, url.toString());
      expect(player.dataSourceType, DataSourceType.network);
    });

    test('file constructor sets correct data source type', () {
      final file = File('/tmp/video.mp4');
      final player = CachedVideoPlayerPlus.file(file);
      expect(player.dataSource, file.absolute.path);
      expect(player.dataSourceType, DataSourceType.file);
    });

    test('initialize creates a controller and marks as initialized', () async {
      final player = CachedVideoPlayerPlus.asset('assets/video.mp4');
      expect(player.isInitialized, isFalse);
      
      await player.initialize();
      
      expect(player.isInitialized, isTrue);
      expect(player.controller, isNotNull);
      // 'create' is called on the VideoPlayerPlatform, not the method channel here 
      // because we mocked the platform instance entirely.
    });

    test('dispose disposes the controller', () async {
      final player = CachedVideoPlayerPlus.asset('assets/video.mp4');
      await player.initialize();
      expect(player.isInitialized, isTrue);

      await player.dispose();
      expect(player.isInitialized, isFalse);
    });
  });
}

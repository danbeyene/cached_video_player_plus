import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class CachedVideoPlayerPlusPlatformAndroid extends VideoPlayerPlatform {
  final MethodChannel _channel = const MethodChannel('cached_video_player_plus');

  /// Registers this class as the default instance of [VideoPlayerPlatform].
  static void registerWith() {
    VideoPlayerPlatform.instance = CachedVideoPlayerPlusPlatformAndroid();
  }

  @override
  Future<void> init() {
    return _channel.invokeMethod<void>('init');
  }

  @override
  Future<void> dispose(int playerId) {
    return _channel.invokeMethod<void>(
      'dispose',
      <String, dynamic>{'textureId': playerId},
    );
  }

  @override
  Future<int?> create(DataSource dataSource) async {
    final Map<String, dynamic> args = <String, dynamic>{};
    
    switch (dataSource.sourceType) {
      case DataSourceType.asset:
        args['asset'] = dataSource.asset;
        args['package'] = dataSource.package;
        args['uri'] = dataSource.asset; 
        break;
      case DataSourceType.network:
        args['uri'] = dataSource.uri;
        args['formatHint'] = _videoFormatString(dataSource.formatHint);
        args['httpHeaders'] = dataSource.httpHeaders;
        break;
      case DataSourceType.file:
        args['uri'] = dataSource.uri;
        break;
      case DataSourceType.contentUri:
        args['uri'] = dataSource.uri;
        break;
    }

    final Map<Object?, Object?>? response = await _channel.invokeMapMethod<Object?, Object?>('create', args);
    return response?['textureId'] as int?;
  }

  @override
  Future<void> setLooping(int playerId, bool looping) {
    return _channel.invokeMethod<void>(
      'setLooping',
      <String, dynamic>{
        'textureId': playerId,
        'looping': looping,
      },
    );
  }

  @override
  Future<void> play(int playerId) {
    return _channel.invokeMethod<void>(
      'play',
      <String, dynamic>{'textureId': playerId},
    );
  }

  @override
  Future<void> pause(int playerId) {
    return _channel.invokeMethod<void>(
      'pause',
      <String, dynamic>{'textureId': playerId},
    );
  }

  @override
  Future<void> setVolume(int playerId, double volume) {
    return _channel.invokeMethod<void>(
      'setVolume',
      <String, dynamic>{
        'textureId': playerId,
        'volume': volume,
      },
    );
  }
  
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) {
      return _channel.invokeMethod<void>(
        'setPlaybackSpeed',
        <String, dynamic>{
          'textureId': playerId,
          'speed': speed,
        },
      );
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) {
    return _channel.invokeMethod<void>(
      'setMixWithOthers',
      <String, dynamic>{
        'mixWithOthers': mixWithOthers,
      },
    );
  }

  @override
  Future<void> setCaptionOffset(int playerId, Duration delay) {
    return _channel.invokeMethod<void>(
      'setCaptionOffset',
      <String, dynamic>{
        'textureId': playerId,
        'offset': delay.inMilliseconds,
      },
    );
  }

  @override
  Future<void> seekTo(int playerId, Duration position) {
    return _channel.invokeMethod<void>(
      'seekTo',
      <String, dynamic>{
        'textureId': playerId,
        'position': position.inMilliseconds,
      },
    );
  }

  @override
  Future<Duration> getPosition(int playerId) async {
    final int? position = await _channel.invokeMethod<int>(
      'position',
      <String, dynamic>{'textureId': playerId},
    );
    return Duration(milliseconds: position ?? 0);
  }

  @override
  Widget buildView(int playerId) {
    return Texture(textureId: playerId);
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    return EventChannel('cached_video_player_plus/videoEvents$playerId')
        .receiveBroadcastStream()
        .map((dynamic event) {
            final Map<dynamic, dynamic> map = event as Map<dynamic, dynamic>;
            switch (map['event']) {
                case 'initialized':
                    return VideoEvent(
                        eventType: VideoEventType.initialized,
                        duration: Duration(milliseconds: map['duration'] as int),
                        size: Size((map['width'] as num).toDouble(), (map['height'] as num).toDouble()),
                    );
                case 'completed':
                    return VideoEvent(eventType: VideoEventType.completed);
                case 'bufferingUpdate':
                    final List<dynamic> values = map['values'] as List<dynamic>;
                    return VideoEvent(
                        eventType: VideoEventType.bufferingUpdate,
                        buffered: values.map<DurationRange>((dynamic value) {
                            final List<dynamic> range = value as List<dynamic>;
                            return DurationRange(
                                Duration(milliseconds: range[0] as int),
                                Duration(milliseconds: range[1] as int),
                            );
                        }).toList(),
                    );
                case 'bufferingStart':
                    return VideoEvent(eventType: VideoEventType.bufferingStart);
                case 'bufferingEnd':
                    return VideoEvent(eventType: VideoEventType.bufferingEnd);
                case 'isPlayingStateUpdate':
                    return VideoEvent(
                      eventType: VideoEventType.isPlayingStateUpdate,
                      isPlaying: map['isPlaying'] as bool,
                    );  
                default:
                    return VideoEvent(eventType: VideoEventType.unknown);
            }
        });
  }
}

String? _videoFormatString(VideoFormat? format) {
  switch (format) {
    case VideoFormat.dash:
      return 'dash';
    case VideoFormat.hls:
      return 'hls';
    case VideoFormat.ss:
      return 'ss';
    case VideoFormat.other:
      return 'other';
    case null:
      return null;
  }
}

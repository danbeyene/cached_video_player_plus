import 'package:shared_preferences/shared_preferences.dart';

import 'cache_key_helpers.dart' show cacheKeyPrefix;
import 'i_video_player_metadata_storage.dart';

/// This class handles the storage of cache expiration timestamps and provides
/// migration functionality from get_storage to shared_preferences.
/// 
/// You can optionally inject your app's [SharedPreferences] instance to share
/// the same instance across your app and this library:
/// 
/// ```dart
/// // In your app initialization:
/// final prefs = await SharedPreferences.getInstance();
/// VideoPlayerMetadataStorage.setSharedPreferences(prefs);
/// ```
class VideoPlayerMetadataStorage implements IVideoPlayerMetadataStorage {
  /// Optional injected SharedPreferences instance from the app.
  static SharedPreferences? _injectedPrefs;
  
  /// Fallback async prefs when no instance is injected.
  SharedPreferencesAsync? _asyncPrefs;

  /// Singleton instance of VideoPlayerStorage.
  static final _instance = VideoPlayerMetadataStorage._internal();

  /// Private constructor for singleton pattern implementation.
  VideoPlayerMetadataStorage._internal();

  /// Factory constructor that returns the singleton instance.
  factory VideoPlayerMetadataStorage() => _instance;

  /// Sets a shared [SharedPreferences] instance to be used by the library.
  /// 
  /// Call this once during app initialization if you want to share your app's
  /// SharedPreferences instance with the library:
  /// 
  /// ```dart
  /// // In main() or during app startup:
  /// final prefs = await SharedPreferences.getInstance();
  /// VideoPlayerMetadataStorage.setSharedPreferences(prefs);
  /// ```
  /// 
  /// If not called, the library will use its own internal async instance.
  static void setSharedPreferences(SharedPreferences prefs) {
    _injectedPrefs = prefs;
  }
  
  /// Gets the async prefs instance (lazy initialization).
  SharedPreferencesAsync get _prefs {
    _asyncPrefs ??= SharedPreferencesAsync();
    return _asyncPrefs!;
  }

  @override
  Future<Set<String>> get keys async {
    if (_injectedPrefs != null) {
      return _injectedPrefs!.getKeys();
    }
    return _prefs.getKeys();
  }

  @override
  Future<int?> read(String key) async {
    if (_injectedPrefs != null) {
      return _injectedPrefs!.getInt(key);
    }
    return _prefs.getInt(key);
  }

  @override
  Future<void> write(String key, int value) async {
    if (_injectedPrefs != null) {
      await _injectedPrefs!.setInt(key, value);
      return;
    }
    return _prefs.setInt(key, value);
  }

  @override
  Future<void> remove(String key) async {
    if (_injectedPrefs != null) {
      await _injectedPrefs!.remove(key);
      return;
    }
    return _prefs.remove(key);
  }

  @override
  Future<void> erase() async {
    final allKeys = await keys;
    final videoPlayerKeys = allKeys.where((key) => key.startsWith(cacheKeyPrefix));

    for (final key in videoPlayerKeys) {
      await remove(key);
    }
  }
}

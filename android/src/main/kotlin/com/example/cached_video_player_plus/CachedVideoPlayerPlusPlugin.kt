package com.example.cached_video_player_plus

import android.content.Context
import androidx.annotation.NonNull
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry
import io.flutter.plugin.common.BinaryMessenger
import android.net.Uri
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import java.util.concurrent.ConcurrentHashMap
import io.flutter.FlutterInjector
import android.os.Handler
import android.os.Looper

/** CachedVideoPlayerPlusPlugin */
class CachedVideoPlayerPlusPlugin: FlutterPlugin, MethodCallHandler {
  
  private lateinit var channel : MethodChannel
  private lateinit var textureRegistry: TextureRegistry
  private lateinit var context: Context
  private lateinit var binaryMessenger: BinaryMessenger
  
  // Use Long for textureId (Dart int is 64-bit)
  private val players = ConcurrentHashMap<Long, VideoPlayer>()
  private var mixWithOthers = false

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "cached_video_player_plus")
    channel.setMethodCallHandler(this)
    textureRegistry = flutterPluginBinding.textureRegistry
    context = flutterPluginBinding.applicationContext
    binaryMessenger = flutterPluginBinding.binaryMessenger
    
    // Initialize CacheManager on a background thread to avoid blocking UI
    Thread {
        CacheManager.getInstance(context)
    }.start()
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    when (call.method) {
        "init" -> {
            result.success(null)
        }
        "create" -> {
            val args = call.arguments as? Map<String, Any?>
            val uri = args?.get("uri") as? String
            val formatHint = args?.get("formatHint") as? String
            val httpHeaders = args?.get("httpHeaders") as? Map<String, String> ?: emptyMap()
            
            if (uri == null) {
                result.error("invalid_args", "uri is null", null)
                return
            }

            val asset = args?.get("asset") as? String
            val packageName = args?.get("package") as? String
            
            val finalUri = if (asset != null) {
                val loader = FlutterInjector.instance().flutterLoader()
                val assetLookupKey = if (packageName != null) loader.getLookupKeyForAsset(asset, packageName) else loader.getLookupKeyForAsset(asset)
                "asset:///$assetLookupKey"
            } else {
                uri
            }

            val producer = textureRegistry.createSurfaceProducer()
            val eventChannel = EventChannel(binaryMessenger, "cached_video_player_plus/videoEvents${producer.id()}")
            
            val player = VideoPlayer(context, eventChannel, producer, finalUri, formatHint, httpHeaders)
            player.setAudioAttributes(mixWithOthers)
            players[producer.id()] = player
            
            val reply = HashMap<String, Any>()
            reply["textureId"] = producer.id()
            result.success(reply)
        }
        "setMixWithOthers" -> {
            mixWithOthers = call.argument<Boolean>("mixWithOthers") ?: false
            result.success(null)
        }
        "clearAllCache" -> {
             Thread {
                 CacheManager.getInstance(context).clearAllCache()
                 Handler(Looper.getMainLooper()).post {
                     result.success(null)
                 }
             }.start()
        }
        "removeFile" -> {
             val args = call.arguments as? Map<String, Any?>
             val url = args?.get("url") as? String
             if (url != null) {
                 Thread {
                     CacheManager.getInstance(context).removeFile(url)
                     Handler(Looper.getMainLooper()).post {
                         result.success(null)
                     }
                 }.start()
             } else {
                 result.success(null)
             }
        }
        "enforceCacheLimit" -> {
             val args = call.arguments as? Map<String, Any?>
             // Handling different number types from Dart
             val max = (args?.get("maxCacheSize") as? Number)?.toLong()
             if (max != null) {
                 Thread {
                     CacheManager.getInstance(context).enforceCacheLimit(max)
                     Handler(Looper.getMainLooper()).post {
                         result.success(null)
                     }
                 }.start()
             } else {
                 result.success(null)
             }
        }
        "preCache" -> {
             val args = call.arguments as? Map<String, Any?>
             val url = args?.get("url") as? String
             val headers = args?.get("headers") as? Map<String, String> ?: emptyMap()
             
             if (url != null) {
                 Thread {
                     try {
                         val uri = Uri.parse(url)
                         val dataSpec = DataSpec(uri)
                         val upstreamDataSource = DefaultHttpDataSource.Factory()
                             .setUserAgent("cached_video_player_plus")
                             .setDefaultRequestProperties(headers)
                             .createDataSource()
                         
                         val cache = CacheManager.getInstance(context).simpleCache
                         val cacheDataSource = CacheDataSource(cache, upstreamDataSource)
                         val cacheWriter = CacheWriter(cacheDataSource, dataSpec, null, null)
                         cacheWriter.cache()
                         
                         Handler(Looper.getMainLooper()).post {
                             result.success(null)
                         }
                     } catch (e: Exception) {
                         e.printStackTrace()
                         Handler(Looper.getMainLooper()).post {
                             result.error("cache_error", e.message, null)
                         }
                     }
                 }.start()
             } else {
                 result.error("invalid_args", "url is null", null)
             }
        }
        else -> {
            val args = call.arguments as? Map<String, Any?>
            val textureId = (args?.get("textureId") as? Number)?.toLong()
            
            if (textureId != null) {
                if (call.method == "dispose") {
                    val player = players.remove(textureId)
                    player?.dispose()
                    result.success(null)
                    return
                }

                val player = players[textureId]
                if (player != null) {
                    when (call.method) {
                        "play" -> { player.play(); result.success(null) }
                        "pause" -> { player.pause(); result.success(null) }
                        "setLooping" -> { 
                            val looping = args?.get("looping") as? Boolean ?: false
                            player.setLooping(looping)
                            result.success(null)
                        }
                        "setVolume" -> {
                            val volume = (args?.get("volume") as? Number)?.toDouble() ?: 0.0
                            player.setVolume(volume)
                            result.success(null)
                        }
                        "setPlaybackSpeed" -> {
                            val speed = (args?.get("speed") as? Number)?.toDouble() ?: 1.0
                            player.setPlaybackSpeed(speed)
                            result.success(null)
                        }
                        "seekTo" -> {
                             val pos = (args?.get("position") as? Number)?.toInt() ?: 0
                             player.seekTo(pos)
                             result.success(null)
                        }
                        "position" -> {
                            result.success(player.getPosition())
                        }
                        else -> result.notImplemented()
                    }
                } else {
                    result.error("unknown_player", "No player found for textureId $textureId", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    for (player in players.values) {
        player.dispose()
    }
    players.clear()
  }
}

package com.example.cached_video_player_plus

import android.content.Context
import android.net.Uri
import android.view.Surface
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.upstream.DefaultAllocator
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import io.flutter.plugin.common.EventChannel
import io.flutter.view.TextureRegistry
import java.util.HashMap

class VideoPlayer(
    private val context: Context,
    private val eventChannel: EventChannel,
    private val textureEntry: TextureRegistry.SurfaceProducer,
    private val dataSource: String,
    private val formatHint: String?,
    private val httpHeaders: Map<String, String>
) {
    private var exoPlayer: ExoPlayer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var surface: Surface? = null
    private var isInitialized = false
    private var captionOffset: Long = 0L

    init {
        setupEventChannel()
        initializePlayer()
    }

    private fun setupEventChannel() {
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    private fun initializePlayer() {
        // Optimize buffering for faster startup
        val loadControl = DefaultLoadControl.Builder()
            .setAllocator(DefaultAllocator(true, C.DEFAULT_BUFFER_SEGMENT_SIZE))
            .setBufferDurationsMs(
                DefaultLoadControl.DEFAULT_MIN_BUFFER_MS,
                DefaultLoadControl.DEFAULT_MAX_BUFFER_MS,
                500, // bufferForPlaybackMs: Reduce to 500ms for faster start
                1000 // bufferForPlaybackAfterRebufferMs: Reduce to 1s
            )
            .build()
            
        exoPlayer = ExoPlayer.Builder(context)
            .setLoadControl(loadControl)
            .build()
        
        val uri = Uri.parse(dataSource)
        
        // Prepare DataSource capable of Caching
        val cacheManager = CacheManager.getInstance(context)
        
        // Upstream (Network)
        val httpDataSourceFactory = DefaultHttpDataSource.Factory()
            .setAllowCrossProtocolRedirects(true)
        
        // Base factor for all URIs (assets, files, content://)
        val defaultDataSourceFactory = DefaultDataSource.Factory(context, httpDataSourceFactory)

        // Cache Layer wrapping the default factory
        val cacheDataSourceFactory = CacheDataSource.Factory()
            .setCache(cacheManager.simpleCache)
            .setUpstreamDataSourceFactory(defaultDataSourceFactory)
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR) 
        
        // Media Source
        val mediaItem = MediaItem.fromUri(uri)
        
        // If it is network, use cache factory.
        if (dataSource.startsWith("http") || dataSource.startsWith("https")) {
            val mediaSourceFactory = androidx.media3.exoplayer.source.DefaultMediaSourceFactory(cacheDataSourceFactory)
            exoPlayer?.setMediaSource(mediaSourceFactory.createMediaSource(mediaItem))
        } else {
             // Local file / asset - use default factory (no cache)
            val mediaSourceFactory = androidx.media3.exoplayer.source.DefaultMediaSourceFactory(defaultDataSourceFactory)
            exoPlayer?.setMediaSource(mediaSourceFactory.createMediaSource(mediaItem))
        }
        
        setupListeners()
        
        textureEntry.setSize(1080, 1920)
        surface = textureEntry.surface
        exoPlayer?.setVideoSurface(surface)
        
        exoPlayer?.prepare()
    }

    private fun setupListeners() {
        exoPlayer?.addListener(object : Player.Listener {
            override fun onPlaybackStateChanged(playbackState: Int) {
                when (playbackState) {
                    Player.STATE_BUFFERING -> {
                        sendBufferingUpdate()
                    }
                    Player.STATE_READY -> {
                         if (!isInitialized) {
                             isInitialized = true
                             sendInitialized()
                         }
                    }
                    Player.STATE_ENDED -> {
                        val event = HashMap<String, Any>()
                        event["event"] = "completed"
                        eventSink?.success(event)
                    }
                    Player.STATE_IDLE -> {}
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                eventSink?.error("VideoError", "Video player had error $error", null)
            }
            
            override fun onVideoSizeChanged(videoSize: VideoSize) {
                val width = videoSize.width
                val height = videoSize.height
                textureEntry.setSize(width, height)
                
                 if (isInitialized) {
                     val event = HashMap<String, Any>()
                     event["event"] = "isPlayingStateUpdate"
                     event["isPlaying"] = exoPlayer?.isPlaying ?: false
                     eventSink?.success(event)
                 }
            }
            
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                 val event = HashMap<String, Any>()
                 event["event"] = "isPlayingStateUpdate"
                 event["isPlaying"] = isPlaying
                 eventSink?.success(event)
            }

            override fun onIsLoadingChanged(isLoading: Boolean) {
                 // Priority Management: Pause pre-cache if we are actively loading (buffering/downloading)
                 if (isLoading) {
                     CacheManager.getInstance(context).incrementActiveDownloadCount()
                 } else {
                     CacheManager.getInstance(context).decrementActiveDownloadCount()
                 }
            }
        })
    }

    private fun sendBufferingUpdate() {
        val event = HashMap<String, Any>()
        event["event"] = "bufferingUpdate"
        val ranges = ArrayList<List<Number>>()
        // ExoPlayer buffers ahead, but simple mapped range support is minimal in basic listener.
        // We can just send 0..bufferedPosition
        val buffered = exoPlayer?.bufferedPosition ?: 0L
        ranges.add(listOf(0, buffered))
        event["values"] = ranges
        eventSink?.success(event)
    }

    private fun sendInitialized() {
        val event = HashMap<String, Any>()
        event["event"] = "initialized"
        event["duration"] = exoPlayer?.duration ?: 0L
        
        val size = exoPlayer?.videoSize
        event["width"] = size?.width ?: 0
        event["height"] = size?.height ?: 0
        
        eventSink?.success(event)
    }

    fun play() {
        exoPlayer?.play()
    }

    fun pause() {
        exoPlayer?.pause()
    }

    fun setLooping(looping: Boolean) {
        exoPlayer?.repeatMode = if (looping) Player.REPEAT_MODE_ONE else Player.REPEAT_MODE_OFF
    }

    fun setVolume(volume: Double) {
        exoPlayer?.volume = volume.toFloat()
    }

    fun setPlaybackSpeed(speed: Double) {
        exoPlayer?.setPlaybackSpeed(speed.toFloat())
    }

    fun setAudioAttributes(mixWithOthers: Boolean) {
        val audioAttributes = AudioAttributes.Builder()
            .setUsage(C.USAGE_MEDIA)
            .setContentType(C.AUDIO_CONTENT_TYPE_MOVIE)
            .build()
        exoPlayer?.setAudioAttributes(audioAttributes, !mixWithOthers)
    }

    fun setCaptionOffset(offset: Long) {
        captionOffset = offset
    }

    fun seekTo(location: Int) {
        exoPlayer?.seekTo(location.toLong())
    }

    fun getPosition(): Long {
        return exoPlayer?.currentPosition ?: 0L
    }

    fun dispose() {
        if (exoPlayer?.isLoading == true) {
            CacheManager.getInstance(context).decrementActiveDownloadCount()
        }
        
        exoPlayer?.release()
        surface?.release()
        textureEntry.release()
        eventSink = null
    }
}

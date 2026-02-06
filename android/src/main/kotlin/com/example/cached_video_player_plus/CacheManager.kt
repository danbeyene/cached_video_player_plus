package com.example.cached_video_player_plus

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.media3.common.util.UnstableApi
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.cache.CacheWriter
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Collections
import java.util.LinkedList
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.Future

@UnstableApi
class CacheManager private constructor(private val context: Context) {

    companion object {
        @Volatile
        private var INSTANCE: CacheManager? = null
        private const val MAX_CACHE_SIZE = 500 * 1024 * 1024L // 500 MB default

        fun getInstance(context: Context): CacheManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: CacheManager(context).also { INSTANCE = it }
            }
        }
    }

    private val cacheDir: File = File(context.cacheDir, "cached_video_player_plus")
    private var evictor: LeastRecentlyUsedCacheEvictor = LeastRecentlyUsedCacheEvictor(MAX_CACHE_SIZE)
    private var databaseProvider: StandaloneDatabaseProvider = StandaloneDatabaseProvider(context)
    
    val simpleCache: SimpleCache

    // Concurrency & Priority
    private val executor = Executors.newFixedThreadPool(2)
    private val taskQueue = LinkedList<PreCacheRequest>()
    private val activeTasks = ConcurrentHashMap<String, PreCacheTask>()
    private var activeDownloadCount = 0
    private val lock = Any()

    init {
        if (!cacheDir.exists()) {
            cacheDir.mkdirs()
        }
        simpleCache = SimpleCache(cacheDir, evictor, databaseProvider)
    }

    // MARK: - Priority Management

    fun incrementActiveDownloadCount() {
        synchronized(lock) {
            activeDownloadCount++
            if (activeDownloadCount == 1) {
                pausePreCaching()
            }
        }
    }

    fun decrementActiveDownloadCount() {
        synchronized(lock) {
            if (activeDownloadCount > 0) {
                activeDownloadCount--
            }
            if (activeDownloadCount == 0) {
                resumePreCaching()
            }
        }
    }

    private fun pausePreCaching() {
        // Cancel all active tasks
        val tasks = ArrayList(activeTasks.values)
        for (task in tasks) {
            task.cancel()
            // Re-queue task to handle partial downloads or restarts when idle.
            taskQueue.addFirst(task.request)
        }
        activeTasks.clear()
        // println("CVPP: Paused pre-caching. Active tasks cancelled and re-queued.")
    }

    private fun resumePreCaching() {
        // println("CVPP: Resuming pre-caching.")
        processQueue()
    }

    private fun processQueue() {
        synchronized(lock) {
            if (activeDownloadCount > 0) return
            
            while (activeTasks.size < 2 && !taskQueue.isEmpty()) {
                val request = taskQueue.poll() ?: break
                startTask(request)
            }
        }
    }

    private fun startTask(request: PreCacheRequest) {
        val task = PreCacheTask(request, this)
        activeTasks[request.url] = task
        executor.submit {
            task.run()
            synchronized(lock) {
                activeTasks.remove(request.url)
                processQueue() // Trigger next
            }
        }
    }

    // MARK: - Pre-Caching API

    fun preCache(url: String, headers: Map<String, String>, result: MethodChannel.Result?) {
        synchronized(lock) {
            val request = PreCacheRequest(url, headers, result)
            taskQueue.add(request)
            processQueue()
        }
    }

    // MARK: - File System Operations

    fun clearAllCache() {
        synchronized(lock) {
             try {
                for (key in simpleCache.keys) {
                    simpleCache.removeResource(key)
                }
             } catch (e: Exception) {
                e.printStackTrace()
             }
        }
    }
    
    fun removeFile(url: String) {
        synchronized(lock) {
            try {
                simpleCache.removeResource(url)
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }

    fun enforceCacheLimit(maxSize: Long) {
        synchronized(lock) {
            try {
                var currentSize = simpleCache.cacheSpace
                if (currentSize <= maxSize) return
                
                // Collecting spans logic similar to previous, but synchronized
                val allSpans = mutableListOf<androidx.media3.datasource.cache.CacheSpan>()
                for (key in simpleCache.keys) {
                    allSpans.addAll(simpleCache.getCachedSpans(key))
                }
                allSpans.sortBy { it.lastTouchTimestamp }

                for (span in allSpans) {
                    if (currentSize <= maxSize) break
                    val length = span.length
                    simpleCache.removeSpan(span)
                    currentSize -= length
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
        }
    }
    
    // Helper classes
    
    class PreCacheRequest(val url: String, val headers: Map<String, String>, val result: MethodChannel.Result?)
    
    class PreCacheTask(val request: PreCacheRequest, val manager: CacheManager) {
        private var cacheWriter: CacheWriter? = null
        @Volatile var isCancelled = false
        
        fun cancel() {
            isCancelled = true
            cacheWriter?.cancel()
        }
        
        fun run() {
            if (isCancelled) return
            try {
                val uri = Uri.parse(request.url)
                val dataSpec = DataSpec(uri)
                val upstreamDataSource = DefaultHttpDataSource.Factory()
                    .setUserAgent("cached_video_player_plus")
                    .setDefaultRequestProperties(request.headers)
                    .createDataSource()
                
                val cacheDataSource = CacheDataSource(manager.simpleCache, upstreamDataSource)
                
                // Using CacheWriter
                val writer = CacheWriter(cacheDataSource, dataSpec, null) { requestLength, bytesCached, newBytesCached ->
                     // Progress callback if needed
                }
                cacheWriter = writer
                writer.cache()
                
                if (!isCancelled) {
                    Handler(Looper.getMainLooper()).post {
                        request.result?.success(null)
                    }
                }
            } catch (e: Exception) {
                if (!isCancelled) {
                     Handler(Looper.getMainLooper()).post {
                        // Cancellation exception is expected if we cancelled it
                        if (e.message?.contains("Cancellation") == true) {
                            // Do nothing
                        } else {
                            request.result?.error("cache_error", e.message, null)
                        }
                    }
                }
            }
        }
    }
    
    fun getCachePath(url: String): String? {
        return null 
    }
}

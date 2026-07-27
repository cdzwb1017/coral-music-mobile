package com.coral.music.mobile

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import androidx.core.content.ContextCompat
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.datasource.ResolvingDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.common.C
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.IOException
import java.io.ByteArrayOutputStream
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.ConcurrentHashMap

object NativePlaybackEvents : EventChannel.StreamHandler {
    private val sinks = CopyOnWriteArraySet<EventChannel.EventSink>()
    override fun onListen(arguments: Any?, events: EventChannel.EventSink) { sinks += events }
    override fun onCancel(arguments: Any?) { sinks.clear() }
    fun emit(values: Map<String, Any>) = sinks.forEach { it.success(values) }
}

class NativePlaybackService : MediaSessionService() {
    private lateinit var player: ExoPlayer
    private lateinit var session: MediaSession
    @Volatile private var tracks = emptyList<JSONObject>()
    private var current = -1
    private var mode = "listLoop"
    private var autoPlay = false
    private var bitrate: Int? = null
    private var sampleRate: Int? = null
    private var hasAdvancedPosition = false
    private var lastObservedPositionMs = C.TIME_UNSET
    private val sourceFormats = ConcurrentHashMap<Int, SourceFormat>()
    private val attempts = mutableMapOf<Int, Int>()
    private lateinit var positionHandler: Handler
    private val positionTicker = object : Runnable {
        override fun run() {
            val positionMs = player.currentPosition
            if (player.isPlaying && lastObservedPositionMs != C.TIME_UNSET &&
                positionMs != lastObservedPositionMs) {
                hasAdvancedPosition = true
            }
            lastObservedPositionMs = positionMs
            emit()
            if (player.playbackState != Player.STATE_IDLE && player.playbackState != Player.STATE_ENDED) {
                positionHandler.postDelayed(this, 500)
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        val http = DefaultHttpDataSource.Factory()
        val resolving = ResolvingDataSource.Factory(http, object : ResolvingDataSource.Resolver {
            override fun resolveDataSpec(dataSpec: DataSpec): DataSpec {
                val index = dataSpec.uri.lastPathSegment?.toIntOrNull()
                    ?: throw IOException("无效的逻辑播放地址")
                val track = tracks.getOrNull(index) ?: throw IOException("播放曲目已不存在")
                val resolved = UserApiRuntime.runner.resolveForPlayback(mapOf(
                    "source" to track.optString("source"),
                    "quality" to track.optString("quality"),
                    "musicInfo" to track.optJSONObject("musicInfo").toMap(),
                ))
                if (isLowerQuality(resolved.quality, track.optString("quality"))) {
                    throw IOException("该曲无此音质")
                }
                return dataSpec.buildUpon()
                    .setUri(resolved.url)
                    .setHttpRequestHeaders(resolved.headers)
                    .build()
            }
        })
        val inspecting = DataSource.Factory {
            val upstream = resolving.createDataSource()
            object : DataSource {
                private var index = -1
                private var startsAtZero = false
                private var fullResponse = false
                private val header = ByteArrayOutputStream(42)

                override fun addTransferListener(transferListener: TransferListener) =
                    upstream.addTransferListener(transferListener)

                override fun open(dataSpec: DataSpec): Long {
                    index = dataSpec.uri.lastPathSegment?.toIntOrNull() ?: -1
                    startsAtZero = dataSpec.position == 0L
                    fullResponse = dataSpec.length == C.LENGTH_UNSET.toLong()
                    header.reset()
                    return upstream.open(dataSpec)
                }

                override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                    val count = upstream.read(buffer, offset, length)
                    if (startsAtZero && index >= 0 && count > 0 && header.size() < 42) {
                        header.write(buffer, offset, minOf(count, 42 - header.size()))
                        inspectFlacHeader(index, header.toByteArray(), upstream.responseHeaders, fullResponse)
                    }
                    return count
                }

                override fun getUri() = upstream.uri
                override fun getResponseHeaders() = upstream.responseHeaders
                override fun close() = upstream.close()
            }
        }
        player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(DefaultMediaSourceFactory(inspecting))
            .build()
        positionHandler = Handler(player.applicationLooper)
        session = MediaSession.Builder(this, player).build()
        player.addListener(object : Player.Listener {
            override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
                current = item?.mediaId?.removePrefix("coral:")?.toIntOrNull() ?: current
                bitrate = null; sampleRate = null
                hasAdvancedPosition = false; lastObservedPositionMs = C.TIME_UNSET
                sourceFormats[current]?.let { format ->
                    bitrate = format.bitrate; sampleRate = format.sampleRate
                }
                emit("loading")
            }
            override fun onPlaybackStateChanged(state: Int) {
                emit(when (state) {
                    Player.STATE_BUFFERING -> "loading"
                    Player.STATE_READY -> if (player.playWhenReady && !hasAdvancedPosition) "loading"
                    else if (player.isPlaying) "playing" else "ready"
                    Player.STATE_ENDED -> "completed"
                    else -> "idle"
                })
            }
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (!isPlaying) emit(if (player.playWhenReady) "loading" else "paused")
            }
            override fun onPlayerError(error: androidx.media3.common.PlaybackException) { retry("音频加载失败") }
        })
        player.addAnalyticsListener(object : AnalyticsListener {
            override fun onAudioInputFormatChanged(
                eventTime: AnalyticsListener.EventTime,
                format: androidx.media3.common.Format,
                decoderReuseEvaluation: androidx.media3.exoplayer.DecoderReuseEvaluation?,
            ) {
                val reportedBitrate = format.bitrate.takeIf { it > 0 }
                    ?: format.averageBitrate.takeIf { it > 0 }
                    ?: format.peakBitrate.takeIf { it > 0 }
                reportedBitrate?.let { bitrate = it }
                format.sampleRate.takeIf { it > 0 }?.let { sampleRate = it }
                emit()
            }
        })
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo) = session
    override fun onDestroy() {
        positionHandler.removeCallbacks(positionTicker)
        session.release(); player.release(); super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            "startQueue" -> {
                start(JSONObject(intent.getStringExtra("payload") ?: "{}"))
            }
            "play" -> { autoPlay = true; player.play(); emit("playing") }
            "pause" -> { player.pause(); emit("paused") }
            "stop" -> stop()
            "next" -> player.seekToNextMediaItem()
            "previous" -> player.seekToPreviousMediaItem()
            "seek" -> player.seekTo(intent.getLongExtra("positionMs", 0))
        }
        return START_STICKY
    }

    private fun start(payload: JSONObject) {
        val items = payload.optJSONArray("tracks") ?: return emit("error", "播放队列为空")
        tracks = List(items.length()) { items.getJSONObject(it) }
        current = payload.optInt("index", -1)
        if (current !in tracks.indices) return emit("error", "播放索引无效")
        mode = payload.optString("mode", "listLoop"); autoPlay = payload.optBoolean("autoPlay", true)
        attempts.clear(); bitrate = null; sampleRate = null; sourceFormats.clear()
        hasAdvancedPosition = false; lastObservedPositionMs = C.TIME_UNSET
        player.setMediaItems(
            List(tracks.size) { index ->
                val track = tracks[index]
                val artwork = track.optString("artwork").let(Uri::parse)
                    .takeIf { it.scheme in setOf("http", "https") }
                MediaItem.Builder()
                    .setMediaId("coral:$index")
                    .setUri(Uri.parse("coral://queue/$index"))
                    .setMediaMetadata(
                        MediaMetadata.Builder()
                            .setTitle(track.optString("title"))
                            .setArtist(track.optString("artist"))
                            .setAlbumTitle(track.optString("album"))
                            .setArtworkUri(artwork)
                            .setIsPlayable(true)
                            .build(),
                    )
                    .build()
            },
            current,
            0,
        )
        player.repeatMode = when (mode) {
            "singleLoop" -> Player.REPEAT_MODE_ONE
            "listLoop" -> Player.REPEAT_MODE_ALL
            else -> Player.REPEAT_MODE_OFF
        }
        player.shuffleModeEnabled = mode == "shuffle"
        player.prepare()
        if (autoPlay) player.play()
        positionHandler.removeCallbacks(positionTicker)
        positionHandler.post(positionTicker)
        emit(if (autoPlay) "loading" else "ready")
    }

    private fun retry(message: String) {
        val count = (attempts[current] ?: 0) + 1; attempts[current] = count
        if (count >= 3) { player.pause(); emit("error", message); return }
        android.os.Handler(player.applicationLooper)
            .postDelayed({ player.prepare(); if (autoPlay) player.play(); emit("loading") }, count * 1000L)
    }

    private fun isLowerQuality(actual: String, requested: String): Boolean {
        val levels = listOf("master", "atmos_plus", "atmos", "hires", "flac24bit", "flac", "320k", "192k", "128k")
        val actualIndex = levels.indexOf(actual); val requestedIndex = levels.indexOf(requested)
        return actualIndex >= 0 && requestedIndex >= 0 && actualIndex > requestedIndex
    }
    private fun stop() {
        autoPlay = false; player.stop(); player.clearMediaItems(); attempts.clear()
        positionHandler.removeCallbacks(positionTicker)
        emit("idle")
    }
    private fun emit(status: String? = null, error: String? = null) {
        val liveStatus = when {
            player.isPlaying && hasAdvancedPosition -> "playing"
            player.playWhenReady -> "loading"
            else -> "paused"
        }
        val values = mutableMapOf<String, Any>("index" to current, "status" to (status ?: liveStatus), "positionMs" to player.currentPosition)
        if (tracks.indices.contains(current)) {
            val track = tracks[current]
            values["quality"] = track.optString("quality")
            values["durationMs"] = player.duration.takeIf { it > 0 }
                ?: track.optLong("durationMs").takeIf { it > 0 }
                ?: 0L
        }
        (bitrate ?: declaredBitrate())?.let { values["bitrate"] = it }
        sampleRate?.let { values["sampleRate"] = it }
        if (error != null) values["error"] = error
        NativePlaybackEvents.emit(values)
    }

    private fun declaredBitrate(): Int? {
        val track = tracks.getOrNull(current) ?: return null
        val durationMs = track.optLong("durationMs").takeIf { it > 0 } ?: return null
        val quality = track.optString("quality")
        val musicInfo = track.optJSONObject("musicInfo")
        val size = listOf(
            musicInfo?.optJSONObject("_qualitys"),
            musicInfo?.optJSONObject("meta")?.optJSONObject("_qualitys"),
            musicInfo?.optJSONObject("_types"),
        ).firstNotNullOfOrNull { qualitys ->
            qualitys?.optJSONObject(quality)?.optLong("size")?.takeIf { it > 0 }
        } ?: return null
        return (size * 8_000 / durationMs).toInt().takeIf { it > 0 }
    }

    private fun inspectFlacHeader(
        index: Int,
        bytes: ByteArray,
        responseHeaders: Map<String, List<String>>,
        fullResponse: Boolean,
    ) {
        if (bytes.size < 26 || bytes[0] != 'f'.code.toByte() || bytes[1] != 'L'.code.toByte() ||
            bytes[2] != 'a'.code.toByte() || bytes[3] != 'C'.code.toByte()) return
        fun byteAt(offset: Int) = bytes[offset].toInt() and 0xff
        val rate = byteAt(18) shl 12 or byteAt(19) shl 4 or byteAt(20) shr 4
        val samples = ((byteAt(21).toLong() and 0x0f) shl 32) or
            (byteAt(22).toLong() shl 24) or (byteAt(23).toLong() shl 16) or
            (byteAt(24).toLong() shl 8) or byteAt(25).toLong()
        val totalBytes = responseHeaders.entries.firstOrNull { it.key.equals("Content-Range", true) }
            ?.value?.firstOrNull()?.substringAfterLast('/')?.toLongOrNull()
            ?: if (fullResponse) responseHeaders.entries
                .firstOrNull { it.key.equals("Content-Length", true) }
                ?.value?.firstOrNull()?.toLongOrNull() else null
        val format = SourceFormat(
            bitrate = if (totalBytes != null && samples > 0 && rate > 0)
                (totalBytes * 8 * rate / samples).toInt().takeIf { it in 8_000..10_000_000 } else null,
            sampleRate = rate.takeIf { it > 0 },
        )
        sourceFormats[index] = format
        if (index == current) {
            bitrate = format.bitrate ?: bitrate
            sampleRate = format.sampleRate ?: sampleRate
            positionHandler.post { emit() }
        }
    }

    companion object {
        fun command(context: Context, method: String, arguments: Map<*, *>?, result: MethodChannel.Result) {
            val intent = Intent(context, NativePlaybackService::class.java).setAction(method)
            if (method == "startQueue") intent.putExtra("payload", JSONObject(arguments ?: emptyMap<String, Any?>()).toString())
            if (method == "seek") intent.putExtra("positionMs", (arguments?.get("positionMs") as? Number)?.toLong() ?: 0)
            if (method == "startQueue") ContextCompat.startForegroundService(context, intent)
            else context.startService(intent)
            result.success(null)
        }
    }
}

private data class SourceFormat(val bitrate: Int?, val sampleRate: Int?)

private fun JSONObject?.toMap(): Map<String, Any?> = this?.let { value -> value.keys().asSequence().associateWith { value.opt(it) } } ?: emptyMap()

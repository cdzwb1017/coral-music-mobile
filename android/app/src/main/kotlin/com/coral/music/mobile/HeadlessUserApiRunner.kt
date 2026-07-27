package com.coral.music.mobile

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Shared QuickJS runtime for UI and MediaSessionService; never touches an Activity. */
class HeadlessUserApiRunner {
    private val main = Handler(Looper.getMainLooper())
    private val executor = Executors.newSingleThreadExecutor()
    private val runtime = QuickJsRuntime()
    @Volatile private var sources = emptySet<String>()

    fun load(script: String, result: MethodChannel.Result) {
        if (script.isBlank() || script.length > 256 * 1024) {
            result.error("invalid_script", "音源脚本超过大小限制", null)
            return
        }
        executor.execute {
            try {
                val manifest = JSONObject(runtime.nativeLoad(script))
                manifest.optString("error").takeIf(String::isNotBlank)?.let { throw IllegalArgumentException(it) }
                val entries = manifest.optJSONObject("sources") ?: throw IllegalArgumentException("音源脚本未声明来源")
                val enabled = buildSet {
                    entries.keys().forEach { source ->
                        val item = entries.optJSONObject(source)
                        if (item?.optString("type") == "music" && item.optJSONArray("actions")?.toString()?.contains("musicUrl") == true) add(source)
                    }
                }
                require(enabled.isNotEmpty()) { "音源脚本未声明可用的 musicUrl 来源" }
                sources = enabled
                val qualities = enabled.associateWith { source ->
                    val item = entries.optJSONObject(source)
                    val list = item?.optJSONArray("qualitys") ?: item?.optJSONArray("qualities")
                    buildList { for (index in 0 until (list?.length() ?: 0)) list?.optString(index)?.takeIf(String::isNotBlank)?.let(::add) }
                }.filterValues { it.isNotEmpty() }
                main.post { result.success(mapOf("musicUrlSources" to enabled.toList(), "musicUrlQualities" to qualities)) }
            } catch (error: Exception) {
                sources = emptySet()
                main.post { result.error("script_error", error.message?.take(1024), null) }
            }
        }
    }

    fun resolveMusicUrl(arguments: Map<*, *>?, result: MethodChannel.Result) {
        val values = arguments ?: emptyMap<String, Any?>()
        val source = values["source"] as? String ?: ""
        if (source !in sources) {
            result.error("not_ready", "当前音源未支持该歌曲来源", null)
            return
        }
        executor.execute {
            try {
                val resolved = resolve(values)
                main.post { result.success(resolved.asMap()) }
            } catch (error: Exception) {
                main.post { result.error("source_error", error.message?.take(1024) ?: "音源取链失败", null) }
            }
        }
    }

    /** Called by Media3's loader thread; the JS runtime remains serialized here. */
    @Throws(IOException::class)
    fun resolveForPlayback(arguments: Map<*, *>): ResolvedUserApiUrl = try {
        executor.submit<ResolvedUserApiUrl> { resolve(arguments) }.get(20, TimeUnit.SECONDS)
    } catch (error: Exception) {
        throw IOException(error.cause?.message ?: error.message ?: "音源取链失败", error)
    }

    private fun resolve(values: Map<*, *>): ResolvedUserApiUrl {
        val source = values["source"] as? String ?: ""
        require(source in sources) { "当前音源未支持该歌曲来源" }
        val payload = JSONObject().apply {
            put("source", source); put("action", "musicUrl")
            put("info", JSONObject().apply {
                put("type", values["quality"] as? String ?: "128k")
                put("musicInfo", JSONObject(values["musicInfo"] as? Map<*, *> ?: emptyMap<String, Any?>()))
            })
        }
        val raw = JSONObject(runtime.nativeResolve(payload.toString()))
        if (!raw.optBoolean("ok")) throw IllegalArgumentException(raw.optString("error", "音源取链失败"))
        val value = raw.opt("value")
        val detail = when (value) {
            is String -> JSONObject().put("url", value)
            is JSONObject -> value.optJSONObject("data") ?: value
            else -> null
        } ?: throw IllegalArgumentException("音源未返回播放地址")
        val url = detail.optString("url")
        val uri = android.net.Uri.parse(url)
        require(uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank() && url.length <= 8192) { "音源未返回有效的 HTTP 播放地址" }
        val headers = detail.optJSONObject("headers")?.keys()?.asSequence()
            ?.associateWith { detail.optJSONObject("headers")?.optString(it) ?: "" } ?: emptyMap()
        return ResolvedUserApiUrl(url, detail.optString("type"), headers)
    }

    fun clear(result: MethodChannel.Result) { sources = emptySet(); result.success(null) }
}

data class ResolvedUserApiUrl(
    val url: String,
    val quality: String,
    val headers: Map<String, String>,
) {
    fun asMap(): Map<String, Any> = mapOf("url" to url, "type" to quality, "headers" to headers)
}

object UserApiRuntime {
    val runner by lazy { HeadlessUserApiRunner() }
}

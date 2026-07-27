package com.coral.music.mobile

import android.net.Uri
import android.util.Base64
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest

/** Single-threaded native User API runtime. It has no Activity or WebView dependency. */
class QuickJsRuntime {
    init { System.loadLibrary("coral_quickjs") }

    external fun nativeLoad(script: String): String
    external fun nativeResolve(payload: String): String
}

object QuickJsNativeBridge {
    @JvmStatic
    fun md5(value: String, ignored: String): String = MessageDigest.getInstance("MD5")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }

    @JvmStatic
    fun request(rawUrl: String, rawOptions: String): String {
        try {
            val options = JSONObject(rawOptions)
            val method = options.optString("method", "get").uppercase()
            require(method == "GET" || method == "POST") { "只允许 GET 或 POST 请求" }
            require(!options.has("formData")) { "当前受限运行时不支持 multipart 表单" }
            var url = URL(rawUrl)
            var redirects = 0
            while (true) {
                requirePublic(url)
                val connection = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = method
                    connectTimeout = options.optInt("timeout", 15_000).coerceIn(1_000, 20_000)
                    readTimeout = connectTimeout
                    instanceFollowRedirects = false
                    options.optJSONObject("headers")?.keys()?.forEach { key ->
                        if (key.lowercase() !in setOf("host", "connection", "content-length")) setRequestProperty(key, options.optJSONObject("headers")?.optString(key))
                    }
                    val body = body(options)
                    if (body.isNotEmpty()) {
                        require(method == "POST" && body.toByteArray().size <= 64 * 1024) { "请求体超过大小限制" }
                        doOutput = true
                        outputStream.use { it.write(body.toByteArray()) }
                    }
                }
                val status = connection.responseCode
                if (status in 300..399) {
                    val location = connection.getHeaderField("Location") ?: throw IllegalArgumentException("重定向缺少地址")
                    connection.disconnect()
                    require(++redirects <= 5) { "重定向次数过多" }
                    url = URL(url, location)
                    continue
                }
                val stream = if (status >= 400) connection.errorStream else connection.inputStream
                val bytes = stream?.use { readLimited(it) } ?: byteArrayOf()
                val headers = connection.headerFields.filterKeys { it != null }.mapValues { it.value.joinToString(",") }
                val response = JSONObject().apply {
                    put("statusCode", status); put("statusMessage", connection.responseMessage ?: "")
                    put("headers", JSONObject(headers)); put("body", bytes.toString(Charsets.UTF_8)); put("bytes", bytes.size)
                }
                connection.disconnect()
                return JSONObject().put("response", response).put("body", response.getString("body")).toString()
            }
        } catch (error: Exception) {
            return JSONObject().put("error", error.message?.take(1024) ?: "请求失败").toString()
        }
    }

    private fun body(options: JSONObject): String = when {
        options.has("body") -> when (val value = options.opt("body")) {
            is String -> value
            is JSONObject, is org.json.JSONArray -> value.toString()
            else -> ""
        }
        options.has("form") -> options.getJSONObject("form").keys().asSequence().joinToString("&") { key ->
            "${URLEncoder.encode(key, "UTF-8")}=${URLEncoder.encode(options.getJSONObject("form").optString(key), "UTF-8")}" }
        else -> ""
    }

    private fun readLimited(input: java.io.InputStream): ByteArray {
        val output = ByteArrayOutputStream(); val buffer = ByteArray(8192)
        while (true) { val count = input.read(buffer); if (count < 0) return output.toByteArray(); require(output.size() + count <= 1024 * 1024) { "响应超过大小限制" }; output.write(buffer, 0, count) }
    }

    private fun requirePublic(url: URL) {
        val uri = Uri.parse(url.toString())
        require(uri.scheme in setOf("http", "https") && !uri.host.isNullOrBlank()) { "仅允许公开 HTTP/HTTPS 请求" }
        require(InetAddress.getAllByName(uri.host).none { it.isAnyLocalAddress || it.isLoopbackAddress || it.isLinkLocalAddress || it.isSiteLocalAddress || it.isMulticastAddress }) { "禁止请求私网地址" }
    }
}

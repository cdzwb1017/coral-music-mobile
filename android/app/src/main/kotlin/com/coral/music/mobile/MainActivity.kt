package com.coral.music.mobile

import android.content.ComponentName
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.Manifest
import android.app.DownloadManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.provider.Settings
import java.io.File
import com.ryanheise.audioservice.AudioService
import com.ryanheise.audioservice.MediaButtonReceiver
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel

class MainActivity: AudioServiceActivity() {
    companion object {
        private const val MAX_SHARED_AUDIO_BYTES = 2L * 1024 * 1024 * 1024
        private const val DIRECTORY_READ_PERMISSION_REQUEST = 4001
        private const val NOTIFICATION_PERMISSION_REQUEST = 4002
    }

    private lateinit var userApiRunner: HeadlessUserApiRunner
    private var sharedAudioChannel: MethodChannel? = null
    private var directoryReadResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // AudioServiceActivity connects its engine during Activity creation; the
        // service must therefore be available before Flutter plugin attachment.
        packageManager.setComponentEnabledSetting(
            ComponentName(this, AudioService::class.java),
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP,
        )
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION_REQUEST)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        userApiRunner = UserApiRuntime.runner
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "coral_music/user_api")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "load" -> userApiRunner.load(call.argument<String>("script") ?: "", result)
                    "clear" -> userApiRunner.clear(result)
                    "resolveMusicUrl" -> userApiRunner.resolveMusicUrl(call.arguments as? Map<*, *>, result)
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "coral_music/native_playback")
            .setMethodCallHandler { call, result -> NativePlaybackService.command(this, call.method, call.arguments as? Map<*, *>, result) }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "coral_music/native_playback_events")
            .setStreamHandler(NativePlaybackEvents)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "coral_music/background_media")
            .setMethodCallHandler { call, result ->
                if (call.method != "setBackgroundMediaEnabled") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val enabled = call.argument<Boolean>("enabled") ?: false
                packageManager.setComponentEnabledSetting(
                    ComponentName(this, MediaButtonReceiver::class.java),
                    if (enabled) PackageManager.COMPONENT_ENABLED_STATE_ENABLED else PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                    PackageManager.DONT_KILL_APP,
                )
                result.success(null)
            }
        val sharedChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "coral_music/shared_audio")
        sharedAudioChannel = sharedChannel
        sharedChannel
            .setMethodCallHandler { call, result ->
                if (call.method != "consume") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                result.success(consumeSharedAudio())
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "coral_music/local_audio")
            .setMethodCallHandler { call, result ->
                if (call.method != "ensureDirectoryReadAccess") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                ensureDirectoryReadAccess(result)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "coral_music/app_task")
            .setMethodCallHandler { call, result ->
                if (call.method != "moveTaskToBack") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                result.success(moveTaskToBack(true))
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "coral_music/downloads")
            .setMethodCallHandler { call, result ->
                if (call.method != "openDirectory") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                openDownloadDirectory(call.argument<String>("path"), result)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "coral_music/app_update")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "info" -> result.success(mapOf(
                        "version" to (packageManager
                            .getPackageInfo(packageName, 0)
                            .versionName ?: ""),
                        "abi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: ""),
                    ))
                    "downloadAndInstall" -> result.success(AppUpdateInstaller.enqueue(
                        this,
                        call.argument<String>("url"),
                        call.argument<String>("name"),
                    ))
                    else -> result.notImplemented()
                }
            }
    }

    override fun onResume() {
        super.onResume()
        AppUpdateInstaller.installPending(this)
    }

    private fun openDownloadDirectory(path: String?, result: MethodChannel.Result) {
        val directory = path?.let(::File)?.canonicalFile
        val external = Environment.getExternalStorageDirectory().canonicalFile
        if (directory == null || !directory.isDirectory ||
            (directory != external && !directory.path.startsWith("${external.path}${File.separator}")) ||
            Build.VERSION.SDK_INT < Build.VERSION_CODES.O
        ) {
            result.success(false)
            return
        }
        val relativePath = directory.relativeTo(external).path.replace(File.separatorChar, '/')
        val documentId = if (relativePath.isEmpty()) "primary:" else "primary:$relativePath"
        val initialUri = DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            documentId,
        )
        try {
            startActivity(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, initialUri)
            })
            result.success(true)
        } catch (_: Exception) {
            result.success(false)
        }
    }

    private fun ensureDirectoryReadAccess(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(true)
            return
        }
        val permission = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
        if (checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED) {
            result.success(true)
            return
        }
        if (directoryReadResult != null) {
            result.error("permission_request_active", "正在等待媒体访问授权", null)
            return
        }
        directoryReadResult = result
        requestPermissions(arrayOf(permission), DIRECTORY_READ_PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode == DIRECTORY_READ_PERMISSION_REQUEST) {
            directoryReadResult?.success(
                grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED,
            )
            directoryReadResult = null
            return
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        sharedAudioChannel?.invokeMethod("shared", consumeSharedAudio())
    }

    private fun consumeSharedAudio(): List<String> {
        val current = intent ?: return emptyList()
        if (current.action != Intent.ACTION_SEND && current.action != Intent.ACTION_SEND_MULTIPLE) {
            return emptyList()
        }
        val uris = when (current.action) {
            Intent.ACTION_SEND -> listOfNotNull(current.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            else -> current.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
        }
        val directory = File(filesDir, "shared-audio").apply { mkdirs() }
        val paths = uris.mapNotNull { uri -> copySharedAudio(uri, directory) }
        current.removeExtra(Intent.EXTRA_STREAM)
        return paths
    }

    private fun copySharedAudio(uri: Uri, directory: File): String? {
        var target: File? = null
        return try {
            val name = displayName(uri).replace(Regex("[^a-zA-Z0-9._ -]"), "_")
            val outputFile = File(directory, "${System.currentTimeMillis()}-$name")
            target = outputFile
            val input = contentResolver.openInputStream(uri) ?: return null
            input.use { stream ->
                outputFile.outputStream().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var copied = 0L
                    while (true) {
                        val count = stream.read(buffer)
                        if (count < 0) break
                        copied += count
                        if (copied > MAX_SHARED_AUDIO_BYTES) throw IllegalArgumentException("Shared file is too large")
                        output.write(buffer, 0, count)
                    }
                }
            }
            outputFile.absolutePath
        } catch (_: Exception) {
            target?.delete()
            null
        }
    }

    private fun displayName(uri: Uri): String {
        val cursor: Cursor? = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
        cursor?.use {
            if (it.moveToFirst()) return it.getString(0) ?: "shared-audio"
        }
        return uri.lastPathSegment ?: "shared-audio"
    }

}

class AppUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == DownloadManager.ACTION_DOWNLOAD_COMPLETE) {
            AppUpdateInstaller.installPending(
                context,
                intent.getLongExtra(DownloadManager.EXTRA_DOWNLOAD_ID, -1),
            )
        }
    }
}

private object AppUpdateInstaller {
    private const val PREFS = "coral_app_update"
    private const val DOWNLOAD_ID = "download_id"

    fun enqueue(context: Context, rawUrl: String?, rawName: String?): Boolean {
        val url = rawUrl?.let(Uri::parse) ?: return false
        val name = rawName?.takeIf {
            it.endsWith(".apk", ignoreCase = true) &&
                it.matches(Regex("[a-zA-Z0-9._-]+"))
        } ?: return false
        if (url.scheme != "https" || url.host != "github.com" ||
            url.path?.startsWith("/vien-meng/coral-music-mobile/releases/download/") != true
        ) return false
        return try {
            context.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?.resolve(name)
                ?.delete()
            val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
            val id = manager.enqueue(
                DownloadManager.Request(url)
                    .setTitle("珊瑚音乐更新")
                    .setDescription(name)
                    .setMimeType("application/vnd.android.package-archive")
                    .setNotificationVisibility(
                        DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
                    )
                    .setDestinationInExternalFilesDir(
                        context,
                        Environment.DIRECTORY_DOWNLOADS,
                        name,
                    ),
            )
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putLong(DOWNLOAD_ID, id)
                .apply()
            requestInstallPermission(context)
            true
        } catch (_: Exception) {
            false
        }
    }

    fun installPending(context: Context, completedId: Long? = null) {
        val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val id = preferences.getLong(DOWNLOAD_ID, -1)
        if (id < 0 || (completedId != null && completedId != id)) return
        val manager = context.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
        val uri = manager.getUriForDownloadedFile(id) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !context.packageManager.canRequestPackageInstalls()
        ) {
            requestInstallPermission(context)
            return
        }
        try {
            context.startActivity(
                Intent(Intent.ACTION_INSTALL_PACKAGE, uri).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                },
            )
            preferences.edit().remove(DOWNLOAD_ID).apply()
        } catch (_: Exception) {
            // The system installer is unavailable; keep the completed download.
        }
    }

    private fun requestInstallPermission(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            context.packageManager.canRequestPackageInstalls()
        ) return
        try {
            context.startActivity(
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}"),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        } catch (_: Exception) {
            // Some managed devices do not expose the unknown-source settings UI.
        }
    }
}

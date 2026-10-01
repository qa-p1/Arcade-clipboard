package dev.arcade.clipboard.mobile

import android.content.Context
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Installs the native side of the Dart `arcade_clipboard/mobile` method channel. */
object MobileChannel {
    private const val CHANNEL = "arcade_clipboard/mobile"
    private val io = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "mobile-shared-store").apply { isDaemon = true }
    }
    private val main = Handler(Looper.getMainLooper())

    @JvmStatic
    fun install(messenger: BinaryMessenger, context: Context) {
        CoreIdentityStore.install(context)
        val appContext = context.applicationContext
        val store = MobileSharedStore(appContext)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "openKeyboardSettings") {
                appContext.startActivity(Intent(Settings.ACTION_INPUT_METHOD_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                result.success(null)
                return@setMethodCallHandler
            }
            if (call.method == "writeClipboard") {
                try {
                    val formats = call.argument<List<Map<String, Any?>>>("formats").orEmpty()
                    val image = formats.firstOrNull { it["mimeType"] == "image/png" || it["mimeType"] == "image/jpeg" }
                    val clip = if (image != null) {
                        val bytes = image["bytes"] as? ByteArray ?: error("The image has no data.")
                        require(bytes.size <= 16 * 1024 * 1024) { "The image exceeds 16 MB." }
                        val uri = SharedContentProvider.save(appContext, bytes, image["mimeType"] as String)
                        ClipData.newUri(appContext.contentResolver, "Mesh image", uri)
                    } else {
                        val text = formats.firstOrNull { it["mimeType"] == "text/plain" || it["mimeType"] == "text/uri-list" }
                        val bytes = text?.get("bytes") as? ByteArray ?: error("This item cannot be copied on Android.")
                        ClipData.newPlainText("Mesh clipboard", bytes.toString(Charsets.UTF_8))
                    }
                    appContext.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
                    result.success(null)
                } catch (error: Exception) {
                    result.error("clipboard_write", error.message, null)
                }
                return@setMethodCallHandler
            }
            if (call.method == "exportFile") {
                io.execute {
                    try {
                        val bytes = call.argument<ByteArray>("bytes") ?: error("Missing file data.")
                        require(bytes.size <= 16 * 1024 * 1024) { "The file exceeds 16 MB." }
                        val name = call.argument<String>("name") ?: "clip"
                        val uri = SharedContentProvider.save(appContext, bytes, "application/octet-stream", name)
                        main.post {
                            val share = Intent(Intent.ACTION_SEND).apply {
                                type = appContext.contentResolver.getType(uri)
                                putExtra(Intent.EXTRA_STREAM, uri)
                                clipData = ClipData.newUri(appContext.contentResolver, "Shared clip", uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            appContext.startActivity(Intent.createChooser(share, "Share clip").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            result.success(null)
                        }
                    } catch (error: Exception) {
                        main.post { result.error("file_share", error.message, null) }
                    }
                }
                return@setMethodCallHandler
            }
            io.execute {
                try {
                    val value = handle(call, store)
                    main.post { result.success(value) }
                } catch (error: Throwable) {
                    main.post {
                        result.error(
                            "mobile_shared_store",
                            error.message ?: "Could not access shared mobile clipboard data.",
                            null,
                        )
                    }
                }
            }
        }
    }

    private fun handle(call: MethodCall, store: MobileSharedStore): Any? = when (call.method) {
        "drainSharedInbox" -> store.drainInbox()
        "ackSharedInbox" -> {
            val ids = call.argument<List<String>>("ids")
                ?: throw IllegalArgumentException("Missing shared item IDs.")
            store.acknowledge(ids)
            null
        }
        "publishKeyboardHistory" -> {
            val arguments = call.arguments as? Map<*, *>
                ?: throw IllegalArgumentException("Missing keyboard history.")
            val rawItems = arguments["items"] as? List<*> ?: emptyList<Any?>()
            val items = rawItems.mapNotNull { item ->
                (item as? Map<*, *>)?.entries?.associate { (key, value) -> key.toString() to value }
            }
            store.publishKeyboardHistory(items, arguments["paused"] as? Boolean ?: false)
            null
        }
        else -> throw UnsupportedOperationException("Unsupported mobile method: ${call.method}")
    }
}

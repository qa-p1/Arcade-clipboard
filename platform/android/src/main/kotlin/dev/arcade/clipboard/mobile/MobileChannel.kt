package dev.arcade.clipboard.mobile

import android.content.Context
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
        val store = MobileSharedStore(context.applicationContext)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
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

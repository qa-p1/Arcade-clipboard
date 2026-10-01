package dev.arcade.clipboard.mobile

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.os.Bundle
import java.io.ByteArrayOutputStream
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import java.lang.ref.WeakReference
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors

/** Android Sharesheet target for plain text and URLs. A share is only queued after explicit review. */
class ShareTargetActivity : Activity() {
    private var session: ShareSession? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val retained = lastNonConfigurationInstance as? ShareSession
        val active = retained ?: restoreOrReadShare(savedInstanceState)
        session = active
        active.attach(this)
        render(active)
        active.scheduleOpenAfterQueue()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        session?.let { active ->
            outState.putString(STATE_STATUS, active.status.name)
            outState.putString(STATE_MESSAGE, active.message)
        }
        super.onSaveInstanceState(outState)
    }

    /** Keep an in-flight operation and its confirmation state through a configuration change. */
    override fun onRetainNonConfigurationInstance(): Any? = session

    override fun onBackPressed() {
        val active = session ?: return super.onBackPressed()
        if (active.status == Status.SUBMITTING) return
        cancelAndClose(active)
    }

    override fun onDestroy() {
        session?.detach(this)
        super.onDestroy()
    }

    private fun restoreOrReadShare(savedInstanceState: Bundle?): ShareSession {
        when (savedInstanceState?.getString(STATE_STATUS)?.let { runCatching { Status.valueOf(it) }.getOrNull() }) {
            Status.SUBMITTING, Status.UNCERTAIN -> {
                // The process may have stopped after the atomic write. Never enqueue again on restore.
                return ShareSession(
                    text = null,
                    status = Status.UNCERTAIN,
                    message = "The app stopped while saving. The share may or may not be queued. Open Arcade Clipboard to check before sharing it again.",
                )
            }
            Status.QUEUED -> return ShareSession(text = null, status = Status.QUEUED)
            Status.APP_NOT_OPENED -> return ShareSession(
                text = null,
                status = Status.APP_NOT_OPENED,
                message = savedInstanceState.getString(STATE_MESSAGE),
            )
            Status.INVALID -> return ShareSession(
                text = null,
                status = Status.INVALID,
                message = savedInstanceState.getString(STATE_MESSAGE),
            )
            else -> Unit
        }

        return when (val result = readSharedText(intent)) {
            is ShareInput.Valid -> ShareSession(text = result.text, sources = result.sources, status = Status.PREVIEW)
            is ShareInput.Invalid -> ShareSession(text = null, status = Status.INVALID, message = result.message)
        }
    }

    private fun readSharedText(source: Intent): ShareInput {
        if (source.action !in setOf(Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE)) {
            return ShareInput.Invalid("This share doesn’t contain supported text.")
        }

        @Suppress("DEPRECATION")
        val streams: List<Uri> = if (source.action == Intent.ACTION_SEND_MULTIPLE) {
            source.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM).orEmpty()
        } else listOfNotNull(source.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
        if (streams.isNotEmpty()) {
            if (streams.size > 32 || streams.any { it.scheme != "content" }) {
                return ShareInput.Invalid("Share up to 32 files from an app on this device.")
            }
            return ShareInput.Valid(streams.joinToString("\n") { displayName(it) }, streams)
        }

        val value = try {
            source.getCharSequenceExtra(Intent.EXTRA_TEXT)
                ?: source.getCharSequenceExtra(Intent.EXTRA_HTML_TEXT)
        } catch (_: RuntimeException) {
            null
        } ?: return ShareInput.Invalid("This share doesn’t contain supported text.")

        // Reject on character count first, then validate the exact UTF-8 byte size before building UI.
        if (value.length > MAX_SHARED_BYTES) {
            return ShareInput.Invalid("This text is too large to share. The limit is 32 KB.")
        }
        val text = value.toString()
        if (text.isBlank()) return ShareInput.Invalid("There is no text to add.")
        if (text.toByteArray(StandardCharsets.UTF_8).size > MAX_SHARED_BYTES) {
            return ShareInput.Invalid("This text is too large to share. The limit is 32 KB.")
        }
        return ShareInput.Valid(text)
    }

    private fun render(active: ShareSession) {
        when (active.status) {
            Status.PREVIEW -> showPreview(active)
            Status.SUBMITTING -> showStatus(
                title = "Adding to your mesh…",
                detail = "Saving this share on this phone. It will stay queued until Arcade Clipboard can sync it.",
                showProgress = true,
            )
            Status.QUEUED -> showStatus(
                title = "Queued on this phone",
                detail = "Sync is not confirmed yet. Opening Arcade Clipboard to finish syncing this share.",
                showProgress = true,
            )
            Status.UNCERTAIN -> showActionStatus(
                title = "Couldn’t confirm the save",
                detail = active.message ?: "The share may or may not be queued. Open Arcade Clipboard to check before sharing it again.",
                primary = "Open Arcade Clipboard",
                onPrimary = { openMainApp(active) },
            )
            Status.APP_NOT_OPENED -> showActionStatus(
                title = "Share queued locally",
                detail = active.message ?: "Sync is not confirmed. Open Arcade Clipboard to finish syncing this share.",
                primary = "Open Arcade Clipboard",
                onPrimary = { openMainApp(active) },
            )
            Status.INVALID -> showActionStatus(
                title = "Can’t add this share",
                detail = active.message ?: "This share was not queued.",
                primary = "Done",
                onPrimary = { cancelAndClose(active) },
            )
        }
    }

    private fun showPreview(active: ShareSession) {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(24), dp(24), dp(16))
        }
        root.addView(TextView(this).apply {
            text = "Review before adding"
            textSize = 21f
            setTextColor(0xff202124.toInt())
        }, matchWidth())
        root.addView(TextView(this).apply {
            text = "Add this content to your shared clipboard."
            textSize = 15f
            setTextColor(0xff5f6368.toInt())
            setPadding(0, dp(10), 0, dp(14))
        }, matchWidth())

        val preview = TextView(this).apply {
            text = active.text.orEmpty() // Keep the original whitespace; do not trim the queued text.
            textSize = 16f
            setTextColor(0xff202124.toInt())
            setTextIsSelectable(true)
            setPadding(dp(12), dp(10), dp(12), dp(10))
            setBackgroundColor(0xfff1f3f4.toInt())
        }
        root.addView(ScrollView(this).apply {
            isFillViewport = false
            addView(preview, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.END or Gravity.CENTER_VERTICAL
            setPadding(0, dp(16), 0, 0)
        }
        actions.addView(Button(this).apply {
            text = "Cancel"
            setOnClickListener { cancelAndClose(active) }
        })
        actions.addView(Button(this).apply {
            text = "Add to mesh"
            setOnClickListener { confirmAndQueue(active) }
        }, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            marginStart = dp(12)
        })
        root.addView(actions, matchWidth())
        setContentView(root, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT))
    }

    private fun confirmAndQueue(active: ShareSession) {
        if (!active.beginSubmission()) return

        // Clear the delivered payload before starting work so a restored task cannot retry it.
        setIntent(Intent())
        render(active)
        SHARE_WORKER.execute {
            val outcome = runCatching {
                if (active.sources.isEmpty()) MobileSharedStore(applicationContext).enqueue(active.text.orEmpty(), "This phone")
                else {
                    var total = 0
                    val representations = active.sources.map { uri ->
                        val bytes = contentResolver.openInputStream(uri)?.use { input ->
                            val output = ByteArrayOutputStream()
                            val buffer = ByteArray(64 * 1024)
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                total += count
                                require(total <= 16 * 1024 * 1024) { "This share exceeds 16 MB." }
                                output.write(buffer, 0, count)
                            }
                            output.toByteArray()
                        } ?: error("The shared file is no longer available.")
                        val mime = contentResolver.getType(uri) ?: "application/octet-stream"
                        mapOf<String, Any?>(
                            "mime_type" to mime,
                            "data_base64" to android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP),
                            "name" to displayName(uri),
                        )
                    }
                    MobileSharedStore(applicationContext).enqueue("", "This phone", representations)
                }
            }
            MAIN.post {
                active.completeSubmission(outcome)
                active.currentActivity()?.let { attached ->
                    attached.render(active)
                    active.scheduleOpenAfterQueue()
                }
            }
        }
    }

    private fun openMainApp(active: ShareSession) {
        if (!active.claimAppLaunch()) return
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        if (launch == null) {
            active.appLaunchFailed("The share is queued locally, but Arcade Clipboard could not be opened. Sync is not confirmed; open the app manually.")
            render(active)
            return
        }
        launch.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        launch.putExtra(EXTRA_SHARED_ITEM_PENDING, true)
        try {
            startActivity(launch)
            finish()
        } catch (_: RuntimeException) {
            active.appLaunchFailed("The share is queued locally, but Arcade Clipboard could not be opened. Sync is not confirmed; open the app manually.")
            render(active)
        }
    }

    private fun cancelAndClose(active: ShareSession) {
        active.cancelOpen()
        setIntent(Intent())
        finish()
    }

    private fun showStatus(title: String, detail: String, showProgress: Boolean) {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(24), dp(16), dp(24), dp(16))
        }
        if (showProgress) {
            root.addView(ProgressBar(this).apply { isIndeterminate = true },
                LinearLayout.LayoutParams(dp(22), dp(22)).apply { marginEnd = dp(14) })
        }
        val copy = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        copy.addView(TextView(this).apply {
            text = title
            textSize = 18f
            setTextColor(0xff202124.toInt())
        })
        copy.addView(TextView(this).apply {
            text = detail
            textSize = 14f
            setTextColor(0xff5f6368.toInt())
            setPadding(0, dp(8), 0, 0)
        })
        root.addView(copy, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        setContentView(root, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }

    private fun showActionStatus(
        title: String,
        detail: String,
        primary: String,
        onPrimary: () -> Unit,
    ) {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(dp(24), dp(24), dp(24), dp(16))
        }
        root.addView(TextView(this).apply {
            text = title
            textSize = 20f
            setTextColor(0xff202124.toInt())
        }, matchWidth())
        root.addView(TextView(this).apply {
            text = detail
            textSize = 15f
            setTextColor(0xff5f6368.toInt())
            setPadding(0, dp(10), 0, dp(14))
        }, matchWidth())
        root.addView(Button(this).apply {
            text = primary
            setOnClickListener { onPrimary() }
        }, matchWidth())
        if (primary != "Done") {
            root.addView(Button(this).apply {
                text = "Done"
                setOnClickListener {
                    session?.let { active -> cancelAndClose(active) }
                }
            }, matchWidth())
        }
        setContentView(root, ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT))
    }

    private fun matchWidth() = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
    )

    private fun displayName(uri: Uri): String {
        val name = runCatching {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            }
        }.getOrNull() ?: "shared-file"
        return name.replace('/', '_').replace('\\', '_').replace('\u0000', '_').take(100).ifBlank { "shared-file" }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private sealed class ShareInput {
        data class Valid(val text: String, val sources: List<Uri> = emptyList()) : ShareInput()
        data class Invalid(val message: String) : ShareInput()
    }

    private enum class Status { PREVIEW, SUBMITTING, QUEUED, UNCERTAIN, APP_NOT_OPENED, INVALID }

    /** Retained across rotation. A restored process never repeats a confirmed submission. */
    private class ShareSession(
        val text: String?,
        val sources: List<Uri> = emptyList(),
        status: Status,
        message: String? = null,
    ) {
        @Volatile var status: Status = status
            private set
        @Volatile var message: String? = message
            private set
        private var activity = WeakReference<ShareTargetActivity>(null)
        private var autoOpen: Runnable? = null
        private var appLaunchClaimed = false

        @Synchronized fun attach(owner: ShareTargetActivity) {
            activity = WeakReference(owner)
        }

        @Synchronized fun detach(owner: ShareTargetActivity) {
            if (activity.get() === owner) activity.clear()
        }

        @Synchronized fun currentActivity(): ShareTargetActivity? = activity.get()

        @Synchronized fun beginSubmission(): Boolean {
            if (status != Status.PREVIEW) return false
            status = Status.SUBMITTING
            return true
        }

        @Synchronized fun completeSubmission(outcome: Result<MobileSharedStore.SharedText>) {
            if (status != Status.SUBMITTING) return
            if (outcome.isSuccess) {
                status = Status.QUEUED
                message = null
            } else {
                // A failure may happen while releasing the storage lock after the atomic rename.
                // Keep the result ambiguous and require a check in the app before sharing again.
                status = Status.UNCERTAIN
                val reason = (outcome.exceptionOrNull()?.message ?: "Could not confirm the local save.")
                    .take(MAX_ERROR_CHARS)
                message = "Could not confirm the local save. The share may or may not be queued. Open Arcade Clipboard to check before sharing again. $reason"
            }
        }

        @Synchronized fun appLaunchFailed(reason: String) {
            status = Status.APP_NOT_OPENED
            message = reason
            appLaunchClaimed = false
            autoOpen?.let { MAIN.removeCallbacks(it) }
            autoOpen = null
        }

        @Synchronized fun claimAppLaunch(): Boolean {
            if (appLaunchClaimed || status !in setOf(Status.QUEUED, Status.UNCERTAIN, Status.APP_NOT_OPENED)) return false
            appLaunchClaimed = true
            autoOpen?.let { MAIN.removeCallbacks(it) }
            autoOpen = null
            return true
        }

        @Synchronized fun cancelOpen() {
            autoOpen?.let { MAIN.removeCallbacks(it) }
            autoOpen = null
        }

        @Synchronized fun scheduleOpenAfterQueue() {
            if (status != Status.QUEUED || appLaunchClaimed || autoOpen != null) return
            val scheduled = Runnable {
                synchronized(this) { autoOpen = null }
                currentActivity()?.openMainApp(this)
            }
            autoOpen = scheduled
            MAIN.postDelayed(scheduled, QUEUED_STATUS_DELAY_MS)
        }

        companion object {
            private const val MAX_ERROR_CHARS = 300
        }
    }

    companion object {
        const val EXTRA_SHARED_ITEM_PENDING = "arcade_clipboard.mobile.sharedPending"
        private const val STATE_STATUS = "share_status"
        private const val STATE_MESSAGE = "share_message"
        // Keep in sync with MobileSharedStore.MAX_SHARED_BYTES.
        private const val MAX_SHARED_BYTES = 32 * 1024
        private const val QUEUED_STATUS_DELAY_MS = 700L
        private val MAIN = Handler(Looper.getMainLooper())
        private val SHARE_WORKER = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "mobile-share-target").apply { isDaemon = true }
        }
    }
}

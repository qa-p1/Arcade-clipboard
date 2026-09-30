package dev.arcade.clipboard.mobile

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.RandomAccessFile
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Small, encrypted handoff store shared by the Flutter app and its Share Target / IME.
 * The Rust database remains the source of truth. These files only bridge processes.
 */
internal class MobileSharedStore(context: Context) {
    private val directory = File(context.noBackupFilesDir, "mobile-shared-v1").apply {
        check(isDirectory || mkdirs()) { "Could not safely create mobile clipboard storage." }
    }
    private val inbox = File(directory, "inbox").apply {
        check(isDirectory || mkdirs()) { "Could not safely create the pending share queue." }
    }
    private val inboxLock = File(directory, "inbox.lock")
    private val keyLock = File(directory, "keystore.lock")
    private val keyboardCache = File(directory, "keyboard-cache.enc")

    data class SharedText(
        val id: String,
        val text: String,
        val kind: String,
        val sourceName: String,
        val createdAt: Long,
        val expiresAt: Long,
    )

    fun enqueue(textValue: String, sourceName: String): SharedText = withInboxLock {
        val text = textValue
        require(text.isNotBlank()) { "There is no text to add." }
        val textBytes = text.toByteArray(StandardCharsets.UTF_8).size
        require(textBytes <= MAX_SHARED_BYTES) {
            "This text is too large to share. The limit is 32 KB."
        }
        pruneExpiredInbox()
        val files = inboxFiles()
        require(files.size < MAX_INBOX_ITEMS) {
            "There are too many shares waiting to sync. Open Arcade Clipboard to finish syncing them."
        }
        val queuedBytes = files.sumOf(File::length)
        val item = SharedText(
            id = UUID.randomUUID().toString(),
            text = text,
            kind = if (isHttpUrl(text.trim())) "url" else "text",
            sourceName = sourceName.take(MAX_SOURCE_NAME_CHARS),
            createdAt = System.currentTimeMillis(),
            expiresAt = System.currentTimeMillis() + MAX_INBOX_AGE_MS,
        )
        val payload = JSONObject()
            .put("id", item.id)
            .put("text", item.text)
            .put("kind", item.kind)
            .put("sourceName", item.sourceName)
            .put("createdAt", item.createdAt)
            .put("expiresAt", item.expiresAt)
            .toString()
            .toByteArray(StandardCharsets.UTF_8)
        val encryptedBytes = payload.size.toLong() + ENVELOPE_OVERHEAD_BYTES
        require(queuedBytes + encryptedBytes <= MAX_INBOX_BYTES) {
            "There are too many shares waiting to sync. Open Arcade Clipboard to finish syncing them."
        }
        writeEncryptedAtomic(File(inbox, "${item.id}.enc"), payload, "inbox:${item.id}")
        item
    }

    fun drainInbox(): List<Map<String, Any>> = withInboxLock {
        pruneExpiredInbox()
        inboxFiles()
            .orEmpty()
            .asSequence()
            .mapNotNull { file ->
                val id = file.name.removeSuffix(".enc")
                if (!isUuid(id)) return@mapNotNull null
                runCatching {
                    val payload = JSONObject(String(readEncrypted(file, "inbox:$id"), StandardCharsets.UTF_8))
                    val text = payload.optString("text").takeIf { it.isNotBlank() } ?: return@runCatching null
                    payload.optLong("createdAt") to mapOf(
                        "id" to id,
                        "text" to text,
                        "kind" to payload.optString("kind", if (isHttpUrl(text.trim())) "url" else "text"),
                        "sourceName" to payload.optString("sourceName", "This phone"),
                    ) as Map<String, Any>
                }.getOrNull()
            }
            .sortedBy { it.first }
            .take(MAX_DRAIN_ITEMS)
            .map { it.second }
            .toList()
    }

    fun acknowledge(ids: List<String>) = withInboxLock {
        ids.filter(::isUuid).forEach { id ->
            // UUID validation prevents a caller from using an ack as a path traversal.
            File(inbox, "$id.enc").delete()
        }
    }

    fun publishKeyboardHistory(items: List<Map<String, Any?>>, paused: Boolean) {
        val boundedItems = JSONArray()
        var size = 0
        val now = System.currentTimeMillis()
        val cacheExpiry = now + MAX_CACHE_AGE_MS
        if (!paused) {
            // Keep keyboard handoff small and recent. Full history remains in the Rust store.
            var published = 0
            for (source in items) {
                if (published >= MAX_CACHE_ITEMS) break
                val text = (source["text"] as? String)?.takeIf(String::isNotEmpty) ?: continue
                val bytes = text.toByteArray(StandardCharsets.UTF_8).size
                if (bytes > MAX_CACHE_ITEM_BYTES || size + bytes > MAX_CACHE_BYTES) continue
                val id = (source["id"] as? String)?.takeIf(::isUuid) ?: continue
                val createdAt = (source["created_at"] as? Number)?.toLong() ?: continue
                val fallbackExpiry = createdAt.saturatingPlus(MAX_MISSING_EXPIRY_AGE_MS)
                val requestedExpiry = (source["expires_at"] as? Number)?.toLong() ?: fallbackExpiry
                val expiresAt = minOf(requestedExpiry, cacheExpiry)
                if (createdAt <= 0L || expiresAt <= now) continue
                size += bytes
                published += 1
                boundedItems.put(
                    JSONObject()
                        .put("id", id)
                        .put("source_name", (source["source_name"] as? String).orEmpty().take(80))
                        .put("created_at", createdAt)
                        .put("expires_at", expiresAt)
                        .put("text", text)
                        .put("pinned", source["pinned"] as? Boolean ?: false),
                )
            }
        }
        val payload = JSONObject()
            .put("version", 1)
            .put("written_at", now)
            .put("paused", paused)
            .put("items", boundedItems)
            .toString()
            .toByteArray(StandardCharsets.UTF_8)
        writeEncryptedAtomic(keyboardCache, payload, "keyboard-cache")
    }

    fun readKeyboardHistory(): KeyboardHistory {
        if (!keyboardCache.exists()) return KeyboardHistory(paused = false, items = emptyList())
        return runCatching {
            val root = JSONObject(String(readEncrypted(keyboardCache, "keyboard-cache"), StandardCharsets.UTF_8))
            val writtenAt = root.optLong("written_at")
            val now = System.currentTimeMillis()
            if (writtenAt <= 0L || now < writtenAt || now - writtenAt > MAX_CACHE_AGE_MS) {
                keyboardCache.delete()
                return KeyboardHistory(paused = root.optBoolean("paused", false), items = emptyList(), needsRefresh = true)
            }
            val snapshotExpiry = writtenAt.saturatingPlus(MAX_CACHE_AGE_MS)
            val items = root.optJSONArray("items") ?: JSONArray()
            KeyboardHistory(
                paused = root.optBoolean("paused", false),
                items = (0 until items.length()).mapNotNull { index ->
                    runCatching {
                        val item = items.getJSONObject(index)
                        val id = item.getString("id")
                        val createdAt = item.optLong("created_at")
                        val text = item.getString("text")
                        val expiresAt = minOf(
                            item.optLong("expires_at", createdAt.saturatingPlus(MAX_MISSING_EXPIRY_AGE_MS)),
                            snapshotExpiry,
                        )
                        if (!isUuid(id) || createdAt <= 0L || text.isEmpty() ||
                            text.toByteArray(StandardCharsets.UTF_8).size > MAX_CACHE_ITEM_BYTES || expiresAt <= now
                        ) return@runCatching null
                        KeyboardItem(
                            id = id,
                            sourceName = item.optString("source_name"),
                            createdAt = createdAt,
                            expiresAt = expiresAt,
                            text = text,
                            pinned = item.optBoolean("pinned", false),
                        )
                    }.getOrNull()
                },
                needsRefresh = false,
            )
        }.getOrElse { KeyboardHistory(paused = false, items = emptyList(), needsRefresh = true) }
    }

    data class KeyboardHistory(val paused: Boolean, val items: List<KeyboardItem>, val needsRefresh: Boolean = false)
    data class KeyboardItem(
        val id: String,
        val sourceName: String,
        val createdAt: Long,
        val expiresAt: Long,
        val text: String,
        val pinned: Boolean,
    )

    private fun writeEncryptedAtomic(target: File, cleartext: ByteArray, aad: String) {
        val encrypted = encrypt(cleartext, aad.toByteArray(StandardCharsets.UTF_8))
        val temporary = File(directory, ".${target.name}.${UUID.randomUUID()}.tmp")
        FileOutputStream(temporary).use { stream ->
            stream.write(encrypted)
            stream.fd.sync()
        }
        if (!temporary.renameTo(target)) {
            temporary.delete()
            throw IllegalStateException("Could not safely save this item on this phone.")
        }
    }

    private fun readEncrypted(file: File, aad: String): ByteArray {
        require(file.canonicalPath.startsWith(directory.canonicalPath + File.separator))
        val limit = if (file.parentFile?.canonicalPath == inbox.canonicalPath) MAX_INBOX_FILE_BYTES else MAX_ENCRYPTED_CACHE_FILE_BYTES
        require(file.length() <= limit) { "Mobile cache entry is too large." }
        return decrypt(file.readBytes(), aad.toByteArray(StandardCharsets.UTF_8))
    }

    private fun inboxFiles(): List<File> = inbox.listFiles().orEmpty()
        .filter { it.isFile && it.name.endsWith(".enc") }

    private fun pruneExpiredInbox() {
        val expiry = System.currentTimeMillis() - MAX_INBOX_AGE_MS
        inboxFiles().forEach { file ->
            val id = file.name.removeSuffix(".enc")
            val expiryTimestamp = if (isUuid(id)) {
                runCatching {
                    val payload = JSONObject(String(readEncrypted(file, "inbox:$id"), StandardCharsets.UTF_8))
                    payload.optLong("expiresAt", payload.optLong("createdAt").saturatingPlus(MAX_INBOX_AGE_MS))
                }.getOrNull()
            } else 0L
            val timestamp = expiryTimestamp ?: file.lastModified()
            if (timestamp <= System.currentTimeMillis() || timestamp <= 0L || timestamp < expiry) file.delete()
        }
    }

    private fun encrypt(cleartext: ByteArray, aad: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(aad)
        val iv = cipher.iv
        val ciphertext = cipher.doFinal(cleartext)
        return byteArrayOf(FORMAT_VERSION.toByte()) + iv + ciphertext
    }

    private fun decrypt(envelope: ByteArray, aad: ByteArray): ByteArray {
        require(envelope.size >= 1 + GCM_IV_BYTES + GCM_TAG_BYTES)
        require(envelope[0].toInt() == FORMAT_VERSION) { "Unsupported mobile cache version." }
        val iv = envelope.copyOfRange(1, 1 + GCM_IV_BYTES)
        val ciphertext = envelope.copyOfRange(1 + GCM_IV_BYTES, envelope.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(GCM_TAG_BITS, iv))
        cipher.updateAAD(aad)
        return cipher.doFinal(ciphertext)
    }

    private fun key(): SecretKey = synchronized(PROCESS_STORE_LOCK) {
        RandomAccessFile(keyLock, "rw").use { randomAccessFile ->
            randomAccessFile.channel.lock().use {
                val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
                (store.getKey(KEY_ALIAS, null) as? SecretKey) ?: run {
                    val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
                    val spec = KeyGenParameterSpec.Builder(
                        KEY_ALIAS,
                        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                    )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setKeySize(256)
                        .setRandomizedEncryptionRequired(true)
                        .apply {
                            if (Build.VERSION.SDK_INT >= 28) setUnlockedDeviceRequired(true)
                        }
                        .build()
                    generator.init(spec)
                    generator.generateKey()
                }
            }
        }
    }

    private fun <T> withInboxLock(work: () -> T): T = synchronized(PROCESS_STORE_LOCK) {
        RandomAccessFile(inboxLock, "rw").use { randomAccessFile ->
            randomAccessFile.channel.lock().use { work() }
        }
    }

    private fun isHttpUrl(value: String): Boolean =
        runCatching {
            val uri = android.net.Uri.parse(value)
            (uri.scheme.equals("https", ignoreCase = true) || uri.scheme.equals("http", ignoreCase = true)) &&
                !uri.host.isNullOrBlank()
        }.getOrDefault(false)

    private fun isUuid(value: String): Boolean = runCatching { UUID.fromString(value) }.isSuccess

    private fun Long.saturatingPlus(amount: Long): Long =
        if (this > Long.MAX_VALUE - amount) Long.MAX_VALUE else this + amount

    companion object {
        private val PROCESS_STORE_LOCK = Any()
        private const val KEY_ALIAS = "dev.arcade.clipboard.mobile-cache.v1"
        private const val FORMAT_VERSION = 1
        private const val GCM_IV_BYTES = 12
        private const val GCM_TAG_BITS = 128
        private const val GCM_TAG_BYTES = GCM_TAG_BITS / 8
        private const val ENVELOPE_OVERHEAD_BYTES = 1L + GCM_IV_BYTES + GCM_TAG_BYTES
        private const val MAX_SHARED_BYTES = 32 * 1024
        private const val MAX_SOURCE_NAME_CHARS = 80
        private const val MAX_INBOX_ITEMS = 100
        private const val MAX_INBOX_BYTES = 4 * 1024 * 1024
        private const val MAX_INBOX_FILE_BYTES = 64 * 1024L
        private const val MAX_DRAIN_ITEMS = 50
        private const val MAX_INBOX_AGE_MS = 7L * 24 * 60 * 60 * 1000
        private const val MAX_CACHE_ITEMS = 30
        private const val MAX_CACHE_ITEM_BYTES = 32 * 1024
        private const val MAX_CACHE_BYTES = 2 * 1024 * 1024
        private const val MAX_CACHE_AGE_MS = 7L * 24 * 60 * 60 * 1000
        private const val MAX_MISSING_EXPIRY_AGE_MS = 24L * 60 * 60 * 1000
        private const val MAX_ENCRYPTED_CACHE_FILE_BYTES = MAX_CACHE_BYTES + 64 * 1024
    }
}

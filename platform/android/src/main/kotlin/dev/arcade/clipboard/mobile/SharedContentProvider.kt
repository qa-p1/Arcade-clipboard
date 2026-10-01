package dev.arcade.clipboard.mobile

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException
import java.util.UUID

/** Read-only URIs grant access only to an image explicitly copied by the user. */
class SharedContentProvider : ContentProvider() {
    override fun onCreate() = true
    override fun getType(uri: Uri): String = android.webkit.MimeTypeMap.getSingleton().getMimeTypeFromExtension(safeFile(uri).extension.lowercase()) ?: "application/octet-stream"
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw FileNotFoundException("Read-only clipboard content")
        return ParcelFileDescriptor.open(safeFile(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val file = safeFile(uri)
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(columns).apply {
            addRow(columns.map { if (it == OpenableColumns.DISPLAY_NAME) file.name else if (it == OpenableColumns.SIZE) file.length() else null })
        }
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = 0
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = 0

    private fun safeFile(uri: Uri): File {
        val name = uri.lastPathSegment ?: throw FileNotFoundException()
        if (uri.pathSegments.size != 2 || !Regex("[0-9a-f-]{36}").matches(uri.pathSegments[0]) || name in setOf(".", "..") || name.contains('/')) throw FileNotFoundException()
        val id = uri.pathSegments[0]
        return File(requireNotNull(context).cacheDir, "mesh-copied-images/$id/$name").also {
            if (!it.isFile) throw FileNotFoundException()
        }
    }

    companion object {
        fun save(context: Context, bytes: ByteArray, mime: String, filename: String? = null): Uri {
            val directory = File(context.cacheDir, "mesh-copied-images")
            check(directory.isDirectory || directory.mkdirs())
            val cutoff = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
            directory.listFiles().orEmpty().filter { it.lastModified() < cutoff }.forEach { it.deleteRecursively() }
            require(directory.walkTopDown().filter { it.isFile }.sumOf { it.length() } + bytes.size <= 64 * 1024 * 1024L) {
                "Copied image storage is full. Try again after older copies expire."
            }
            val id = UUID.randomUUID().toString()
            val name = File(filename ?: if (mime == "image/png") "clip.png" else "clip.jpg").name.replace('\\', '_').take(100).ifBlank { "clip" }
            require(name !in setOf(".", ".."))
            val child = File(directory, id).apply { check(mkdirs()) }
            File(child, name).outputStream().use { it.write(bytes) }
            return Uri.Builder().scheme("content").authority("${context.packageName}.shared-content").appendPath(id).appendPath(name).build()
        }
    }
}

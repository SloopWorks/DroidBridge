package dev.droidbridge.companion

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File

class TransferProvider : ContentProvider() {
    override fun onCreate() = true
    private fun file(uri: Uri): File {
        val id = uri.lastPathSegment ?: throw IllegalArgumentException("Missing transfer")
        require(uri.authority == "${context!!.packageName}.transfers" && uri.pathSegments.size == 1 && runCatching { java.util.UUID.fromString(id) }.isSuccess)
        return BridgeStore.get(context!!).transfers.sharedFile(id)
    }
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor { require(mode == "r"); return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY) }
    override fun getType(uri: Uri): String { file(uri); return BridgeStore.get(context!!).transfers.sharedMetadata(uri.lastPathSegment!!).getString("mime_type") }
    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val f = file(uri); val metadata = BridgeStore.get(context!!).transfers.sharedMetadata(uri.lastPathSegment!!)
        val columns = (projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).filter { it in setOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE) }.toTypedArray()
        return MatrixCursor(columns).apply { addRow(columns.map { if (it == OpenableColumns.DISPLAY_NAME) metadata.getString("display_name") else f.length() }) }
    }
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?) = throw UnsupportedOperationException()
}

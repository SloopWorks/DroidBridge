package dev.droidbridge.companion

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.io.RandomAccessFile
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/** Fixed-size transfer. Local staging and confirmed remote delivery are separate facts. */
class BridgeTransfers(private val context: Context, private val store: BridgeStore) {
    private data class Transfer(val id: String, val owner: String, var name: String, var mime: String,
        var size: Long, var sha: String, val file: File, val direction: String,
        var localBytes: Long = 0, var next: Int = 0, var committed: Boolean = false,
        var status: String = "receiving", var remoteBytes: Long = 0,
        val created: Long = System.currentTimeMillis(), val chunks: MutableMap<Int, String> = mutableMapOf(),
        val cancelled: AtomicBoolean = AtomicBoolean(false))
    private val root = File(context.filesDir, "transfers").apply { mkdirs() }
    private val records = LinkedHashMap<String, Transfer>()
    private val journal = SecureJournal(context, "transfers", 262144)
    private class StageRead(val transfer: Transfer, val deadline: Long) {
        val signal = android.os.CancellationSignal()
        val stream = java.util.concurrent.atomic.AtomicReference<InputStream?>()
        // 0=reading, 1=cancelled, 2=published. A timeout cannot revoke a completed stage.
        val state = java.util.concurrent.atomic.AtomicInteger(0)
        val timedOut = AtomicBoolean(false)
    }
    private val stagingReads = ConcurrentHashMap<String, StageRead>()
    private companion object {
        val daemonThreads = java.util.concurrent.ThreadFactory { task -> Thread(task, "DroidBridgeTransferCancellation").apply { isDaemon = true } }
        val deadlines = java.util.concurrent.ScheduledThreadPoolExecutor(1, daemonThreads).apply { removeOnCancelPolicy = true }
        val closeWork = java.util.concurrent.ThreadPoolExecutor(2, 2, 0, java.util.concurrent.TimeUnit.MILLISECONDS,
            java.util.concurrent.ArrayBlockingQueue<Runnable>(2), daemonThreads, java.util.concurrent.ThreadPoolExecutor.AbortPolicy())
    }
    private fun cancelRead(read: StageRead, timeout: Boolean = false) {
        if (!read.state.compareAndSet(0, 1)) return
        if (timeout) read.timedOut.set(true)
        read.transfer.cancelled.set(true)
        // Neither a timer nor the UI waits on provider Binder or stream-close work.
        // Admission retains this read until stage() finally exits, even if a provider ignores cancellation.
        try { closeWork.execute {
            runCatching { read.stream.get()?.close() }
            runCatching { read.signal.cancel() }
        } } catch (_: java.util.concurrent.RejectedExecutionException) {
            // Fail publication closed; do not create another thread or unbounded queue.
        }
    }
    private fun checkRead(read: StageRead) {
        check(read.state.get() == 0 && !read.transfer.cancelled.get() && !Thread.currentThread().isInterrupted &&
            android.os.SystemClock.elapsedRealtime() < read.deadline) { "File preparation cancelled or timed out" }
    }
    private var healthy = true
    init {
        runCatching {
            val encoded = journal.read() ?: return@runCatching
            val saved = JSONArray(encoded); require(saved.length() <= 32)
            for (i in 0 until saved.length()) {
                val value = saved.getJSONObject(i); val path = value.getString("file")
                require(runCatching { UUID.fromString(path) }.isSuccess)
                val file = File(root, path); val size = value.getLong("size"); val local = value.getLong("local_bytes")
                require(size in 0..ProtocolRules.MAX_FILE && local in 0..size && file.canonicalFile.parentFile == root.canonicalFile)
                val chunks = mutableMapOf<Int, String>(); val hashes = value.getJSONObject("chunks")
                require(hashes.length() <= 800)
                hashes.keys().forEach { chunks[it.toInt()] = hashes.getString(it) }
                var status = value.getString("status")
                if (status == "staging") { status = "failed"; file.delete(); file.createNewFile() }
                else if (status !in listOf("cancelled", "failed")) {
                    require(file.isFile && file.length() >= local)
                    if (file.length() != local) RandomAccessFile(file, "rw").use { it.setLength(local) }
                }
                records[value.getString("transfer_id")] = Transfer(value.getString("transfer_id"), value.getString("owner"), value.getString("display_name"), value.getString("mime_type"), size, value.getString("sha256"), file, value.getString("direction"), if (status == "failed") 0 else local, value.getInt("next_index"), value.getBoolean("committed"), status, value.optLong("remote_bytes", 0), value.getLong("created"), chunks)
            }
            require(records.values.sumOf { it.localBytes } <= 100L * 1024 * 1024)
        }.onFailure { healthy = false; records.clear() }
        if (healthy) { expire(); val owned = records.values.map { it.file.name }.toSet(); root.listFiles()?.filter { it.name !in owned }?.forEach { it.delete() } }
    }
    private fun persist() {
        val array = JSONArray(records.values.map { t -> info(t).put("owner", t.owner).put("file", t.file.name).put("created", t.created)
            .put("local_bytes", t.localBytes).put("remote_bytes", t.remoteBytes).put("chunks", JSONObject(t.chunks.mapKeys { it.key.toString() })) })
        journal.write(array.toString())
    }
    @Synchronized private fun expire() {
        val expired = records.values.filter { System.currentTimeMillis() - it.created !in 0..(30 * 60_000) }
        expired.forEach { it.cancelled.set(true); records.remove(it.id); it.file.delete() }
        if (expired.isNotEmpty()) persist()
    }
    private fun activeCount() = records.values.count { it.status in listOf("staging", "receiving", "ready") }
    private fun admit(size: Long) {
        if (!healthy) throw BridgeFailure(503, "transfer_journal_unavailable")
        expire()
        if (activeCount() >= 2) throw BridgeFailure(429, "transfer_capacity")
        if (records.values.sumOf { if (it.status == "staging") ProtocolRules.MAX_FILE else it.localBytes } + size > 100L * 1024 * 1024) throw BridgeFailure(429, "transfer_byte_capacity")
        if (records.size >= 32) {
            val old = records.values.firstOrNull { it.status in listOf("cancelled", "failed", "downloaded") } ?: throw BridgeFailure(429, "transfer_history_capacity")
            records.remove(old.id); old.file.delete()
        }
    }
    @Synchronized fun begin(owner: String, json: JSONObject): JSONObject {
        val id = json.getString("transfer_id"); require(runCatching { UUID.fromString(id) }.isSuccess)
        val size = json.getLong("size"); require(size in 0..ProtocolRules.MAX_FILE)
        val hash = json.getString("sha256"); require(hash.matches(Regex("[a-f0-9]{64}")))
        require(json.getString("direction") == "mac_to_phone")
        val name = ProtocolRules.safeName(json.getString("display_name")); val mime = json.optString("mime_type", "application/octet-stream").take(128)
        records[id]?.let { if (it.owner != owner) throw SecurityException("Wrong transfer owner"); if (it.size != size || it.sha != hash || it.name != name || it.mime != mime) throw BridgeFailure(409, "transfer_conflict"); return info(it) }
        admit(size)
        val file = File(root, UUID.randomUUID().toString()).apply { createNewFile() }
        val transfer = Transfer(id, owner, name, mime, size, hash, file, "mac_to_phone")
        records[id] = transfer; persist(); return info(transfer)
    }
    @Synchronized private fun owned(id: String, owner: String): Transfer {
        if (!healthy) throw BridgeFailure(503, "transfer_journal_unavailable")
        expire(); val t = records[id] ?: throw BridgeFailure(404, "unknown_transfer")
        if (t.owner != owner) throw SecurityException("Wrong transfer owner")
        return t
    }
    @Synchronized fun info(id: String, owner: String) = info(owned(id, owner))
    private fun info(t: Transfer) = JSONObject().put("transfer_id", t.id).put("display_name", t.name).put("mime_type", t.mime).put("size", t.size).put("sha256", t.sha)
        .put("direction", t.direction).put("next_index", t.next).put("accepted_bytes", if (t.direction == "phone_to_mac") t.remoteBytes else t.localBytes)
        .put("staged_bytes", t.localBytes).put("committed", t.committed).put("chunk_size", 65536).put("status", t.status)
    @Synchronized fun put(id: String, owner: String, index: Int, hash: String, bytes: ByteArray): JSONObject {
        val t = owned(id, owner)
        require(t.direction == "mac_to_phone" && index >= 0 && bytes.size <= 65536 && hash.matches(Regex("[a-f0-9]{64}")))
        if (t.cancelled.get() || t.status in listOf("cancelled", "failed")) throw BridgeFailure(409, "transfer_cancelled")
        require(ProtocolRules.hash(bytes) == hash) { "Chunk hash mismatch" }
        t.chunks[index]?.let { if (it != hash) throw BridgeFailure(409, "chunk_conflict"); return info(t) }
        require(!t.committed && index == t.next && t.localBytes + bytes.size <= t.size && bytes.isNotEmpty())
        FileOutputStream(t.file, true).use { it.write(bytes); it.fd.sync() }
        t.chunks[index] = hash; t.next++; t.localBytes += bytes.size; persist(); return info(t)
    }
    fun commit(id: String, owner: String): JSONObject {
        val t = synchronized(this) { owned(id, owner).also { require(it.localBytes == it.size && !it.cancelled.get()) } }
        val digest = digest(t.file.inputStream())
        synchronized(this) {
            require(records[id] === t && digest == t.sha && t.file.length() == t.size && !t.cancelled.get())
            if (!store.trusted().has(owner)) throw SecurityException("Trust revoked")
            if (!t.committed) { t.committed = true; t.status = "received"; persist(); store.event("file_received", info(t), owner) }
            return info(t)
        }
    }
    @Synchronized fun read(id: String, owner: String, index: Int): ByteArray {
        val t = owned(id, owner); require(t.direction == "phone_to_mac" && t.committed && index >= 0 && !t.cancelled.get())
        val offset = index.toLong() * 65536; require(offset <= t.size)
        return RandomAccessFile(t.file, "r").use { file -> file.seek(offset); ByteArray(minOf(65536L, t.size - offset).toInt()).also { file.readFully(it) } }
    }
    @Synchronized fun remoteReceipt(id: String, owner: String, request: JSONObject): JSONObject {
        val t = owned(id, owner); require(t.direction == "phone_to_mac" && !t.cancelled.get())
        val bytes = request.getLong("accepted_bytes"); require(bytes in t.remoteBytes..t.size)
        val complete = request.getString("status") == "downloaded"
        if (complete) require(bytes == t.size && request.getString("sha256") == t.sha)
        t.remoteBytes = bytes; if (complete) t.status = "downloaded"; persist(); return info(t)
    }
    @Synchronized fun cancel(id: String, owner: String): JSONObject { owned(id, owner); return cancelLocal(id) }
    @Synchronized fun cancelLocal(id: String): JSONObject {
        val t = records[id] ?: throw BridgeFailure(404, "unknown_transfer")
        t.cancelled.set(true); t.status = "cancelled"; t.file.delete(); t.localBytes = 0; persist()
        stagingReads[id]?.let { cancelRead(it) }
        return JSONObject().put("cancelled", true)
    }
    fun stage(uri: Uri, recipientTrustId: String = store.selectedTrust() ?: throw IllegalArgumentException("Choose a trusted Mac"), onProgress: (Long) -> Unit = {}): JSONObject {
        require(uri.scheme == "content" && store.trusted().has(recipientTrustId))
        val id = UUID.randomUUID().toString(); val file = File(root, UUID.randomUUID().toString())
        val t = Transfer(id, recipientTrustId, "Shared file", "application/octet-stream", 0, "", file, "phone_to_mac", status = "staging")
        val read = StageRead(t, android.os.SystemClock.elapsedRealtime() + 30_000)
        synchronized(this) {
            if (stagingReads.size >= 2) throw BridgeFailure(429, "staging_reader_capacity")
            admit(ProtocolRules.MAX_FILE); file.createNewFile(); records[id] = t; stagingReads[id] = read
            try { persist() } catch (failure: Exception) { stagingReads.remove(id); records.remove(id); file.delete(); throw failure }
        }
        val timeout = deadlines.schedule({ cancelRead(read, timeout = true) },
            maxOf(0, read.deadline - android.os.SystemClock.elapsedRealtime()), java.util.concurrent.TimeUnit.MILLISECONDS)
        try {
            checkRead(read)
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null, read.signal)?.use {
                if (it.moveToFirst()) synchronized(this) { t.name = ProtocolRules.safeName(it.getString(0) ?: t.name) }
            }
            checkRead(read)
            val mime = context.contentResolver.getType(uri) ?: "application/octet-stream"
            checkRead(read)
            synchronized(this) { t.mime = mime.take(128) }
            val digest = MessageDigest.getInstance("SHA-256"); var total = 0L
            context.contentResolver.openAssetFileDescriptor(uri, "r", read.signal)!!.use { descriptor ->
                descriptor.createInputStream().use { input ->
                    read.stream.set(input); checkRead(read)
                    file.outputStream().use { output ->
                        val block = ByteArray(65536)
                        while (true) {
                            checkRead(read)
                            val count = input.read(block)
                            // close() may wake a blocked read with EOF: never publish that truncated result.
                            checkRead(read)
                            if (count < 0) break
                            total += count; require(total <= ProtocolRules.MAX_FILE); digest.update(block, 0, count); output.write(block, 0, count)
                            synchronized(this) { t.localBytes = total }; onProgress(total)
                        }
                    }
                }
            }
            synchronized(this) {
                checkRead(read)
                if (!store.trusted().has(recipientTrustId)) throw SecurityException("Trust revoked")
                t.size = total; t.sha = digest.digest().joinToString("") { "%02x".format(it) }; t.committed = true; t.status = "ready"; persist()
                checkRead(read)
                check(read.state.compareAndSet(0, 2)) { "File preparation cancelled or timed out" }
                return info(t).also { store.event("file_shared", it, recipientTrustId) }
            }
        } catch (failure: Exception) {
            synchronized(this) { t.status = if (read.timedOut.get() || !t.cancelled.get()) "failed" else "cancelled"; t.committed = false; t.localBytes = 0; file.delete(); persist() }
            throw failure
        } finally {
            timeout.cancel(false)
            read.stream.set(null)
            stagingReads.remove(id)
        }
    }
    @Synchronized fun listLocal(): JSONArray { expire(); return JSONArray(records.values.map { info(it).put("owner", it.owner).put("can_cancel", it.status !in listOf("cancelled", "failed")) }) }
    @Synchronized fun received() = JSONArray(records.values.filter { it.direction == "mac_to_phone" && it.committed && !it.cancelled.get() }.map { info(it) })
    fun exportReceived(id: String, destination: Uri) {
        val t = synchronized(this) { (records[id] ?: throw BridgeFailure(404, "unknown_transfer")).also { require(it.committed && it.direction == "mac_to_phone" && !it.cancelled.get()) } }
        context.contentResolver.openOutputStream(destination)!!.use { out -> t.file.inputStream().use { it.copyTo(out, 65536) } }
    }
    @Synchronized fun revoke(owner: String) { records.values.filter { it.owner == owner }.forEach { cancelLocal(it.id) } }
    private fun digest(input: InputStream): String = input.use { val d = MessageDigest.getInstance("SHA-256"); val block = ByteArray(65536); while (true) { val n = it.read(block); if (n < 0) break; d.update(block, 0, n) }; d.digest().joinToString("") { byte -> "%02x".format(byte) } }
}

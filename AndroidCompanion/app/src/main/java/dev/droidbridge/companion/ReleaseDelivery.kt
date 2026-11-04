package dev.droidbridge.companion

import android.os.SystemClock
import org.json.JSONObject
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/** Explicit public release lookup. Never includes device IDs, trust or shared content. */
class ReleaseDelivery : AutoCloseable {
    @Volatile private var connection: HttpsURLConnection? = null
    @Volatile private var closed = false
    data class Metadata(val version: String, val size: Long, val sha256: String, val downloadUrl: String, val releaseUrl: String, val signing: String) {
        fun summary(): String {
            val trust = if (signing == "developer_id_notarized") "The official release reports Developer ID signing and Apple notarization. macOS verifies the downloaded app when you open it."
                else "Development release: ad-hoc signed; not notarized. macOS may require explicit approval."
            return "DroidBridge $version · Apple Silicon · macOS 26+\n${String.format(java.util.Locale.ROOT, "%.1f", size / 1048576.0)} MiB\nSHA-256: $sha256\n$trust A checksum verifies bytes, not a Developer ID identity."
        }
    }
    companion object {
        const val VERSION = "0.2.0"
        const val RELEASE_TEAM = "2XAXFD3872"
        const val MANIFEST = "https://github.com/SloopWorks/DroidBridge/releases/download/v$VERSION/release-manifest.json"
        fun parse(bytes: ByteArray): Metadata {
            require(bytes.size <= 16384) { "Release metadata exceeds its size limit" }
            val utf8 = Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString()
            ProtocolRules.validateJSON(utf8)
            val json = JSONObject(utf8)
            val size = json.get("size_bytes")
            require(size is Number && size.toDouble().isFinite() && size.toDouble() == size.toLong().toDouble() && size.toLong() in 1..268435456)
            require(json.getString("version") == VERSION && json.getString("architecture") == "arm64" && json.getString("minimum_macos") == "26.0")
            val sha = json.getString("sha256"); require(sha.matches(Regex("[a-f0-9]{64}")))
            val signing = json.getString("signing")
            when (signing) {
                "ad_hoc_not_notarized" -> {
                    require(!json.has("schema_version") || json.get("schema_version") == 1)
                    require(!json.has("team_id") && !json.has("source_commit") && !json.has("source_dirty"))
                }
                "developer_id_notarized" -> {
                    require(json.get("schema_version") == 2 && json.getString("team_id") == RELEASE_TEAM)
                    require(json.get("source_dirty") == false)
                    require(json.get("source_commit") is String && json.get("build") is String)
                    require(json.getString("source_commit").matches(Regex("[a-f0-9]{40}")))
                    require(json.getString("build").matches(Regex("[1-9][0-9]*")))
                }
                else -> require(false) { "Unknown installer signing policy" }
            }
            val download = "https://github.com/SloopWorks/DroidBridge/releases/download/v$VERSION/DroidBridge-$VERSION-arm64.dmg"
            val release = "https://github.com/SloopWorks/DroidBridge/releases/tag/v$VERSION"
            require(json.getString("download_url") == download && json.getString("release_url") == release)
            return Metadata(VERSION, size.toLong(), sha, download, release, signing)
        }
        private fun allowed(url: URL): Boolean = url.protocol == "https" && url.userInfo == null && (url.port == -1 || url.port == 443) &&
            url.host in setOf("github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com")
    }
    fun fetch(): Metadata {
        val deadline = SystemClock.elapsedRealtime() + 10000
        var target = URL(MANIFEST)
        repeat(6) { redirects ->
            check(!closed && !Thread.currentThread().isInterrupted) { "Release lookup cancelled" }
            require(allowed(target))
            val remaining = (deadline - SystemClock.elapsedRealtime()).coerceAtMost(5000).toInt(); check(remaining > 0)
            val opened = target.openConnection() as HttpsURLConnection
            connection = opened
            // Cancellation may race connection publication. No request may start
            // after close() missed this newly allocated connection.
            if (closed) { opened.disconnect(); error("Release lookup cancelled") }
            try {
                opened.instanceFollowRedirects = false; opened.connectTimeout = remaining; opened.readTimeout = remaining
                opened.setRequestProperty("Accept", "application/json")
                val status = opened.responseCode
                require(opened.headerFields.entries.sumOf { (key, values) -> (key?.length ?: 0) + values.sumOf { it.length + 4 } } <= 16384)
                if (status in setOf(301, 302, 303, 307, 308)) {
                    require(redirects < 5)
                    target = URL(target, opened.getHeaderField("Location") ?: error("Missing release redirect"))
                    require(allowed(target)); return@repeat
                }
                require(status == 200) { "This release's installer is not available yet" }
                require(opened.contentLengthLong <= 16384)
                val output = java.io.ByteArrayOutputStream()
                opened.inputStream.use { input ->
                    val buffer = ByteArray(2048)
                    while (true) {
                        check(!closed && !Thread.currentThread().isInterrupted && SystemClock.elapsedRealtime() < deadline)
                        val count = input.read(buffer); if (count < 0) break
                        require(output.size() + count <= 16384); output.write(buffer, 0, count)
                    }
                }
                return parse(output.toByteArray())
            } finally { opened.disconnect(); if (connection === opened) connection = null }
        }
        error("Too many release redirects")
    }
    /** UI cancellation never waits on a TLS socket lock; I/O ends within its timeout. */
    fun cancel() { closed = true }
    override fun close() { closed = true; connection?.disconnect() }
}

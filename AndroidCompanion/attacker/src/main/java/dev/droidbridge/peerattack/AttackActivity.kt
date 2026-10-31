package dev.droidbridge.peerattack

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLSocket

/** Ordinary INTERNET-only APK occupies the companion's loopback port. Never distributed with product. */
class AttackActivity : Activity() {
    private var listener: ServerSocket? = null
    private val workers = ThreadPoolExecutor(2, 2, 0, TimeUnit.SECONDS, ArrayBlockingQueue(2))
    private val sockets = java.util.concurrent.ConcurrentHashMap.newKeySet<Socket>()
    private val captures = JSONArray()
    private var mode = ""
    private var runId = ""
    private var claimedId = ""
    private lateinit var label: TextView
    @Volatile private var stopped = false
    override fun onCreate(savedInstanceState: Bundle?) { super.onCreate(savedInstanceState); BridgeTlsIdentity.configure(applicationContext); label = TextView(this).apply { textSize = 20f; setPadding(40,80,40,40) }; setContentView(label); start(intent) }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); stop(); start(intent) }
    private fun start(intent: Intent) {
        mode = intent.getStringExtra("mode") ?: "plain"; require(mode in listOf("plain", "tls"))
        runId = intent.getStringExtra("run_id") ?: java.util.UUID.randomUUID().toString(); require(runCatching { java.util.UUID.fromString(runId) }.isSuccess)
        claimedId = intent.getStringExtra("claimed_device_id") ?: java.util.UUID.randomUUID().toString(); require(runCatching { java.util.UUID.fromString(claimedId) }.isSuccess)
        captures.apply { while (length() > 0) remove(0) }; stopped = false
        Thread {
            try {
                listener = if (mode == "tls") BridgeTlsIdentity.serverSocket() else ServerSocket(37841, 8, InetAddress.getByName("127.0.0.1"))
                save(); runOnUiThread { label.text = "Adversarial peer listening\nMode: $mode\nRun: $runId\nPermission: INTERNET only\nNo companion private key or root access" }
                while (!stopped) {
                    val socket = listener!!.accept(); sockets.add(socket)
                    try { workers.execute { try { socket.use { capture(it) } } finally { sockets.remove(socket) } } } catch (_: Exception) { socket.close(); sockets.remove(socket) }
                }
            } catch (_: Exception) { if (!stopped) runOnUiThread { label.text = "Listener unavailable. Stop the genuine companion first." } }
        }.start()
    }
    private fun capture(socket: Socket) {
        val data = ByteArrayOutputStream(); var phase = "plain_read"; var tlsHandshake = false
        try {
            socket.soTimeout = 3000
            if (socket is SSLSocket) { phase = "tls_handshake"; socket.startHandshake(); tlsHandshake = true; phase = "tls_application_read" }
            val buffer = ByteArray(4096)
            while (data.size() < 65536) {
                val count = socket.getInputStream().read(buffer, 0, minOf(buffer.size, 65536 - data.size())); if (count < 0) break; data.write(buffer, 0, count)
                val request = data.toByteArray().toString(Charsets.ISO_8859_1)
                if (request.contains("\r\n\r\n")) {
                    // Believable public hello; an unauthorized client must never reach this response.
                    val id = request.lineSequence().firstOrNull { it.startsWith("X-Request-ID:", true) }?.substringAfter(':')?.trim() ?: java.util.UUID.randomUUID().toString()
                    val body = JSONObject().put("protocol", 1).put("request_id", id).put("data", JSONObject().put("device_id", claimedId).put("device_name", "Pixel test peer").put("protocol_min",1).put("protocol_max",1).put("capabilities",JSONArray()).put("pairing_available",true)).toString().toByteArray()
                    socket.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray()); socket.getOutputStream().write(body); break
                }
            }
        } catch (_: Exception) { /* failure phase is recorded without exception/content logging */ }
        val bytes = data.toByteArray()
        val text = bytes.toString(Charsets.ISO_8859_1)
        val isHttp = text.startsWith("GET ") || text.startsWith("POST ") || text.startsWith("PUT ") || text.startsWith("DELETE ")
        synchronized(captures) {
            if (captures.length() >= 8) captures.remove(0)
            val index = captures.length(); File(filesDir, "$runId-$index.bin").writeBytes(bytes)
            captures.put(JSONObject().put("phase",phase).put("tls_handshake_completed",tlsHandshake).put("captured_bytes",bytes.size)
                .put("application_http_bytes",if (mode == "tls" || isHttp) bytes.size else 0).put("http_request_prefix",isHttp)
                .put("authorization_header_present",text.contains("Authorization:",true)).put("captured_sha256",ProtocolRules.hash(bytes)))
            save()
        }
    }
    @Synchronized private fun save() {
        val json = JSONObject().put("run_id",runId).put("mode",mode).put("claimed_device_id",claimedId)
            .put("server_pin",if (mode == "tls") BridgeTlsIdentity.serverPin() else JSONObject.NULL).put("ordinary_permissions",JSONArray(listOf("android.permission.INTERNET")))
            .put("listening",listener?.isBound == true && listener?.isClosed == false).put("captures",captures)
        File(filesDir,"capture.json").writeText(json.toString())
    }
    private fun stop() { stopped = true; runCatching { listener?.close() }; sockets.forEach { runCatching { it.close() } } }
    override fun onDestroy() { stop(); workers.shutdownNow(); super.onDestroy() }
}
object ProtocolRules { fun secureEqual(a: String, b: String) = java.security.MessageDigest.isEqual(a.toByteArray(), b.toByteArray()); fun hash(data: ByteArray) = java.security.MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) } }

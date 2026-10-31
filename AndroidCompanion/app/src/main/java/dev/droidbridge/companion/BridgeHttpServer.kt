package dev.droidbridge.companion

import org.json.JSONObject
import java.io.BufferedInputStream
import java.net.InetAddress
import java.net.Socket
import java.net.URLDecoder
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Pinned TLS on loopback: ADB transport alone does not authenticate a local Android listener. */
class BridgeHttpServer(private val store: BridgeStore) : AutoCloseable {
    private val server = BridgeTlsIdentity.serverSocket()
    private val workers = ThreadPoolExecutor(4, 4, 0, TimeUnit.SECONDS, ArrayBlockingQueue(4))
    private val activeSockets = java.util.concurrent.ConcurrentHashMap.newKeySet<Socket>()
    private val writeDeadlines = java.util.concurrent.ScheduledThreadPoolExecutor(1).apply { removeOnCancelPolicy = true }
    @Volatile private var closed = false
    private val eventSlots = java.util.concurrent.Semaphore(1)
    private val handshakeSlots = java.util.concurrent.Semaphore(2)
    @Volatile internal var lastHandshakeFailure: Throwable? = null
    private val acceptor = Thread({
        while (!closed) {
            val socket = try { server.accept() } catch (_: Exception) { break }
            activeSockets.add(socket)
            try { workers.execute { try { socket.use { handle(it) } } finally { activeSockets.remove(socket) } } } catch (_: Exception) { activeSockets.remove(socket); socket.close() }
        }
    }, "DroidBridge-accept")
    fun start() { acceptor.start() }
    private fun line(input: BufferedInputStream, remaining: Int, socket: Socket, deadline: Long): String {
        val data = ArrayList<Byte>()
        while (true) {
            socket.soTimeout = (deadline - android.os.SystemClock.elapsedRealtime()).also { require(it > 0) }.toInt()
            val byte = input.read(); require(byte >= 0) { "Unexpected end" }
            if (byte == 10) { require(data.lastOrNull() == 13.toByte()); data.removeAt(data.lastIndex); break }
            require(data.size < remaining) { "Header too large" }; data.add(byte.toByte())
        }
        return data.toByteArray().toString(Charsets.ISO_8859_1)
    }
    private fun handle(socket: Socket) {
        // No HTTP parser or response is reachable until TLS proves possession of the installed key.
        if (!handshakeSlots.tryAcquire()) return
        val handshakeDeadline = writeDeadlines.schedule({ runCatching { socket.close() } }, 3, TimeUnit.SECONDS)
        try {
            socket.soTimeout = 3000
            (socket as javax.net.ssl.SSLSocket).startHandshake()
            require(socket.session.protocol in listOf("TLSv1.2", "TLSv1.3"))
        } catch (failure: Exception) { lastHandshakeFailure = failure; return }
        finally { handshakeDeadline.cancel(false); handshakeSlots.release() }
        var requestId = UUID.randomUUID().toString()
        try {
            socket.soTimeout = 5_000
            val deadline = android.os.SystemClock.elapsedRealtime() + 5_000
            val input = BufferedInputStream(socket.getInputStream(), 8192)
            val first = line(input, 2048, socket, deadline).split(' ')
            require(first.size == 3 && first[2] == "HTTP/1.1" && first[0] in listOf("GET", "POST", "PUT", "DELETE"))
            val method = first[0]; val target = first[1]
            require(target.startsWith("/v1/") && !target.contains("#") && target.length <= 2048)
            val path = target.substringBefore('?')
            require(!path.contains('%') && !path.contains("..") && !path.contains('\\'))
            val query = LinkedHashMap<String, String>()
            for (entry in target.substringAfter('?', "").split('&').filter { it.isNotEmpty() }) {
                val name = URLDecoder.decode(entry.substringBefore('='), "UTF-8")
                if (query.containsKey(name)) throw BridgeFailure(400, "duplicate_query")
                query[name] = URLDecoder.decode(entry.substringAfter('=', ""), "UTF-8")
            }
            val headers = LinkedHashMap<String, String>(); var bytes = 0
            while (true) {
                val value = line(input, ProtocolRules.MAX_HEADERS - bytes, socket, deadline); bytes += value.length + 2
                if (value.isEmpty()) break
                require(value.contains(':') && !value.first().isWhitespace())
                val key = value.substringBefore(':').lowercase(); require(key.matches(Regex("[a-z0-9!#$%&'*+.^_`|~-]+"))); require(!headers.containsKey(key)) { "Duplicate header" }
                headers[key] = value.substringAfter(':').trim()
            }
            val size = ProtocolRules.contentLength(headers)
            val rawChunk = method == "PUT" && path.matches(Regex("/v1/transfers/[a-fA-F0-9-]{36}/chunks/[0-9]+"))
            if (rawChunk && size > 65536) throw BridgeFailure(413, "chunk_too_large")
            if (method in listOf("POST", "PUT") && !headers.containsKey("content-length")) throw BridgeFailure(400, "length_required")
            if (method in listOf("GET", "DELETE") && size != 0) throw BridgeFailure(400, "unexpected_body")
            val body = ByteArray(size); var offset = 0
            while (offset < size) { socket.soTimeout = (deadline - android.os.SystemClock.elapsedRealtime()).also { require(it > 0) }.toInt(); val read = input.read(body, offset, size - offset); require(read > 0); offset += read }
            val decoded = if (rawChunk) "" else Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(body)).toString()
            if (!rawChunk && decoded.isNotBlank()) ProtocolRules.validateJSON(decoded)
            val json = if (decoded.isBlank()) JSONObject() else JSONObject(decoded)
            if (json.has("protocol")) require(json.getInt("protocol") == 1)
            requestId = json.optString("request_id", headers["x-request-id"] ?: requestId)
            require(runCatching { UUID.fromString(requestId) }.isSuccess)
            if (headers["x-request-id"] != null && json.has("request_id")) require(headers["x-request-id"] == json.getString("request_id"))
            val auth = headers["authorization"] ?: ""
            val macId = if (auth.startsWith("Bearer ")) store.authenticate(auth.substring(7)) else null
            if (path != "/v1/hello" && path != "/v1/pair" && !path.startsWith("/v1/pair/")) {
                if (macId == null) throw SecurityException("Unauthorized")
            }
            val data: JSONObject = when {
                method == "GET" && path == "/v1/hello" -> store.hello()
                method == "POST" && path == "/v1/pair" -> store.requestPair(json)
                method == "GET" && path.startsWith("/v1/pair/") -> store.pollPair(path.substringAfterLast('/'), auth.removePrefix("Pairing "))
                method == "GET" && path == "/v1/catalog" -> store.catalog(query["cursor"] ?: "", (query["limit"] ?: "64").toInt(), macId)
                method == "GET" && path == "/v1/catalog/changes" -> store.catalogChanges(query["after"] ?: "", macId)
                method == "GET" && path.startsWith("/v1/icons/") -> {
                    val hash = path.substringAfterLast('/').removeSuffix(".png")
                    val icon = store.icon(hash) ?: return respond(socket, 404, requestId, null, "not_found")
                    if (store.authenticate(auth.removePrefix("Bearer ")) != macId) throw SecurityException("Trust revoked")
                    if (icon.size > 262144) throw BridgeFailure(413, "icon_too_large")
                    writeResponse(socket, "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: ${icon.size}\r\nETag: \"$hash\"\r\nConnection: close\r\n\r\n", icon); return
                }
                method == "GET" && path == "/v1/events" -> { if (!eventSlots.tryAcquire()) throw BridgeFailure(429, "poll_capacity"); try { store.events((query["after"] ?: "0").toLong(), (query["limit"] ?: "64").toInt(), (query["wait_ms"] ?: "25000").toLong(), query["epoch"], macId) } finally { eventSlots.release() } }
                method == "GET" && path == "/v1/identity" -> JSONObject().put("device_id", store.deviceId).put("protocol", 1).put("trust_id", macId)
                method == "GET" && path == "/v1/diagnostics" -> store.status().put("service_running", store.running).put("protocol", 1)
                method == "POST" && path == "/v1/commands" -> store.command(json, macId!!)
                method == "POST" && path.matches(Regex("/v1/commands/[a-fA-F0-9-]{36}/receipt")) -> store.commandReceipt(path.split('/')[3], json, macId!!)
                method == "POST" && path == "/v1/state" -> store.updatePeerState(macId!!, json)
                method == "POST" && path == "/v1/transfers" -> store.transfers.begin(macId!!, json)
                method == "GET" && path.matches(Regex("/v1/transfers/[a-fA-F0-9-]{36}")) -> store.transfers.info(path.substringAfterLast('/'), macId!!)
                method == "DELETE" && path.matches(Regex("/v1/transfers/[a-fA-F0-9-]{36}")) -> store.transfers.cancel(path.substringAfterLast('/'), macId!!)
                rawChunk -> store.transfers.put(path.split('/')[3], macId!!, path.substringAfterLast('/').toInt(), headers["x-chunk-sha256"] ?: "", body)
                method == "POST" && path.matches(Regex("/v1/transfers/[a-fA-F0-9-]{36}/commit")) -> store.transfers.commit(path.split('/')[3], macId!!)
                method == "POST" && path.matches(Regex("/v1/transfers/[a-fA-F0-9-]{36}/receipt")) -> store.transfers.remoteReceipt(path.split('/')[3], macId!!, json)
                method == "GET" && path.matches(Regex("/v1/transfers/[a-fA-F0-9-]{36}/chunks/[0-9]+")) -> {
                    val chunk = store.transfers.read(path.split('/')[3], macId!!, path.substringAfterLast('/').toInt())
                    if (store.authenticate(auth.removePrefix("Bearer ")) != macId) throw SecurityException("Trust revoked")
                    writeResponse(socket, "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: ${chunk.size}\r\nX-Chunk-SHA256: ${ProtocolRules.hash(chunk)}\r\nConnection: close\r\n\r\n", chunk); return
                }
                method == "GET" && path == "/v1/trust" -> store.trustPublic(macId!!)
                method == "DELETE" && path.startsWith("/v1/trust/") -> { val targetTrust = path.substringAfterLast('/'); if (targetTrust != macId) throw SecurityException("Cannot revoke another Mac"); store.revoke(targetTrust); JSONObject().put("revoked", true) }
                else -> return respond(socket, 404, requestId, null, "not_found")
            }
            if (macId != null && !(method == "DELETE" && path == "/v1/trust/$macId") && store.authenticate(auth.substring(7)) != macId) throw SecurityException("Trust revoked")
            respond(socket, if (path == "/v1/pair" && method == "POST") 202 else 200, requestId, data)
        } catch (_: SecurityException) { respond(socket, 401, requestId, null, "unauthorized") }
        catch (e: BridgeFailure) { respond(socket, e.status, requestId, null, e.code) }
        catch (e: IllegalArgumentException) { respond(socket, if (e.message == "stale_cursor") 409 else 400, requestId, null, if (e.message == "stale_cursor") "stale_cursor" else "invalid_request") }
        catch (_: org.json.JSONException) { respond(socket, 400, requestId, null, "invalid_json") }
        catch (_: android.util.MalformedJsonException) { respond(socket, 400, requestId, null, "invalid_json") }
        catch (_: java.nio.charset.CharacterCodingException) { respond(socket, 400, requestId, null, "invalid_utf8") }
        catch (_: java.net.SocketTimeoutException) { respond(socket, 408, requestId, null, "request_timeout") }
        catch (_: Exception) { respond(socket, 503, requestId, null, "unavailable") }
    }
    private fun respond(socket: Socket, status: Int, id: String, data: JSONObject?, error: String? = null) {
        runCatching {
            val json = JSONObject().put("protocol", 1).put("request_id", id)
            if (data != null) json.put("data", data) else json.put("error", JSONObject().put("code", error).put("message", error).put("retryable", status == 503))
            val bytes = json.toString().toByteArray(Charsets.UTF_8)
            require(bytes.size <= ProtocolRules.MAX_JSON)
            writeResponse(socket, "HTTP/1.1 $status Response\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n", bytes)
        }
    }
    private fun writeResponse(socket: Socket, headers: String, body: ByteArray) {
        val timeout = writeDeadlines.schedule({ runCatching { socket.close() } }, 5, TimeUnit.SECONDS)
        try { val output = socket.getOutputStream(); output.write(headers.toByteArray(Charsets.US_ASCII)); output.write(body); output.flush() }
        finally { timeout.cancel(false) }
    }
    override fun close() {
        closed = true; server.close(); activeSockets.forEach { runCatching { it.close() } }
        workers.shutdownNow(); writeDeadlines.shutdownNow()
    }
}

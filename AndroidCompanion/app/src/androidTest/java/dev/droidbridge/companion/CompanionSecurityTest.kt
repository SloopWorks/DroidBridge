package dev.droidbridge.companion

import android.content.Context
import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/** Real HTTP adversarial tests with isolated private preferences/files and real Android Keystore. */
class CompanionSecurityTest {
    private class Peer : AutoCloseable {
        private val target = InstrumentationRegistry.getInstrumentation().targetContext
        private val name = "security-${UUID.randomUUID()}"
        private val directory = File(target.cacheDir, name).apply { mkdirs() }
        private val context = object : ContextWrapper(target) {
            override fun getFilesDir() = directory
            override fun getSharedPreferences(name: String, mode: Int) = target.getSharedPreferences(this@Peer.name + name, mode)
        }
        var store: BridgeStore = BridgeStore::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }.newInstance(context)
        private var server = BridgeHttpServer(store).apply { start() }
        fun restart() { server.close(); store = BridgeStore::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }.newInstance(context); server = BridgeHttpServer(store).apply { start() } }
        fun request(path: String, body: JSONObject? = null, token: String? = null, method: String? = null, bytes: ByteArray? = null, chunkHash: String? = null): Pair<Int, JSONObject> {
            val c = PinnedTestClient.open(path)
            c.connectTimeout = 3000; c.readTimeout = 5000; c.requestMethod = method ?: if (body != null) "POST" else "GET"
            token?.let { c.setRequestProperty("Authorization", "Bearer $it") }
            chunkHash?.let { c.setRequestProperty("X-Chunk-SHA256", it) }
            if (body != null || bytes != null) { c.doOutput = true; c.outputStream.use { it.write(bytes ?: body!!.toString().toByteArray()) } }
            val status = c.responseCode; val parsed = JSONObject((if (status < 400) c.inputStream else c.errorStream).bufferedReader().use { it.readText() }); c.disconnect()
            return status to parsed
        }
        fun pair(): Pair<String, String> {
            val secret = store.startPairing(); val mac = UUID.randomUUID().toString()
            val pending = request("/v1/pair", JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret).put("mac_id", mac).put("mac_name", "Security test"))
            assertEquals(202, pending.first); val id = pending.second.getJSONObject("data").getString("pairing_id")
            store.approvePair(); val paired = store.pollPair(id, secret)
            return paired.getString("credential") to paired.getString("trust_id")
        }
        override fun close() { server.close(); directory.deleteRecursively() }
    }
    @Test fun trustScopedEventsAndRevocationAfterLongPoll() = Peer().use { p ->
        val a = p.pair(); val b = p.pair()
        p.store.event("clipboard_received", JSONObject().put("text", "synthetic-test-only"), a.second)
        val eventsA = p.request("/v1/events?after=0&wait_ms=0", token = a.first).second.getJSONObject("data").getJSONArray("events")
        val eventsB = p.request("/v1/events?after=0&wait_ms=0", token = b.first).second.getJSONObject("data").getJSONArray("events")
        assertEquals(1, eventsA.length()); assertEquals(0, eventsB.length())
        val result = java.util.concurrent.atomic.AtomicInteger()
        val poll = Thread { result.set(p.request("/v1/events?after=1&wait_ms=2000", token = a.first).first) }.apply { start() }
        Thread.sleep(200); p.store.revoke(a.second); p.store.event("catalog_changed", JSONObject())
        poll.join(4000); assertFalse(poll.isAlive); assertEquals(401, result.get())
        assertEquals(200, p.request("/v1/identity", token = b.first).first)
    }
    @Test fun receiptsRetainUnexpiredIdentitiesAndRejectCapacity() = Peer().use { p ->
        val a = p.pair(); val b = p.pair()
        fun ping(id: String = UUID.randomUUID().toString()) = JSONObject().put("request_id", id).put("kind", "ping").put("payload", JSONObject()).put("expires_at", java.time.Instant.now().plusSeconds(29).toString())
        val first = ping(); assertEquals(200, p.request("/v1/commands", first, a.first).first)
        assertEquals(409, p.request("/v1/commands", first, b.first).first)
        val changed = JSONObject(first.toString()).put("payload", JSONObject().put("changed", true))
        assertEquals(409, p.request("/v1/commands", changed, a.first).first)
        repeat(511) { assertEquals(200, p.request("/v1/commands", ping(), a.first).first) }
        assertEquals(429, p.request("/v1/commands", ping(), a.first).first)
        assertEquals(200, p.request("/v1/commands", first, a.first).first)
        val expired = ping().put("expires_at", java.time.Instant.now().minusSeconds(1).toString())
        assertEquals(400, p.request("/v1/commands", expired, a.first).first)
    }
    @Test fun transferHashesOrderingTrustAndTraversal() = Peer().use { p ->
        val a = p.pair(); val b = p.pair(); val bytes = "synthetic-file-test".toByteArray(); val sha = ProtocolRules.hash(bytes); val id = UUID.randomUUID().toString()
        val begin = JSONObject().put("request_id", UUID.randomUUID().toString()).put("transfer_id", id).put("direction", "mac_to_phone").put("display_name", "../../escape.txt").put("mime_type", "text/plain").put("size", bytes.size).put("sha256", sha)
        assertEquals(200, p.request("/v1/transfers", begin, a.first).first)
        assertEquals(401, p.request("/v1/transfers/$id", token = b.first).first)
        assertEquals(400, p.request("/v1/transfers/$id/chunks/1", token = a.first, method = "PUT", bytes = bytes, chunkHash = sha).first)
        assertEquals(400, p.request("/v1/transfers/$id/chunks/0", token = a.first, method = "PUT", bytes = bytes, chunkHash = "0".repeat(64)).first)
        assertEquals(200, p.request("/v1/transfers/$id/chunks/0", token = a.first, method = "PUT", bytes = bytes, chunkHash = sha).first)
        assertEquals(200, p.request("/v1/transfers/$id/chunks/0", token = a.first, method = "PUT", bytes = bytes, chunkHash = sha).first)
        val committed = p.request("/v1/transfers/$id/commit", JSONObject().put("request_id", UUID.randomUUID().toString()), a.first)
        assertEquals(200, committed.first); assertEquals("escape.txt", committed.second.getJSONObject("data").getString("display_name"))
        p.store.revoke(a.second); assertEquals(401, p.request("/v1/transfers/$id", token = a.first).first)
    }
    @Test fun profileAndExportCommandsUpdateRealPhoneState() = Peer().use { p ->
        val pair = p.pair(); p.store.refreshCatalog()
        fun command(kind: String, payload: JSONObject) = JSONObject().put("request_id", UUID.randomUUID().toString()).put("kind", kind).put("payload", payload).put("expires_at", java.time.Instant.now().plusSeconds(25).toString())
        assertEquals(200, p.request("/v1/commands", command("set_profile", JSONObject().put("profile", "responsive")), pair.first).first)
        assertEquals("responsive", p.store.status().getString("profile"))
        val app = p.store.catalogLocal().getJSONObject(0).getString("package_name")
        assertEquals(200, p.request("/v1/commands", command("set_export", JSONObject().put("package_name", app).put("selected", false)), pair.first).first)
        val choices = p.store.catalogLocal()
        assertFalse((0 until choices.length()).map { choices.getJSONObject(it) }.first { it.getString("package_name") == app }.getBoolean("export_to_mac"))
    }

    @Test fun phoneCommandReceiptsAreDurableScopedAndProgressToTerminal() = Peer().use { p ->
        val a = p.pair(); val b = p.pair(); p.store.selectTrust(a.second)
        val id = p.store.phoneCommand("share_text", JSONObject().put("text", "synthetic-private-command"))
        assertEquals("queued", p.store.commandOutcomes().getJSONObject(0).getString("status"))
        val accepted = JSONObject().put("request_id", id).put("status", "accepted").put("result", JSONObject())
        assertEquals(401, p.request("/v1/commands/$id/receipt", accepted, b.first).first)
        assertEquals(200, p.request("/v1/commands/$id/receipt", accepted, a.first).first)
        val applied = JSONObject().put("request_id", id).put("status", "applied").put("result", JSONObject().put("state", "received"))
        assertEquals(200, p.request("/v1/commands/$id/receipt", applied, a.first).first)
        assertEquals("applied", p.store.commandOutcomes().getJSONObject(0).getString("status"))
        assertEquals(409, p.request("/v1/commands/$id/receipt", JSONObject(applied.toString()).put("status", "rejected"), a.first).first)
        p.restart()
        assertEquals("applied", p.store.commandOutcomes().getJSONObject(0).getString("status"))
        assertEquals(200, p.request("/v1/commands/$id/receipt", applied, a.first).first)
        val fresh = p.store.phoneCommand("open_app", JSONObject().put("package_name", "com.android.settings"))
        p.restart()
        val events = p.request("/v1/events?after=0&epoch=old-service&wait_ms=0", token = a.first).second.getJSONObject("data")
        assertTrue(events.getBoolean("reset_required"))
        assertTrue((0 until events.getJSONArray("events").length()).map { events.getJSONArray("events").getJSONObject(it) }.any { it.getJSONObject("payload").optString("request_id") == fresh })
    }
    @Test fun peerStateAndExportPreferencesAreScopedToTheSelectedMac() = Peer().use { p ->
        val a = p.pair(); val b = p.pair(); p.store.running = true; p.store.refreshCatalog()
        val session = JSONObject().put("session_id", UUID.randomUUID().toString()).put("package_name", "com.android.settings").put("label", "Settings").put("backend", "native").put("phase", "running")
        val state = JSONObject().put("request_id", UUID.randomUUID().toString()).put("sessions", org.json.JSONArray().put(session)).put("connection_state", "connected").put("audio_route", "phone")
        assertEquals(200, p.request("/v1/state", state, a.first).first)
        p.store.selectTrust(a.second); assertTrue(p.store.peerStatus().getBoolean("connected")); assertEquals(1, p.store.peerStatus().getJSONArray("sessions").length())
        val unchanged = JSONObject().put("request_id", UUID.randomUUID().toString()).put("unchanged", true)
        assertEquals(200, p.request("/v1/state", unchanged, a.first).first)
        assertEquals(1, p.store.peerStatus().getJSONArray("sessions").length())
        assertEquals("phone", p.store.peerStatus().getString("audio_route"))
        assertEquals(409, p.request("/v1/state", unchanged, b.first).first)
        assertEquals(400, p.request("/v1/state", JSONObject(unchanged.toString()).put("sessions", org.json.JSONArray()), a.first).first)
        assertEquals(400, p.request("/v1/state", JSONObject(unchanged.toString()).put("unchanged", "true"), a.first).first)
        p.store.selectTrust(b.second); assertFalse(p.store.peerStatus().getBoolean("connected")); assertEquals(0, p.store.peerStatus().getJSONArray("sessions").length())
        val app = p.store.catalogLocal().getJSONObject(0).getString("package_name")
        p.store.chooseExport(app, false, a.second)
        val catalogA = p.request("/v1/catalog?limit=64", token = a.first).second.getJSONObject("data")
        val catalogB = p.request("/v1/catalog?limit=64", token = b.first).second.getJSONObject("data")
        fun exported(catalog: JSONObject) = (0 until catalog.getJSONArray("items").length()).map { catalog.getJSONArray("items").getJSONObject(it) }.first { it.getString("package_name") == app }.getBoolean("export_to_mac")
        assertFalse(exported(catalogA)); assertTrue(exported(catalogB)); assertNotEquals(catalogA.getString("generation"), catalogB.getString("generation"))
        p.store.revoke(a.second)
        try { p.store.updatePeerState(a.second, state); fail("Revoked trust published a dashboard snapshot") } catch (_: SecurityException) {}
        try { p.store.updatePeerState(a.second, unchanged); fail("Revoked trust refreshed a dashboard snapshot") } catch (_: SecurityException) {}
    }
    @Test fun transferResumesAcrossPeerRestartAndCancelsExplicitly() = Peer().use { p ->
        val pair = p.pair(); val id = UUID.randomUUID().toString(); val first = ByteArray(65536) { (it % 251).toByte() }; val second = "tail".toByteArray(); val sha = ProtocolRules.hash(first + second)
        val begin = JSONObject().put("request_id", UUID.randomUUID().toString()).put("transfer_id", id).put("direction", "mac_to_phone").put("display_name", "resume.txt").put("mime_type", "text/plain").put("size", first.size + second.size).put("sha256", sha)
        assertEquals(200, p.request("/v1/transfers", begin, pair.first).first)
        assertEquals(200, p.request("/v1/transfers/$id/chunks/0", token = pair.first, method = "PUT", bytes = first, chunkHash = ProtocolRules.hash(first)).first)
        p.restart()
        assertEquals(1, p.request("/v1/transfers/$id", token = pair.first).second.getJSONObject("data").getInt("next_index"))
        assertEquals(200, p.request("/v1/transfers/$id/chunks/1", token = pair.first, method = "PUT", bytes = second, chunkHash = ProtocolRules.hash(second)).first)
        assertEquals(200, p.request("/v1/transfers/$id/commit", JSONObject().put("request_id", UUID.randomUUID().toString()), pair.first).first)
        assertEquals("received", p.store.transfers.listLocal().getJSONObject(0).getString("status"))
        p.store.transfers.cancelLocal(id)
        assertEquals("cancelled", p.store.transfers.listLocal().getJSONObject(0).getString("status"))
    }

}

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
        fun request(path: String, body: JSONObject? = null, token: String? = null, method: String? = null, bytes: ByteArray? = null, chunkHash: String? = null, pairingSecret: String? = null): Pair<Int, JSONObject> {
            val c = PinnedTestClient.open(path)
            c.connectTimeout = 3000; c.readTimeout = 5000; c.requestMethod = method ?: if (body != null) "POST" else "GET"
            if (pairingSecret != null) c.setRequestProperty("Authorization", "Pairing $pairingSecret") else token?.let { c.setRequestProperty("Authorization", "Bearer $it") }
            chunkHash?.let { c.setRequestProperty("X-Chunk-SHA256", it) }
            if (body != null || bytes != null) { c.doOutput = true; c.outputStream.use { it.write(bytes ?: body!!.toString().toByteArray()) } }
            val status = c.responseCode; val parsed = JSONObject((if (status < 400) c.inputStream else c.errorStream).bufferedReader().use { it.readText() }); c.disconnect()
            return status to parsed
        }
        fun pair(): Pair<String, String> {
            val secret = store.startPairing(); val mac = UUID.randomUUID().toString()
            val pending = request("/v1/pair", JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret).put("mac_id", mac).put("mac_name", "Security test"))
            assertEquals(202, pending.first); val id = pending.second.getJSONObject("data").getString("pairing_id")
            store.approvePair(id); val paired = store.pollPair(id, secret)
            return paired.getString("credential") to paired.getString("trust_id")
        }
        override fun close() { server.close(); directory.deleteRecursively() }
    }
    @Test fun catalogWirePreservesUnicodeScalarsAndOmitsOversizedActivityMetadata() = Peer().use { p ->
        val trust = p.pair()
        val emoji = "\uD83D\uDE00"
        val labels = listOf("界".repeat(86), "界".repeat(256), emoji.repeat(256), "a".repeat(255) + emoji, "\u0001".repeat(256))
        val oversizedActivity = "界".repeat(171) //513UTF8 bytes; do not truncate its identity.
        val maximumActivity = emoji.repeat(128) //512UTF8 bytes.
        val records = org.json.JSONArray()
        repeat(65) { index ->
            val activity = when (index) { 0 -> oversizedActivity; 1 -> maximumActivity; 2 -> "dev.example.\uD83DInvalid"; else -> "a".repeat(512) }
            records.put(JSONObject().put("package_name", "dev.droidbridge.unicode$index")
                .put("label", ProtocolRules.catalogLabel(labels[index % labels.size]))
                .put("activity_name", activity).put("icon_sha256", JSONObject.NULL)
                .put("version_code", 1).put("launchable", true).put("export_to_mac", true))
        }
        // Isolated contract fixture exercises the production TLS/JSON route without
        // installing a test app or adding any production mutation/test endpoint.
        BridgeStore::class.java.getDeclaredField("apps").apply { isAccessible = true }.set(p.store, records)
        BridgeStore::class.java.getDeclaredField("revision").apply { isAccessible = true }.set(p.store, ProtocolRules.hash(records.toString().toByteArray(Charsets.UTF_8)))
        val response = p.request("/v1/catalog?limit=64", token = trust.first)
        assertEquals(200, response.first)
        assertTrue("Full64-row Unicode/escaped page stays under unchanged JSON cap", response.second.toString().toByteArray(Charsets.UTF_8).size <= ProtocolRules.MAX_JSON)
        val data = response.second.getJSONObject("data"); val items = data.getJSONArray("items")
        assertEquals(64, items.length())
        repeat(64) { index ->
            val actual = items.getJSONObject(index).getString("label")
            assertEquals(labels[index % labels.size], actual)
            assertTrue(actual.codePointCount(0, actual.length) <= 256)
            assertFalse(actual.codePoints().anyMatch { it in 0xD800..0xDFFF })
        }
        assertFalse(items.getJSONObject(0).has("activity_name"))
        assertEquals(maximumActivity, items.getJSONObject(1).getString("activity_name"))
        assertFalse(items.getJSONObject(2).has("activity_name"))
        assertEquals("Internal identity remains intact for icon resolution", oversizedActivity, records.getJSONObject(0).getString("activity_name"))
        val next = p.request("/v1/catalog?cursor=${data.getString("next_cursor")}&limit=64", token = trust.first)
        assertEquals(200, next.first); assertEquals(1, next.second.getJSONObject("data").getJSONArray("items").length())
        assertTrue(next.second.getJSONObject("data").isNull("next_cursor"))
        // A real delta uses the same projection and scalar contract as snapshots.
        val combining = "e\u0301".repeat(128)
        records.getJSONObject(0).put("label", ProtocolRules.catalogLabel("e\u0301".repeat(129)))
        BridgeStore::class.java.getDeclaredField("revision").apply { isAccessible = true }.set(p.store, ProtocolRules.hash(records.toString().toByteArray(Charsets.UTF_8)))
        val delta = p.request("/v1/catalog/changes?after=${data.getString("generation")}", token = trust.first)
        assertEquals(200, delta.first)
        val changed = delta.second.getJSONObject("data").getJSONArray("items")
        assertEquals(1, changed.length()); assertEquals(combining, changed.getJSONObject(0).getString("label"))
        assertFalse(changed.getJSONObject(0).has("activity_name"))
        assertEquals(oversizedActivity, records.getJSONObject(0).getString("activity_name"))
    }

    @Test fun authenticatedBroadcastCatalogHintsRespectNullableTargetsAndPeerIsolation() = Peer().use { p ->
        val a = p.pair(); val b = p.pair()
        assertEquals("null", JSONObject().put("target", JSONObject.NULL).optString("target", ""))
        val global = p.store.event("catalog_changed", JSONObject().put("revision", "synthetic-catalog"))
        p.store.event("profile_changed", JSONObject().put("profile", "balanced"))
        p.store.event("clipboard_received", JSONObject().put("event_id", UUID.randomUUID().toString()), a.second)
        p.store.event("catalog_changed", JSONObject().put("revision", "must-not-broadcast-null-string"), "null")
        p.store.event("catalog_changed", JSONObject().put("revision", "must-not-broadcast-malformed"), "not-a-trust")
        p.store.event("catalog_changed", JSONObject().put("revision", "must-not-broadcast-number"), a.second)
        @Suppress("UNCHECKED_CAST")
        val journal = BridgeStore::class.java.getDeclaredField("events").apply { isAccessible = true }.get(p.store) as ArrayDeque<JSONObject>
        journal.last().put("target_trust_id", 7) // Isolated malformed-journal fixture; never a broadcast.
        fun page(token: String) = p.request("/v1/events?after=0&wait_ms=0", token = token).also { assertEquals(200, it.first) }.second.getJSONObject("data").getJSONArray("events")
        val first = page(a.first); val second = page(b.first)
        assertEquals(3, first.length()); assertEquals(2, second.length())
        for (events in listOf(first, second)) {
            assertEquals(global, events.getJSONObject(0).getLong("sequence"))
            assertEquals("catalog_changed", events.getJSONObject(0).getString("kind"))
            assertTrue(events.getJSONObject(0).isNull("target_trust_id"))
            assertEquals("synthetic-catalog", events.getJSONObject(0).getJSONObject("payload").getString("revision"))
            assertEquals("profile_changed", events.getJSONObject(1).getString("kind"))
        }
        assertEquals(a.second, first.getJSONObject(2).getString("target_trust_id"))
        assertEquals(401, p.request("/v1/events?after=0&wait_ms=0").first)
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
        fun ping(id: String = UUID.randomUUID().toString()) = clockedCommand(p.store, JSONObject().put("request_id", id).put("kind", "ping").put("payload", JSONObject()).put("expires_at", java.time.Instant.now().plusSeconds(29).toString()), 29_000)
        val first = ping(); assertEquals(200, p.request("/v1/commands", first, a.first).first)
        assertEquals(409, p.request("/v1/commands", first, b.first).first)
        val changed = JSONObject(first.toString()).put("payload", JSONObject().put("changed", true))
        assertEquals(409, p.request("/v1/commands", changed, a.first).first)
        repeat(511) { assertEquals(200, p.request("/v1/commands", ping(), a.first).first) }
        assertEquals(429, p.request("/v1/commands", ping(), a.first).first)
        assertEquals(200, p.request("/v1/commands", first, a.first).first)
        val expired = ping().put("issued_uptime_ms", android.os.SystemClock.elapsedRealtime() - 2).put("expires_uptime_ms", android.os.SystemClock.elapsedRealtime() - 1)
        assertEquals(409, p.request("/v1/commands", expired, a.first).first)
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
        fun command(kind: String, payload: JSONObject) = clockedCommand(p.store, JSONObject().put("request_id", UUID.randomUUID().toString()).put("kind", kind).put("payload", payload).put("expires_at", java.time.Instant.now().plusSeconds(25).toString()))
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
        val admitted = JSONObject().put("request_id", id).put("status", "admitted").put("result", JSONObject())
        assertEquals(200, p.request("/v1/commands/$id/receipt", admitted, a.first).first)
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
        assertFalse("New epoch never replays queued prior-epoch work", (0 until events.getJSONArray("events").length()).map { events.getJSONArray("events").getJSONObject(it) }.any { it.getJSONObject("payload").optString("request_id") == fresh })
        assertEquals("expired", (0 until p.store.commandOutcomes().length()).map { p.store.commandOutcomes().getJSONObject(it) }.single { it.getString("request_id") == fresh }.getString("status"))
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

    @Test fun wallClockOffsetsDoNotWidenMonotonicDeadlinesOrReopenReceipts() = Peer().use { p ->
        val pair = p.pair()
        fun ping() = clockedCommand(p.store, JSONObject().put("request_id", UUID.randomUUID().toString()).put("kind", "ping").put("payload", JSONObject()))
        for (offset in listOf(-172800L, 172800L)) {
            val request = ping().put("expires_at", java.time.Instant.now().plusSeconds(offset).toString())
            assertEquals("Diagnostic wall-clock skew is irrelevant", 200, p.request("/v1/commands", request, pair.first).first)
        }
        val long = clockedCommand(p.store, ping(), 30_001)
        assertEquals(400, p.request("/v1/commands", long, pair.first).first)
        val future = ping().put("issued_uptime_ms", android.os.SystemClock.elapsedRealtime() + 5000).put("expires_uptime_ms", android.os.SystemClock.elapsedRealtime() + 10000)
        assertEquals(400, p.request("/v1/commands", future, pair.first).first)
        assertEquals(409, p.request("/v1/commands", ping().put("clock_epoch", UUID.randomUUID().toString()), pair.first).first)
        assertEquals(400, p.request("/v1/commands", ping().put("issued_uptime_ms", "123"), pair.first).first)
        val original = ping(); assertEquals(200, p.request("/v1/commands", original, pair.first).first)
        p.restart()
        assertEquals("Canonical completed receipt survives epoch change", 200, p.request("/v1/commands", original, pair.first).first)
        val rewritten = clockedCommand(p.store, JSONObject(original.toString()))
        assertEquals("New clock cannot rewrite an accepted UUID", 409, p.request("/v1/commands", rewritten, pair.first).first)
        val oldEpochNewID = JSONObject(original.toString()).put("request_id", UUID.randomUUID().toString())
        assertEquals(409, p.request("/v1/commands", oldEpochNewID, pair.first).first)
        p.store.revoke(pair.second)
        try { p.store.command(original, pair.second); fail("Revoked trust used a cached receipt") } catch (_: SecurityException) {}
    }
    @Test fun pairingApprovalRejectsMissingDismissedAndReplacedRequests() = Peer().use { p ->
        fun rejected(id: String, code: String) {
            try { p.store.approvePair(id); fail("Unavailable consent was treated as approval") }
            catch (failure: BridgeFailure) { assertEquals(code, failure.code) }
        }
        fun pending(): JSONObject {
            val secret = p.store.startPairing()
            return p.store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret)
                .put("mac_id", UUID.randomUUID().toString()).put("mac_name", "Pairing consent fixture"))
        }
        rejected(UUID.randomUUID().toString(), "pairing_unavailable")
        val dismissed = pending(); p.store.denyPair(); rejected(dismissed.getString("pairing_id"), "pairing_unavailable")
        val replaced = pending(); val current = pending(); rejected(replaced.getString("pairing_id"), "pairing_changed")
        assertEquals(0, p.store.trusted().length())
        val actual = p.store.approvePair(current.getString("pairing_id"))
        assertEquals(current.getString("pairing_id"), actual.pairingId)
        assertTrue(p.store.trusted().has(actual.trustId))
    }

    @Test fun committedSpotlightIntentRetainsPendingMaterializationAndExplicitRetry() = Peer().use { p ->
        val pair = p.pair(); p.store.refreshCatalog()
        val pkg = p.store.catalogLocal().getJSONObject(0).getString("package_name")
        val original = p.store.chooseExport(pkg, true, pair.second)
        fun receipt(status: String, result: JSONObject) = JSONObject().put("request_id", original).put("status", status).put("result", result)
        assertEquals(200, p.request("/v1/commands/$original/receipt", receipt("admitted", JSONObject()), pair.first).first)
        val result = JSONObject().put("intent_committed", true).put("materialization_pending", true).put("wrapper_created", false)
            .put("phase", "selection_saved_wrapper_pending").put("retryable", true)
        val applied = receipt("applied", result)
        assertEquals(200, p.request("/v1/commands/$original/receipt", applied, pair.first).first)
        val saved = p.store.commandOutcomes().getJSONObject(0)
        assertEquals("applied", saved.getString("status")); assertTrue(saved.getJSONObject("result").getBoolean("materialization_pending"))
        val successor = p.store.retrySpotlight(original, pair.second)
        assertNotEquals("Explicit retry has a successor UUID", original, successor)
        assertEquals(200, p.request("/v1/commands/$original/receipt", applied, pair.first).first)
        val events = p.request("/v1/events?after=0&wait_ms=0", token = pair.first).second.getJSONObject("data").getJSONArray("events")
        val commands = (0 until events.length()).map { events.getJSONObject(it) }.filter { it.getString("kind") == "command" }.map { it.getJSONObject("payload") }
        val first = commands.single { it.getString("request_id") == original }.getJSONObject("payload").getLong("selection_revision")
        val next = commands.single { it.getString("request_id") == successor }.getJSONObject("payload").getLong("selection_revision")
        assertTrue("Successor advances selection revision", next > first)
    }

    @Test fun admittedCapacityIsBoundedAndRestartRecoversWithoutReplaying() = Peer().use { p ->
        val pair = p.pair()
        val ids = (0 until 32).map {
            val id = p.store.phoneCommand("open_app", JSONObject().put("package_name", "com.android.settings"), pair.second)
            val receipt = JSONObject().put("request_id", id).put("status", "admitted").put("result", JSONObject())
            p.store.commandReceipt(id, receipt, pair.second)
            val first = p.store.commandOutcomes().let { rows -> (0 until rows.length()).map { rows.getJSONObject(it) }.single { it.getString("request_id") == id } }.getLong("admitted_uptime_ms")
            p.store.commandReceipt(id, receipt, pair.second)
            val again = p.store.commandOutcomes().let { rows -> (0 until rows.length()).map { rows.getJSONObject(it) }.single { it.getString("request_id") == id } }.getLong("admitted_uptime_ms")
            assertEquals(first, again)
            id
        }
        try { p.store.phoneCommand("open_app", JSONObject().put("package_name", "com.android.settings"), pair.second); fail("More than32 live admissions accepted") }
        catch (failure: BridgeFailure) { assertEquals("phone_command_capacity", failure.code) }
        p.restart()
        val outcomes = p.store.commandOutcomes()
        assertEquals(32, outcomes.length())
        for (i in 0 until outcomes.length()) assertEquals("unknown", outcomes.getJSONObject(i).getString("status"))
        val events = p.request("/v1/events?after=0&wait_ms=0", token = pair.first).second.getJSONObject("data").getJSONArray("events")
        assertEquals("Restart never re-emits old admitted effects", 0, events.length())
        val old = ids.last()
        try { p.store.commandReceipt(old, JSONObject().put("request_id", old).put("status", "applied").put("result", JSONObject()), pair.second); fail("Restarted unknown was overwritten") }
        catch (failure: BridgeFailure) { assertEquals("command_outcome_retired", failure.code) }
        val successor = p.store.phoneCommand("open_app", JSONObject().put("package_name", "com.android.settings"), pair.second)
        assertFalse(ids.contains(successor))
        assertEquals("Capacity returns through a new explicit UUID", 32, p.store.commandOutcomes().length())
    }

    @Test fun tlsPairPollCarriesCanonicalIDBeforeAndAfterApprovalAndRejectsReplacement() = Peer().use { p ->
        fun begin(): Pair<String, String> {
            val secret = p.store.startPairing()
            val result = p.request("/v1/pair", JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret)
                .put("mac_id", UUID.randomUUID().toString()).put("mac_name", "Wire pairing regression"))
            assertEquals(202, result.first)
            return secret to result.second.getJSONObject("data").getString("pairing_id")
        }
        val first = begin()
        val pending = p.request("/v1/pair/${first.second}", pairingSecret = first.first)
        assertEquals(200, pending.first)
        assertEquals("pending", pending.second.getJSONObject("data").getString("status"))
        assertEquals(first.second, pending.second.getJSONObject("data").getString("pairing_id"))
        assertFalse(pending.second.getJSONObject("data").has("credential"))
        assertEquals(400, p.request("/v1/pair/${UUID.randomUUID()}", pairingSecret = first.first).first)
        assertEquals(401, p.request("/v1/pair/${first.second}", pairingSecret = "A".repeat(43)).first)
        p.store.approvePair(first.second)
        val approved = p.request("/v1/pair/${first.second}", pairingSecret = first.first)
        assertEquals(200, approved.first)
        val data = approved.second.getJSONObject("data")
        assertEquals("approved", data.getString("status")); assertEquals(first.second, data.getString("pairing_id"))
        assertTrue("Approved response contains a credential without logging it", data.getString("credential").matches(Regex("[A-Za-z0-9_-]{43}")))
        val repeated = p.request("/v1/pair/${first.second}", pairingSecret = first.first).second.getJSONObject("data")
        assertEquals(first.second, repeated.getString("pairing_id"))
        assertTrue("Polling is canonical", data.getString("credential") == repeated.getString("credential"))
        val replacement = begin()
        assertEquals(400, p.request("/v1/pair/${first.second}", pairingSecret = replacement.first).first)
        assertEquals(401, p.request("/v1/pair/${first.second}", pairingSecret = first.first).first)
        val next = p.request("/v1/pair/${replacement.second}", pairingSecret = replacement.first)
        assertEquals(200, next.first); assertEquals(replacement.second, next.second.getJSONObject("data").getString("pairing_id"))
        p.store.denyPair()
        assertEquals(401, p.request("/v1/pair/${replacement.second}", pairingSecret = replacement.first).first)
        InstrumentationRegistry.getInstrumentation().addResults(android.os.Bundle().apply {
            putString("droidbridge_pair_wire_evidence", JSONObject().put("transport", "pinned_tls_http")
                .put("pending_status", pending.first).put("approved_status", approved.first)
                .put("pending_id_matched", true).put("approved_id_matched", true).put("repeat_id_matched", true)
                .put("invalid_id_rejected", true).put("replaced_id_rejected", true).put("denied_poll_rejected", true)
                .put("pending_fields", org.json.JSONArray(pending.second.getJSONObject("data").keys().asSequence().sorted().toList()))
                .put("approved_fields", org.json.JSONArray(data.keys().asSequence().sorted().toList())).toString())
        })
    }

    @Test fun notificationScopeIsCanonicalAndCannotReplayAcrossReplacementTrust() = Peer().use { p ->
        p.store.setting("notifications_enabled", true, Unit)
        val a = p.pair(); val b = p.pair()
        fun command(kind: String, payload: JSONObject) = clockedCommand(p.store, JSONObject().put("request_id", UUID.randomUUID().toString()).put("kind", kind).put("payload", payload))
        fun pref(expected: String) = JSONObject().put("expected_trust_id", expected).put("enabled", true).put("packages", org.json.JSONArray())
        val original = command("notification_preferences", pref(a.second))
        assertEquals(200, p.request("/v1/commands", original, a.first).first)
        assertEquals(200, p.request("/v1/commands", original, a.first).first)
        for (kind in listOf("notification_preferences", "notification_reply", "dismiss_notification")) {
            val payload = if (kind == "notification_preferences") pref(a.second) else JSONObject().put("expected_trust_id", a.second).put("notification_key", "0".repeat(64)).put("action_id", UUID.randomUUID().toString()).put("text", "Synthetic test")
            for (modified in listOf(JSONObject(payload.toString()).apply { remove("expected_trust_id") }, JSONObject(payload.toString()).put("expected_trust_id", b.second), JSONObject(payload.toString()).put("expected_trust_id", a.second.uppercase()))) {
                val response = p.request("/v1/commands", command(kind, modified), a.first)
                assertEquals(409, response.first); assertEquals("trust_changed", response.second.getJSONObject("error").getString("code"))
            }
        }
        assertFalse("Mismatched preference never enabled another trust", p.store.notificationsAllowed(b.second))
        val cross = p.request("/v1/commands", original, b.first)
        assertEquals(409, cross.first); assertEquals("trust_changed", cross.second.getJSONObject("error").getString("code"))
        val rewritten = JSONObject(original.toString()).put("payload", pref(b.second))
        assertEquals("A new trust cannot reuse a prior trust's request UUID", 409, p.request("/v1/commands", rewritten, b.first).first)
        val mac = p.store.trusted().getJSONObject(a.second).getString("mac_id")
        p.store.revoke(a.second)
        val secret = p.store.startPairing()
        val pending = p.store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret).put("mac_id", mac).put("mac_name", "Replacement trust regression"))
        val replacementId = p.store.approvePair(pending.getString("pairing_id")).trustId
        val replacementToken = p.store.pollPair(pending.getString("pairing_id"), secret).getString("credential")
        assertNotEquals(a.second, replacementId)
        val afterReplacement = p.request("/v1/commands", original, replacementToken)
        assertEquals(409, afterReplacement.first); assertEquals("trust_changed", afterReplacement.second.getJSONObject("error").getString("code"))
        assertFalse(p.store.notificationsAllowed(replacementId))
        assertEquals(200, p.request("/v1/commands", command("notification_preferences", pref(replacementId)), replacementToken).first)
        assertTrue(p.store.notificationsAllowed(replacementId))
    }

    @Test fun notificationExposureEvictionCleansOnlyPriorAudienceAndLongPollCannotDeadlock() = Peer().use { p ->
        p.store.setting("notifications_enabled", true, Unit)
        val a = p.pair(); val b = p.pair(); p.store.allowNotifications(a.second, true)
        val pkg = "dev.droidbridge.synthetic"
        val firstKey = ProtocolRules.hash("notification-0".toByteArray())
        val unobserved = ProtocolRules.hash("never-selected".toByteArray())
        p.store.publishNotification(unobserved, pkg, JSONObject().put("notification_key", unobserved).put("package_name", pkg).put("action_id", UUID.randomUUID().toString()).put("title", "Synthetic never selected"))
        p.store.publishNotification(unobserved, pkg, null)
        p.store.publishNotification(ProtocolRules.hash("framework-excluded".toByteArray()), "android", null) // Valid internal sender must never crash excluded cleanup.
        assertEquals("Queued-but-never-observed public replacement leaks no cleanup existence", 0, p.request("/v1/events?after=0&wait_ms=0", token = a.first).second.getJSONObject("data").getJSONArray("events").length())
        for (index in 0..256) {
            val key = ProtocolRules.hash("notification-$index".toByteArray())
            p.store.publishNotification(key, pkg, JSONObject().put("notification_key", key).put("package_name", pkg).put("action_id", UUID.randomUUID().toString()).put("title", "Synthetic public").put("text", "Synthetic public"))
            // A removal is disclosed only for a row actually selected into a TLS response.
            if (index == 0) assertEquals(200, p.request("/v1/events?after=0&wait_ms=0", token = a.first).first)
        }
        fun pages(peer: Pair<String, String>): Pair<List<JSONObject>, Long> {
            val all = mutableListOf<JSONObject>(); var after = 0L
            repeat(16) {
                val result = p.request("/v1/events?after=$after&wait_ms=0", token = peer.first)
                assertEquals(200, result.first)
                val data = result.second.getJSONObject("data"); val next = data.getLong("next_sequence"); val items = data.getJSONArray("events")
                for (i in 0 until items.length()) all.add(items.getJSONObject(i))
                if (next == after) return all to next
                after = next
            }
            fail("Bounded notification event paging did not converge"); return all to after
        }
        val aEvents = pages(a).first
        assertTrue("Eviction sends metadata-only cleanup before forgetting old audience", aEvents.any { it.getString("kind") == "notification_removed" && it.getJSONObject("payload").optString("notification_key") == firstKey && it.getJSONObject("payload").keys().asSequence().toSet() == setOf("notification_key") })
        assertFalse("Evicted old content is not replayed", aEvents.any { it.getString("kind") == "notification_posted" && it.getJSONObject("payload").optString("notification_key") == firstKey })
        assertTrue("Never opted-in trust sees no notification existence", pages(b).first.isEmpty())
        val after = pages(a).second
        val result = java.util.concurrent.atomic.AtomicInteger()
        val poll = Thread { result.set(p.request("/v1/events?after=$after&wait_ms=2000", token = a.first).first) }.apply { start() }
        Thread.sleep(100); p.store.allowNotifications(a.second, false)
        poll.join(3500); assertFalse("Store/event lock order never blocks publisher behind waiting poll", poll.isAlive); assertEquals(200, result.get())
        val cleanup = pages(a).first
        assertTrue(cleanup.isNotEmpty())
        assertTrue("Opt-out allows only key-only prior-audience cleanup", cleanup.all { it.getString("kind") == "notification_removed" && it.getJSONObject("payload").keys().asSequence().toSet() == setOf("notification_key") })
        assertTrue(pages(b).first.isEmpty())
        // Exercise the full256×8 reconciliation matrix. A reconstructed isolated
        // peer models process restart without altering device clocks or rate limits.
        val peers = mutableListOf(a, b)
        repeat(3) { peers.add(p.pair()) }
        p.restart()
        repeat(3) { peers.add(p.pair()) }
        peers.forEach { p.store.allowNotifications(it.second, true) }
        for (index in 0 until 256) {
            val key = ProtocolRules.hash("matrix-$index".toByteArray())
            p.store.publishNotification(key, pkg, JSONObject().put("notification_key", key).put("package_name", pkg).put("action_id", UUID.randomUUID().toString()).put("title", "Synthetic matrix").put("text", "Synthetic matrix"))
            if (index % 64 == 63) peers.forEach { pages(it) } // Each admitted generation really crosses TLS.
        }
        val started = android.os.SystemClock.elapsedRealtime()
        p.store.setting("notifications_enabled", false, Unit)
        val elapsed = android.os.SystemClock.elapsedRealtime() - started
        assertTrue("256×8 callback reconciliation stays below3s", elapsed < 3000)
        val page = p.request("/v1/events?after=0&wait_ms=0", token = a.first).second.getJSONObject("data")
        assertTrue("Bounded journal reports a gap rather than silently stranding old rows", page.getBoolean("reset_required"))
        val retained = page.getJSONArray("events")
        for (i in 0 until retained.length()) {
            assertEquals("notification_removed", retained.getJSONObject(i).getString("kind"))
            assertEquals(setOf("notification_key"), retained.getJSONObject(i).getJSONObject("payload").keys().asSequence().toSet())
        }
        InstrumentationRegistry.getInstrumentation().addResults(android.os.Bundle().apply { putString("droidbridge_notification_matrix", JSONObject().put("keys", 256).put("trusts", 8).put("reconcile_ms", elapsed).put("threshold_ms", 3000).put("overflow_cleanup", true).put("journal_gap_explicit", true).toString()) })
    }

}

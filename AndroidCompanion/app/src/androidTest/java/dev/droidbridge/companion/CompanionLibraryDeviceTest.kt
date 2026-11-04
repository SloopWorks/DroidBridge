package dev.droidbridge.companion

import android.content.Context
import android.content.ContextWrapper
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class CompanionLibraryDeviceTest {
    private class Fixture : AutoCloseable {
        private val target = InstrumentationRegistry.getInstrumentation().targetContext
        private val prefix = "library-${UUID.randomUUID()}"
        private val directory = File(target.cacheDir, prefix).apply { mkdirs() }
        val context = object : ContextWrapper(target) {
            override fun getFilesDir() = directory
            override fun getSharedPreferences(name: String, mode: Int) = target.getSharedPreferences(prefix + name, mode)
        }
        fun store() = BridgeStore::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }.newInstance(context)
        fun trust(store: BridgeStore): String {
            val secret = store.startPairing()
            val request = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("mac_id", UUID.randomUUID().toString())
                .put("mac_name", "Library test Mac").put("pairing_secret", secret))
            return store.approvePair(request.getString("pairing_id")).trustId.also { store.denyPair() }
        }
        override fun close() { directory.deleteRecursively() }
    }
    @Test fun savedSnippetsAreEncryptedBoundedAndSurviveRestartWithoutClipboardAccess() = Fixture().use { fixture ->
        val store = fixture.store(); val marker = "explicit synthetic saved snippet ${UUID.randomUUID()}"
        val id = store.saveSnippet(marker).getString("id"); store.pinSnippet(id, true)
        assertTrue(store.snippets().getJSONObject(0).getBoolean("pinned"))
        val bytes = File(fixture.context.filesDir, "saved-library.enc").readBytes()
        assertFalse(bytes.toString(Charsets.ISO_8859_1).contains(marker))
        val restarted = fixture.store()
        assertEquals(marker, restarted.snippets().getJSONObject(0).getString("text"))
        repeat(63) { restarted.saveSnippet("bounded snippet $it") }
        assertTrue(runCatching { restarted.saveSnippet("overflow") }.isFailure)
        assertEquals(64, restarted.snippets().length())
        restarted.deleteSnippet(id)
        assertEquals(63, fixture.store().snippets().length())
    }
    @Test fun presetRunPinsItsOriginalTrustAndPartialReceiptRetainsTimings() = Fixture().use { fixture ->
        val store = fixture.store(); val recipient = fixture.trust(store); val other = fixture.trust(store)
        val preset = store.savePreset("Desk", listOf("com.android.settings"), recipient, "phone", "balanced", false)
        store.selectTrust(other); store.running = true
        store.updatePeerState(recipient, JSONObject().put("sessions", JSONArray()).put("connection_state", "connected"))
        val id = store.runPreset(preset.getString("id")).getString(0)
        assertEquals(other, store.selectedTrust())
        val queued = store.commandOutcomes().getJSONObject(0)
        assertEquals(recipient, queued.getString("trust_id")); assertEquals("run_preset", queued.getString("kind"))
        store.commandReceipt(id, JSONObject().put("request_id", id).put("status", "admitted"), recipient)
        val beforeMalformed = store.commandOutcomes().toString()
        assertTrue(runCatching { store.commandReceipt(id, JSONObject().put("request_id", id).put("status", "applied")
            .put("result", JSONObject().put("completed_steps", 12)), recipient) }.isFailure)
        assertEquals("Malformed receipts cannot mutate even in-memory timing", beforeMalformed, store.commandOutcomes().toString())
        val terminal = JSONObject().put("request_id", id).put("status", "applied").put("result", JSONObject().put("phase", "preset_partial").put("completed_steps", 2).put("failed_step", "app").put("code", "launch_failed"))
        store.commandReceipt(id, terminal, recipient)
        val result = store.commandOutcomes().getJSONObject(0)
        assertEquals("preset_partial", result.getJSONObject("result").getString("phase"))
        assertEquals(2, result.getJSONObject("result").getInt("completed_steps"))
        assertTrue(result.getJSONObject("timing").getLong("completed_ms") >= result.getJSONObject("timing").getLong("acknowledged_ms"))
        store.commandReceipt(id, terminal, recipient)
        assertEquals(1, store.commandOutcomes().length())
        store.revoke(recipient)
        assertTrue(runCatching { store.runPreset(preset.getString("id")) }.isFailure)
    }
    @Test fun shareActionsRequireExplicitPermissionAndRejectExecutableUrls() = Fixture().use { fixture ->
        val store = fixture.store(); val recipient = fixture.trust(store)
        assertTrue(runCatching { store.phoneCommand("share_text", JSONObject().put("text", "hello").put("action", "copy"), recipient) }.isFailure)
        store.setting("clipboard_enabled", true, Unit)
        assertTrue(runCatching { store.phoneCommand("share_text", JSONObject().put("text", "hello").put("action", "execute"), recipient) }.isFailure)
        assertTrue(runCatching { store.phoneCommand("share_url", JSONObject().put("text", "file:///data/local/tmp/x").put("action", "open"), recipient) }.isFailure)
        store.phoneCommand("share_url", JSONObject().put("text", "https://example.com").put("action", "open"), recipient)
        assertEquals(1, store.commandOutcomes().length())
    }
    @Test fun onlyCompleteVerifiedInboundFilesMayBeSharedAndCancellationRevokesAccess() = Fixture().use { fixture ->
        val store = fixture.store(); val recipient = fixture.trust(store)
        val bytes = "synthetic received file".toByteArray(); val id = UUID.randomUUID().toString()
        store.transfers.begin(recipient, JSONObject().put("transfer_id", id).put("direction", "mac_to_phone").put("display_name", "example.txt")
            .put("mime_type", "text/plain").put("size", bytes.size).put("sha256", ProtocolRules.hash(bytes)))
        assertTrue(runCatching { store.transfers.shareUri(id) }.isFailure)
        store.transfers.put(id, recipient, 0, ProtocolRules.hash(bytes), bytes)
        store.transfers.commit(id, recipient)
        assertEquals("${fixture.context.packageName}.transfers", store.transfers.shareUri(id).authority)
        assertEquals("example.txt", store.transfers.sharedMetadata(id).getString("display_name"))
        assertArrayEquals(bytes, store.transfers.sharedFile(id).readBytes())
        store.transfers.cancelLocal(id)
        assertTrue(runCatching { store.transfers.shareUri(id) }.isFailure)
    }
}

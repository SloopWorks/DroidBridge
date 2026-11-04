package dev.droidbridge.companion

import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test

/** Requires an actual installed, separately paired Mac in the explicit emulator QA scope. */
class CompanionDesktopE2EDeviceTest {
    @Test fun cleanupOwnedPairing() {
        val args = InstrumentationRegistry.getArguments()
        assumeTrue("Only the exact owned installed-flow pairing", args.getString("real_desktop") == "1" && args.getString("cleanup_pairing") == "1")
        val trust = args.getString("e2e_trust") ?: throw AssertionError("Exact trust required")
        val store = BridgeStore.get(InstrumentationRegistry.getInstrumentation().targetContext)
        if (store.trusted().has(trust)) store.revoke(trust)
        assertFalse(store.trusted().has(trust))
    }
    @Test fun actualMacAppliesPhoneCommandsAndDesktopPreset() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val args = InstrumentationRegistry.getArguments()
        assumeTrue("Run only with the coordinated installed Mac", args.getString("real_desktop") == "1")
        val store = BridgeStore.get(instrumentation.targetContext)
        val trust = args.getString("e2e_trust") ?: throw AssertionError("Exact paired trust is required")
        assertTrue(store.trusted().has(trust))
        // Instrumentation may restart the target process. Re-establish the
        // explicit foreground service, retaining the real persisted pairing.
        val activity = instrumentation.startActivitySync(android.content.Intent(instrumentation.targetContext, MainActivity::class.java).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
        instrumentation.runOnMainSync { instrumentation.targetContext.startForegroundService(android.content.Intent(instrumentation.targetContext, BridgeService::class.java)) }
        val connectedDeadline = SystemClock.elapsedRealtime() + 45000
        while ((!store.running || !store.peerStatus(trust).getBoolean("connected")) && SystemClock.elapsedRealtime() < connectedDeadline) Thread.sleep(100)
        assertTrue("The actual paired Mac reconnects after instrumentation restart", store.peerStatus(trust).getBoolean("connected"))
        val previousSharing = store.setting("clipboard_enabled")
        val evidence = JSONArray()
        fun await(id: String): JSONObject {
            val deadline = SystemClock.elapsedRealtime() + 45000
            while (SystemClock.elapsedRealtime() < deadline) {
                val rows = store.commandOutcomes()
                val row = (0 until rows.length()).map { rows.getJSONObject(it) }.first { it.getString("request_id") == id }
                if (row.getString("status") !in listOf("queued", "accepted", "admitted")) {
                    evidence.put(JSONObject().put("kind", row.getString("kind")).put("status", row.getString("status"))
                        .put("result", row.optJSONObject("result") ?: JSONObject()).put("timing", row.optJSONObject("timing") ?: JSONObject()))
                    assertEquals("Actual Mac receipt: ${row.optString("error_code")}", "applied", row.getString("status"))
                    return row
                }
                Thread.sleep(80)
            }
            throw AssertionError("Actual Mac did not publish a terminal command receipt")
        }
        var preset: String? = null
        try {
            store.setting("clipboard_enabled", true, Unit)
            await(store.phoneCommand("set_profile", JSONObject().put("profile", "balanced"), trust))
            assertEquals("balanced", store.status().getString("profile"))
            val copy = await(store.phoneCommand("share_text", JSONObject().put("text", "DroidBridge explicit E2E clipboard probe").put("action", "copy"), trust))
            assertEquals("copied_on_mac", copy.getJSONObject("result").getString("phase"))
            val url = args.getString("e2e_url") ?: throw AssertionError("Owned loopback URL required")
            assertTrue(url.startsWith("http://127.0.0.1:"))
            val opened = await(store.phoneCommand("share_url", JSONObject().put("text", url).put("action", "open"), trust))
            assertEquals("opened_on_mac", opened.getJSONObject("result").getString("phase"))
            val value = store.savePreset("Installed E2E desk", listOf("dev.droidbridge.companionfixture"), trust, "phone", "balanced", false)
            preset = value.getString("id")
            val result = await(store.runPreset(preset).getString(0)).getJSONObject("result")
            assertEquals("preset_completed", result.getString("phase")); assertEquals(3, result.getInt("completed_steps"))
        } finally {
            preset?.let(store::deletePreset)
            store.setting("clipboard_enabled", previousSharing, Unit)
            val directory = java.io.File(instrumentation.targetContext.getExternalFilesDir(null), "verification").apply { mkdirs() }
            java.io.File(directory, "desktop-e2e.json").writeText(JSONObject().put("scope", "Actual phone command through pinned TLS, broker owner admission and installed Mac effects").put("actions", evidence).toString(2))
            instrumentation.runOnMainSync { activity.finish() }
        }
    }
}

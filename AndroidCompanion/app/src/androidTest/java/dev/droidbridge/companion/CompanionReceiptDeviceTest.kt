package dev.droidbridge.companion

import android.app.Activity
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Native UI reports committed routing intent separately from unconfirmed output. */
class CompanionReceiptDeviceTest {
    @Test fun savedAudioPreferenceNeverClaimsUnconfirmedOutputCompleted() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val store = BridgeStore.get(instrumentation.targetContext)
        val originals = store.trusted().keys().asSequence().toSet()
        val selected = store.selectedTrust()
        val secret = store.startPairing()
        val pair = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret)
            .put("mac_id", UUID.randomUUID().toString()).put("mac_name", "Audio receipt regression Mac"))
        val temporary = store.approvePair(pair.getString("pairing_id")).trustId
        store.denyPair(); store.selectTrust(temporary)
        val request = store.phoneCommand("set_audio_route", JSONObject().put("route", "mac"), temporary)
        store.commandReceipt(request, JSONObject().put("request_id", request).put("status", "applied")
            .put("result", JSONObject().put("route", "mac").put("phase", "output_not_confirmed")
                .put("intent_committed", true).put("output_confirmed", false)), temporary)
        val saved = store.commandOutcomes().let { rows -> (0 until rows.length()).map { rows.getJSONObject(it) }.single { it.getString("request_id") == request } }
        assertTrue(saved.getJSONObject("result").has("output_confirmed"))
        assertFalse(saved.getJSONObject("result").getBoolean("output_confirmed"))
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as Activity
        fun nodes(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { nodes(view.getChildAt(it)) } else emptyList()
        try {
            val deadline = SystemClock.elapsedRealtime() + 6000
            var found = false
            while (!found && SystemClock.elapsedRealtime() < deadline) {
                instrumentation.waitForIdleSync()
                instrumentation.runOnMainSync {
                    val labels = nodes(activity.window.decorView).filterIsInstance<TextView>().map { it.text.toString() }
                    found = labels.any { it.contains("set audio route · Audio preference saved; output unconfirmed") }
                    assertFalse("Audio receipt does not falsely claim completed output", labels.any { it.contains("set audio route · Completed") })
                }
                if (!found) Thread.sleep(40)
            }
            assertTrue("Native recent-actions receipt explains unconfirmed output", found)
        } finally {
            instrumentation.runOnMainSync { activity.finish() }
            store.revoke(temporary); selected?.let { store.selectTrust(it) }
            assertEquals(originals, store.trusted().keys().asSequence().toSet())
            assertEquals(selected, store.selectedTrust())
        }
    }
    @Test fun expiredAndUnknownReceiptsRequireMacInspectionWithoutAutomaticResubmission() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val store = BridgeStore.get(instrumentation.targetContext)
        val originals = store.trusted().keys().asSequence().toSet(); val selected = store.selectedTrust()
        val secret = store.startPairing()
        val pair = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret)
            .put("mac_id", UUID.randomUUID().toString()).put("mac_name", "Uncertain receipt regression Mac"))
        val temporary = store.approvePair(pair.getString("pairing_id")).trustId
        store.denyPair(); store.selectTrust(temporary)
        val expired = store.phoneCommand("open_app", JSONObject().put("package_name", "com.android.settings"), temporary)
        val unknown = store.phoneCommand("set_profile", JSONObject().put("profile", "balanced"), temporary)
        store.commandReceipt(unknown, JSONObject().put("request_id", unknown).put("status", "unknown").put("result", JSONObject()), temporary)
        val started = SystemClock.elapsedRealtime()
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as Activity
        fun nodes(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { nodes(view.getChildAt(it)) } else emptyList()
        try {
            var found = false
            while (!found && SystemClock.elapsedRealtime() - started < 38_000) {
                instrumentation.waitForIdleSync()
                instrumentation.runOnMainSync {
                    val labels = nodes(activity.window.decorView).filterIsInstance<TextView>().map { it.text.toString() }
                    found = labels.any { it.contains("open app · Expired · check Mac outcome before retry") } &&
                        labels.any { it.contains("set profile · Outcome not confirmed · check Mac before repeating") }
                    assertFalse("Uncertain receipt never advises a blind replay", labels.any { it.contains("try original action again", true) || it.contains("expiry before trying again", true) })
                }
                if (!found) Thread.sleep(100)
            }
            assertTrue("Expired and unknown outcomes require Mac inspection in actual native views", found)
            val rows = store.commandOutcomes()
            val actual = (0 until rows.length()).map { rows.getJSONObject(it) }.filter { it.optString("trust_id") == temporary }
            assertEquals("UI polling never admits successor requests", setOf(expired, unknown), actual.map { it.getString("request_id") }.toSet())
            assertEquals("expired", actual.single { it.getString("request_id") == expired }.getString("status"))
            assertEquals("unknown", actual.single { it.getString("request_id") == unknown }.getString("status"))
            instrumentation.addResults(android.os.Bundle().apply { putString("droidbridge_uncertain_receipt_ui", JSONObject().put("elapsed_ms", SystemClock.elapsedRealtime() - started)
                .put("real_30s_expiry", true).put("expired_requires_mac_check", true).put("unknown_requires_mac_check", true).put("automatic_successors", 0).toString()) })
        } finally {
            instrumentation.runOnMainSync { activity.finish() }
            store.revoke(temporary); selected?.let { store.selectTrust(it) }
            assertEquals(originals, store.trusted().keys().asSequence().toSet()); assertEquals(selected, store.selectedTrust())
        }
    }

}

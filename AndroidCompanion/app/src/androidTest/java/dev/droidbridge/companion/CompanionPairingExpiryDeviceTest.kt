package dev.droidbridge.companion

import android.app.AlertDialog
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

/** Real120-second expiry, with no clock changes or production deadline hook. */
class CompanionPairingExpiryDeviceTest {
    @Test fun lateTrustTapNeverApprovesAndAdmittedCompletionRemainsTruthful() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val store = BridgeStore.get(instrumentation.targetContext)
        val originals = store.trusted().keys().asSequence().toSet()
        fun pending(name: String): Pair<String, JSONObject> {
            val secret = store.startPairing()
            return secret to store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret)
                .put("mac_id", UUID.randomUUID().toString()).put("mac_name", name))
        }
        val setup = pending("Expiry receipt fixture")
        val temporary = store.approvePair(setup.second.getString("pairing_id")).trustId
        store.denyPair()
        val admittedID = store.phoneCommand("open_app", JSONObject().put("package_name", "com.android.settings"), temporary)
        val queuedID = store.phoneCommand("open_app", JSONObject().put("package_name", "com.android.settings"), temporary)
        store.commandReceipt(admittedID, JSONObject().put("request_id", admittedID).put("status", "admitted").put("result", JSONObject()), temporary)
        val pair = pending("Expired approval fixture")
        val started = SystemClock.elapsedRealtime()
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
        fun nodes(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { nodes(view.getChildAt(it)) } else emptyList()
        try {
            val dialogDeadline = SystemClock.elapsedRealtime() + 5000
            var dialog: AlertDialog? = null
            while (dialog == null && SystemClock.elapsedRealtime() < dialogDeadline) {
                main { dialog = activity.activeDialog }; Thread.sleep(40)
            }
            assertNotNull("Actual pending trust dialog is visible", dialog)
            fun outcome(id: String): JSONObject {
                val rows = store.commandOutcomes()
                return (0 until rows.length()).map { rows.getJSONObject(it) }.single { it.getString("request_id") == id }
            }
            val firstAdmission = outcome(admittedID).getLong("admitted_uptime_ms")
            while (SystemClock.elapsedRealtime() < started + 60_000) Thread.sleep(250)
            store.commandReceipt(admittedID, JSONObject().put("request_id", admittedID).put("status", "admitted").put("result", JSONObject()), temporary)
            assertEquals("Duplicate admission never refreshes the deadline", firstAdmission, outcome(admittedID).getLong("admitted_uptime_ms"))
            val lateID = store.phoneCommand("open_app", JSONObject().put("package_name", "com.android.settings"), temporary)
            store.commandReceipt(lateID, JSONObject().put("request_id", lateID).put("status", "admitted").put("result", JSONObject()), temporary)
            val until = pair.second.getLong("expires_uptime_ms") + 250
            while (SystemClock.elapsedRealtime() < until) Thread.sleep(minOf(1000L, until - SystemClock.elapsedRealtime()).coerceAtLeast(1))
            main { dialog!!.getButton(AlertDialog.BUTTON_POSITIVE).performClick() }
            val feedbackDeadline = SystemClock.elapsedRealtime() + 5000
            var reported = false
            while (!reported && SystemClock.elapsedRealtime() < feedbackDeadline) {
                instrumentation.waitForIdleSync()
                main { val text = nodes(activity.window.decorView).filterIsInstance<TextView>().joinToString("\n") { it.text.toString() }; reported = text.contains("Pairing expired or failed") && !text.contains("Mac approved.") }
                if (!reported) Thread.sleep(40)
            }
            assertTrue("Late Trust tap reports failure, never approval", reported)
            assertEquals("Late tap created no trust", originals + temporary, store.trusted().keys().asSequence().toSet())
            assertEquals("Unresolved first admission retires after120s", "unknown", outcome(admittedID).getString("status"))
            try { store.commandReceipt(admittedID, JSONObject().put("request_id", admittedID).put("status", "applied").put("result", JSONObject()), temporary); fail("Late terminal overwrote retired unknown") }
            catch (failure: BridgeFailure) { assertEquals("command_outcome_retired", failure.code) }
            assertEquals("unknown", outcome(admittedID).getString("status"))
            assertEquals("Within120s admission remains in flight beyond30s command TTL", "admitted", outcome(lateID).getString("status"))
            val applied = JSONObject().put("request_id", lateID).put("status", "applied").put("result", JSONObject().put("state", "synthetic_completion"))
            store.commandReceipt(lateID, applied, temporary)
            assertEquals("applied", outcome(lateID).getString("status"))
            assertEquals("applied", store.commandReceipt(lateID, applied, temporary).getString("status"))
            try { store.commandReceipt(queuedID, JSONObject().put("request_id", queuedID).put("status", "admitted").put("result", JSONObject()), temporary); fail("Expired queued command admitted") }
            catch (failure: BridgeFailure) { assertEquals("phone_command_expired", failure.code) }
            assertEquals("expired", outcome(queuedID).getString("status"))
            instrumentation.addResults(android.os.Bundle().apply { putString("droidbridge_real_pair_expiry", JSONObject().put("elapsed_ms", SystemClock.elapsedRealtime() - started).put("late_tap_approved", false).put("admitted_late_completion", "applied").put("retired_admission", "unknown").put("duplicate_admission_refreshed", false).put("unadmitted_expiry", "expired").toString()) })
        } finally {
            main { activity.finish() }
            store.denyPair(); store.revoke(temporary)
            assertEquals(originals, store.trusted().keys().asSequence().toSet())
        }
    }
}

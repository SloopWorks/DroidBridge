package dev.droidbridge.companion

import android.app.Activity
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Entry point -> foreground consent -> durable exact-trust command, without remote side effects. */
class QuickAccessDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun nodes(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { nodes(view.getChildAt(it)) } else emptyList()
    private fun trust(store: BridgeStore, label: String): String {
        val secret = store.startPairing()
        val pair = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret).put("mac_id", UUID.randomUUID().toString()).put("mac_name", label))
        return store.approvePair(pair.getString("pairing_id")).trustId.also { store.denyPair() }
    }
    private fun waitFor(condition: () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + 6000
        while (SystemClock.elapsedRealtime() < until) { instrumentation.waitForIdleSync(); if (condition()) return; Thread.sleep(40) }
        assertTrue("Condition did not become true", condition())
    }
    @Test fun selectedTextOnlyEnqueuesAfterForegroundReviewAndTargetsChosenTrust() {
        val context = instrumentation.targetContext; val store = BridgeStore.get(context)
        val previous = store.selectedTrust(); val running = store.running; val sharing = store.setting("clipboard_enabled")
        store.setting("clipboard_enabled", true, Unit)
        val recipient = trust(store, "Quick access test Mac")
        store.selectTrust(recipient); store.running = true
        store.updatePeerState(recipient, JSONObject().put("connection_state", "connected"))
        fun requests() = store.commandOutcomes().let { items -> (0 until items.length()).map { items.getJSONObject(it) }.filter { it.optString("trust_id") == recipient } }
        val before = requests().size
        val activity = instrumentation.startActivitySync(Intent(context, QuickAccessActivity::class.java).setAction(Intent.ACTION_PROCESS_TEXT)
            .setType("text/plain").putExtra(Intent.EXTRA_PROCESS_TEXT, "Explicit selected text fixture").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as Activity
        try {
            waitFor { var ready = false; instrumentation.runOnMainSync { ready = nodes(activity.window.decorView).filterIsInstance<Button>().any { it.text.toString() == "Send selected text to Quick access test Mac" && it.isEnabled } }; ready }
            assertEquals("Opening exported process-text activity never sends", before, requests().size)
            instrumentation.runOnMainSync { nodes(activity.window.decorView).filterIsInstance<Button>().single { it.text.toString() == "Send selected text to Quick access test Mac" }.performClick() }
            instrumentation.waitForIdleSync()
            assertEquals("Preview is not consent", before, requests().size)
            // Confirm using Android's input accessibility rather than reaching into implementation fields.
            waitFor {
                val root = instrumentation.uiAutomation.rootInActiveWindow
                val send = root?.findAccessibilityNodeInfosByText("Send")?.firstOrNull { it.isClickable && it.text?.toString()?.equals("Send", ignoreCase = true) == true }
                send?.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLICK) == true
            }
            waitFor { requests().size == before + 1 }
            val receipt = requests().last()
            assertEquals(recipient, receipt.getString("trust_id")); assertEquals("share_text", receipt.getString("kind"))
            val id = receipt.getString("request_id")
            store.commandReceipt(id, JSONObject().put("request_id", id).put("status", "unknown").put("result", JSONObject()), recipient)
            waitFor { var visible = false; instrumentation.runOnMainSync { visible = nodes(activity.window.decorView).filterIsInstance<TextView>().any { it.text.toString().contains("Outcome unknown · check Mac before repeating") } }; visible }
            assertEquals("Unknown effect never causes automatic replay", before + 1, requests().size)
        } finally { instrumentation.runOnMainSync { activity.finish() }; store.running = running; store.setting("clipboard_enabled", sharing, Unit); store.revoke(recipient); previous?.let { store.selectTrust(it) } }
    }
    @Test fun destroyedReviewCannotSubmitThroughRetainedNativeConfirmationCallback() {
        val context = instrumentation.targetContext; val store = BridgeStore.get(context)
        val previous = store.selectedTrust(); val running = store.running; val sharing = store.setting("clipboard_enabled")
        val recipient = trust(store, "Destroyed review test Mac")
        store.selectTrust(recipient); store.running = true; store.setting("clipboard_enabled", true, Unit)
        store.updatePeerState(recipient, JSONObject().put("connection_state", "connected"))
        val activity = instrumentation.startActivitySync(Intent(context, QuickAccessActivity::class.java).setAction(Intent.ACTION_PROCESS_TEXT)
            .setType("text/plain").putExtra(Intent.EXTRA_PROCESS_TEXT, "Never send a destroyed confirmation").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as Activity
        try {
            waitFor { var ready = false; instrumentation.runOnMainSync { ready = nodes(activity.window.decorView).filterIsInstance<Button>().any { it.text.toString() == "Send selected text to Destroyed review test Mac" && it.isEnabled } }; ready }
            lateinit var dialog: android.app.AlertDialog
            lateinit var lateButton: Button
            instrumentation.runOnMainSync {
                nodes(activity.window.decorView).filterIsInstance<Button>().single { it.text.toString() == "Send selected text to Destroyed review test Mac" }.performClick()
                // Own-app field only: retain the actual native callback to simulate a late queued touch.
                val field = QuickAccessActivity::class.java.getDeclaredField("reviewDialog").apply { isAccessible = true }
                dialog = field.get(activity) as android.app.AlertDialog
                lateButton = dialog.getButton(android.app.AlertDialog.BUTTON_POSITIVE)
                activity.finish()
            }
            waitFor { var destroyed = false; instrumentation.runOnMainSync { destroyed = activity.isDestroyed }; destroyed }
            instrumentation.runOnMainSync { assertFalse("Review window dismissed on terminal activity", dialog.isShowing); lateButton.performClick() }
            instrumentation.waitForIdleSync()
            val requests = store.commandOutcomes().let { rows -> (0 until rows.length()).map { rows.getJSONObject(it) }.filter { it.optString("trust_id") == recipient } }
            assertTrue("A destroyed confirmation cannot admit an effect or hit its closed executor", requests.isEmpty())
        } finally {
            instrumentation.runOnMainSync { activity.finish() }
            store.running = running; store.setting("clipboard_enabled", sharing, Unit); store.revoke(recipient); previous?.let { store.selectTrust(it) }
        }
    }
    @Test fun systemEntryPointsProtectPrivilegedTileBindingAndWidgetReceiver() {
        val context = instrumentation.targetContext
        for (tile in listOf(ConnectionTileService::class.java, OperationsTileService::class.java)) {
            val info = context.packageManager.getServiceInfo(android.content.ComponentName(context, tile), 0)
            assertEquals("android.permission.BIND_QUICK_SETTINGS_TILE", info.permission)
            assertTrue(info.exported)
        }
        val widget = context.packageManager.getReceiverInfo(android.content.ComponentName(context, BridgeWidget::class.java), 0)
        assertFalse(widget.exported)
        val first = QuickAccess.appIntent(context, UUID.randomUUID().toString(), "com.android.settings")
        val second = QuickAccess.appIntent(context, UUID.randomUUID().toString(), "com.android.settings")
        assertNotEquals("Distinct trust produces distinct PendingIntent identity", first.data, second.data)
    }
    @Test fun forgedRevokedShortcutNeverAdmitsAnOperation() {
        val context = instrumentation.targetContext; val store = BridgeStore.get(context); val before = store.commandOutcomes().length()
        val activity = instrumentation.startActivitySync(QuickAccess.appIntent(context, UUID.randomUUID().toString(), "com.android.settings").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as Activity
        try {
            waitFor { var found = false; instrumentation.runOnMainSync {
                found = nodes(activity.window.decorView).filterIsInstance<Button>().any { it.text.toString().startsWith("Open ") && it.text.toString().contains(" on ") && !it.isEnabled }
            }; found }
            assertEquals(before, store.commandOutcomes().length())
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }
}

package dev.droidbridge.companion

import android.app.Activity
import android.content.Intent
import android.content.pm.ShortcutManager
import android.os.Bundle
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Real launcher pin + real launcher activation. Run manually with the system confirmation UI. */
class PlatformPinnedShortcutDeviceTest {
    @Test fun launcherPinsAndOpensExactTrustWithoutAdmittingAnEffect() {
        org.junit.Assume.assumeTrue("Requires an explicit launcher confirmation harness", InstrumentationRegistry.getArguments().getString("interactive_platform") == "true")
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val context = instrumentation.targetContext
        val store = BridgeStore.get(context); val previous = store.selectedTrust()
        val secret = store.startPairing()
        val pair = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret)
            .put("mac_id", UUID.randomUUID().toString()).put("mac_name", "Platform acceptance Mac"))
        val trust = store.approvePair(pair.getString("pairing_id")).trustId; store.denyPair()
        val label = "Bridge acceptance"
        val id = ProtocolRules.hash("$trust:com.android.settings".toByteArray())
        val activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as Activity
        fun waitFor(message: String, check: () -> Boolean) {
            val deadline = SystemClock.elapsedRealtime() + 45000
            while (SystemClock.elapsedRealtime() < deadline) { if (check()) return; Thread.sleep(100) }
            assertTrue(message, check())
        }
        try {
            instrumentation.runOnMainSync { assertTrue(QuickAccess.pinApp(activity, trust, "com.android.settings", label)) }
            instrumentation.sendStatus(0, Bundle().apply { putString("platform_step", "Approve actual launcher Add to Home screen for Bridge acceptance; then tap its home icon") })
            val manager = context.getSystemService(ShortcutManager::class.java)
            waitFor("System launcher pin not approved") { manager.pinnedShortcuts.any { it.id == id } }
            val pinned = manager.pinnedShortcuts.single { it.id == id }
            assertEquals(trust, pinned.intent?.getStringExtra(QuickAccess.TRUST))
            assertEquals("com.android.settings", pinned.intent?.getStringExtra(QuickAccess.PACKAGE))
            var opened: QuickAccessActivity? = null
            waitFor("Tap actual launcher Bridge acceptance icon") {
                instrumentation.runOnMainSync { opened = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                    .filterIsInstance<QuickAccessActivity>().firstOrNull() }
                opened != null
            }
            instrumentation.runOnMainSync {
                assertEquals(QuickAccess.OPEN_APP, opened!!.intent.action)
                assertEquals(trust, opened!!.intent.getStringExtra(QuickAccess.TRUST))
                assertEquals("com.android.settings", opened!!.intent.getStringExtra(QuickAccess.PACKAGE))
            }
            assertFalse((0 until store.commandOutcomes().length()).map { store.commandOutcomes().getJSONObject(it) }.any { it.optString("trust_id") == trust })
            val file = java.io.File(context.getExternalFilesDir(null), "platform-pinned-shortcut.png")
            instrumentation.uiAutomation.takeScreenshot().also { bitmap -> file.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle() }
            instrumentation.addResults(Bundle().apply { putString("platform_pin_proof", "Actual launcher pin/activation exact trust confirmed; no remote effect; screenshot=${file.absolutePath}; shortcut=$id") })
            // Retain only a disabled owned fixture until the harness removes its exact home item.
            manager.disableShortcuts(listOf(id), "Platform acceptance fixture complete; remove this shortcut")
        } finally {
            store.revoke(trust); previous?.let { store.selectTrust(it) }
            instrumentation.runOnMainSync { activity.finish() }
        }
    }
}

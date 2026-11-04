package dev.droidbridge.companion

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Actual AppWidgetManager binding, provider RemoteViews, and system PendingIntent activation. */
class PlatformWidgetDeviceTest {
    @Test fun actualHostedFavoriteOpensExactTrustWithoutAdmittingAnEffect() {
        org.junit.Assume.assumeTrue("Requires explicit system widget host harness", InstrumentationRegistry.getArguments().getString("interactive_platform") == "true")
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val context = instrumentation.targetContext
        PlatformUiProof.configure()
        val store = BridgeStore.get(context); val previous = store.selectedTrust()
        val prefs = context.getSharedPreferences("companion-ui", Context.MODE_PRIVATE)
        val hadFavorites = prefs.contains("favorites"); val favorites = prefs.getStringSet("favorites", emptySet())?.toSet() ?: emptySet()
        val secret = store.startPairing()
        val pair = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret)
            .put("mac_id", UUID.randomUUID().toString()).put("mac_name", "Widget acceptance Mac"))
        val trust = store.approvePair(pair.getString("pairing_id")).trustId; store.denyPair(); store.selectTrust(trust)
        store.refreshCatalog(); prefs.edit().putStringSet("favorites", setOf("com.android.settings")).commit()
        val app = store.catalogLocal().let { rows -> (0 until rows.length()).map { rows.getJSONObject(it) }.single { it.getString("package_name") == "com.android.settings" } }
        val label = "${app.getString("label")} on Mac"
        val activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as Activity
        val testPackage = instrumentation.context.packageName
        require(testPackage.matches(Regex("[a-zA-Z0-9_.]+")))
        fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).use { it.readBytes().toString(Charsets.UTF_8) }
        fun waitFor(message: String, check: () -> Boolean) {
            val until = SystemClock.elapsedRealtime() + 10000
            while (SystemClock.elapsedRealtime() < until) { if (check()) return; Thread.sleep(80) }
            PlatformUiProof.captureFailure("platform-widget-failure")
            assertTrue(message, check())
        }
        fun shot(name: String) {
            PlatformUiProof.settle()
            val file = java.io.File(context.getExternalFilesDir(null), name)
            instrumentation.uiAutomation.takeScreenshot().also { bitmap -> file.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle() }
        }
        try {
            shell("appwidget grantbind --package $testPackage --user 0")
            shell("am start -n $testPackage/dev.droidbridge.companion.PlatformWidgetHostActivity --es target_package ${context.packageName}")
            waitFor("Actual system widget host not visible") { PlatformUiProof.text("Actual system-bound DroidBridge widget", testPackage) != null }
            BridgeWidget.refresh(context)
            waitFor("Actual widget favorite not rendered") { PlatformUiProof.text(label, context.packageName) != null }
            shot("platform-widget-favorite.png")
            PlatformUiProof.touch(PlatformUiProof.text(label, context.packageName)!!)
            var opened: QuickAccessActivity? = null
            waitFor("System widget PendingIntent did not open quick review") {
                instrumentation.runOnMainSync { opened = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<QuickAccessActivity>().firstOrNull() }
                opened != null
            }
            instrumentation.runOnMainSync {
                assertEquals(QuickAccess.OPEN_APP, opened!!.intent.action)
                assertEquals(trust, opened!!.intent.getStringExtra(QuickAccess.TRUST))
                assertEquals("com.android.settings", opened!!.intent.getStringExtra(QuickAccess.PACKAGE))
            }
            assertFalse(store.commandOutcomes().let { rows -> (0 until rows.length()).map { rows.getJSONObject(it) }.any { it.optString("trust_id") == trust } })
            val reviewStatus = "${QuickAccessState.label(store.running, false)} · Widget acceptance Mac"
            waitFor("Actual quick review text not displayed") { PlatformUiProof.text(reviewStatus, context.packageName) != null }
            shot("platform-widget-favorite-open.png")
            instrumentation.runOnMainSync { opened!!.finish() }
            // Bring back the singleTask test host, then finish its exact owned binding.
            shell("am start -n $testPackage/dev.droidbridge.companion.PlatformWidgetHostActivity --es target_package ${context.packageName}")
            waitFor("Widget host did not resume for cleanup") { PlatformUiProof.text("Actual system-bound DroidBridge widget", testPackage) != null }
            instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
        } finally {
            shell("am start -n $testPackage/dev.droidbridge.companion.PlatformWidgetHostActivity --es target_package ${context.packageName} --ez cleanup true")
            shell("appwidget revokebind --package $testPackage --user 0")
            if (hadFavorites) prefs.edit().putStringSet("favorites", favorites).commit() else prefs.edit().remove("favorites").commit()
            store.revoke(trust); previous?.let { store.selectTrust(it) }
            instrumentation.runOnMainSync { activity.finish() }
        }
    }
}

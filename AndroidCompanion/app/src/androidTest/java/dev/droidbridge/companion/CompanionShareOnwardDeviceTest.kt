package dev.droidbridge.companion

import android.content.Intent
import android.graphics.Rect
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Button
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Test
import java.util.UUID

/** Opt-in: real Sharesheet selection and bytes read inside a different app UID. */
class CompanionShareOnwardDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val target get() = instrumentation.targetContext
    private fun nodes(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { nodes(view.getChildAt(it)) } else emptyList()
    private fun accessibility(): List<AccessibilityNodeInfo> {
        fun flatten(node: AccessibilityNodeInfo?): List<AccessibilityNodeInfo> = if (node == null) emptyList() else listOf(node) + (0 until node.childCount).flatMap { flatten(node.getChild(it)) }
        val automation = instrumentation.uiAutomation
        return (automation.windows.mapNotNull { it.root } + listOfNotNull(automation.rootInActiveWindow)).flatMap(::flatten).filter { it.isVisibleToUser }
    }
    private fun waitFor(label: String, condition: () -> Boolean) {
        val end = SystemClock.elapsedRealtime() + 8000
        while (SystemClock.elapsedRealtime() < end) { if (condition()) return; Thread.sleep(40) }
        throw AssertionError(label + "\nObserved: " + text().take(1200))
    }
    private fun text() = accessibility().mapNotNull { it.text?.toString() }.joinToString("\n")
    private fun touch(rect: Rect) {
        assertFalse(rect.isEmpty)
        val started = SystemClock.uptimeMillis()
        for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
            val event = MotionEvent.obtain(started, SystemClock.uptimeMillis(), action, rect.centerX().toFloat(), rect.centerY().toFloat(), 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            assertTrue(instrumentation.uiAutomation.injectInputEvent(event, true)); event.recycle()
            if (action == MotionEvent.ACTION_DOWN) Thread.sleep(60)
        }
    }
    private fun screenshot(name: String) {
        Thread.sleep(200)
        val bitmap = instrumentation.uiAutomation.takeScreenshot() ?: throw AssertionError("Screenshot unavailable")
        val directory = java.io.File(target.getExternalFilesDir(null), "verification").apply { mkdirs() }
        java.io.File(directory, name).outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
    }
    @Test fun sharesheetGrantsOnlyExplicitlySelectedExternalReceiverTheVerifiedFile() {
        assumeTrue("Requires coordinated separate fixture app", InstrumentationRegistry.getArguments().getString("external_receiver") == "1")
        PlatformUiProof.configure()
        android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand("cmd statusbar collapse")).use { it.readBytes() }
        val store = BridgeStore.get(target); val original = store.selectedTrust()
        val secret = store.startPairing()
        val pending = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("mac_id", UUID.randomUUID().toString()).put("mac_name", "Onward grant verification").put("pairing_secret", secret))
        val trust = store.approvePair(pending.getString("pairing_id")).trustId
        store.denyPair(); store.selectTrust(trust)
        val bitmap = android.graphics.Bitmap.createBitmap(32, 32, android.graphics.Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.rgb(36, 87, 197))
        val bytes = java.io.ByteArrayOutputStream().also { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }.toByteArray(); bitmap.recycle()
        val id = UUID.randomUUID().toString(); val expected = ProtocolRules.hash(bytes)
        var activity: MainActivity? = null
        try {
            store.transfers.begin(trust, JSONObject().put("transfer_id", id).put("direction", "mac_to_phone").put("display_name", "Onward verification.png").put("mime_type", "image/png").put("size", bytes.size).put("sha256", expected))
            store.transfers.put(id, trust, 0, expected, bytes); store.transfers.commit(id, trust)
            val uri = store.transfers.shareUri(id)
            // A real foreground sender is required by Android's activity-launch policy.
            activity = instrumentation.startActivitySync(Intent(target, MainActivity::class.java).putExtra("tab", "Sharing").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            instrumentation.waitForIdleSync()
            Thread.sleep(200)
            // A String extra is not a URI grant. The recipient must actually fail a read.
            target.startActivity(Intent().setClassName("dev.droidbridge.companionfixture", "dev.droidbridge.companionfixture.ReceiveActivity").putExtra("probe_uri", uri.toString()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            waitFor("Ungranting direct launch must refuse actual content read") { text().contains("READ_REFUSED") }
            screenshot("share-onward-without-grant.png")
            instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
            PlatformUiProof.settle()
            val screen = checkNotNull(activity)
            instrumentation.waitForIdleSync()
            var button: Button? = null
            waitFor("Actual received-file share action is available") {
                instrumentation.runOnMainSync { button = nodes(screen.window.decorView).filterIsInstance<Button>().firstOrNull { it.text.toString() == "Share Onward verification.png onward…" } }
                button != null
            }
            val bounds = Rect()
            instrumentation.runOnMainSync { button!!.requestRectangleOnScreen(Rect(0, 0, button!!.width, button!!.height), true) }
            PlatformUiProof.settle()
            val shareLabel = "Share Onward verification.png onward…"
            waitFor("Share control has an actual visible accessibility node") { PlatformUiProof.text(shareLabel, target.packageName) != null }
            PlatformUiProof.touch(checkNotNull(PlatformUiProof.text(shareLabel, target.packageName)))
            screenshot("share-onward-after-touch.png")
            waitFor("System Sharesheet offers the separate recipient") { accessibility().any { it.text?.toString() == "DroidBridge transfer verifier" } }
            screenshot("share-onward-sharesheet.png")
            val receiver = accessibility().first { it.text?.toString() == "DroidBridge transfer verifier" }
            PlatformUiProof.settle()
            PlatformUiProof.touch(receiver)
            waitFor("Selected recipient must read the exact granted bytes") { text().contains("READ_OK") }
            val receipt = text()
            assertTrue(receipt.contains("Grant: true")); assertTrue(receipt.contains("Bytes: ${bytes.size}")); assertTrue(receipt.contains("SHA256: $expected"))
            val uid = Regex("External UID: (\\d+)").find(receipt)?.groupValues?.get(1)?.toInt() ?: throw AssertionError("External UID missing")
            assertNotEquals("Read happens in a separate ordinary app UID", target.applicationInfo.uid, uid)
            assertEquals("Receiver UID binds the installed fixture package", target.packageManager.getApplicationInfo("dev.droidbridge.companionfixture", 0).uid, uid)
            screenshot("share-onward-external-read.png")
            val output = java.io.File(target.getExternalFilesDir(null), "verification/share-onward.json")
            output.writeText(JSONObject().put("separate_uid", true).put("no_grant_read_refused", true).put("sharesheet_selected", true).put("read_grant_present", true).put("bytes", bytes.size).put("sha256", expected).toString(2))
        } catch (failure: Throwable) {
            PlatformUiProof.captureFailure("share-onward-failure")
            throw failure
        } finally {
            instrumentation.uiAutomation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
            instrumentation.runOnMainSync { activity?.finish() }
            store.revoke(trust); original?.let(store::selectTrust)
        }
    }
}

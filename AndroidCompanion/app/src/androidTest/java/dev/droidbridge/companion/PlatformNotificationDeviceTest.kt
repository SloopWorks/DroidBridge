package dev.droidbridge.companion

import android.app.Activity
import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** A real foreground notification with bytes from the transfer ledger, followed through SystemUI. */
class PlatformNotificationDeviceTest {
    @Test fun transferProgressAndSystemNotificationActionUseRealService() {
        org.junit.Assume.assumeTrue("Explicit SystemUI acceptance harness", InstrumentationRegistry.getArguments().getString("interactive_platform") == "true")
        val instrumentation = InstrumentationRegistry.getInstrumentation(); val context = instrumentation.targetContext
        org.junit.Assume.assumeTrue(context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
        PlatformUiProof.configure()
        val store = BridgeStore.get(context); val wasRunning = store.running; val previous = store.selectedTrust()
        val secret = store.startPairing()
        val pair = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret)
            .put("mac_id", UUID.randomUUID().toString()).put("mac_name", "Notification acceptance Mac"))
        val trust = store.approvePair(pair.getString("pairing_id")).trustId; store.denyPair()
        val transfer = UUID.randomUUID().toString(); val all = byteArrayOf(1,2,3,4); val chunk = byteArrayOf(1)
        store.transfers.begin(trust, JSONObject().put("transfer_id", transfer).put("direction", "mac_to_phone").put("size", 4)
            .put("sha256", ProtocolRules.hash(all)).put("display_name", "notification-proof.bin").put("mime_type", "application/octet-stream"))
        store.transfers.put(transfer, trust, 0, ProtocolRules.hash(chunk), chunk)
        val activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as Activity
        fun waitFor(message: String, check: () -> Boolean) {
            val until = SystemClock.elapsedRealtime() + 10000
            while (SystemClock.elapsedRealtime() < until) { if (check()) return; Thread.sleep(80) }
            PlatformUiProof.captureFailure("platform-notification-failure")
            assertTrue(message, check())
        }
        try {
            instrumentation.runOnMainSync { context.startForegroundService(Intent(context, BridgeService::class.java)) }
            val manager = context.getSystemService(NotificationManager::class.java)
            var posted: Notification? = null
            waitFor("Real transfer progress notification not published") {
                posted = manager.activeNotifications.firstOrNull { it.id == 1 }?.notification
                posted?.extras?.getInt(Notification.EXTRA_PROGRESS_MAX) == 1000 && posted?.extras?.getInt(Notification.EXTRA_PROGRESS) == 250
            }
            assertEquals(listOf("Quick actions", "Transfers", "Disconnect…"), posted!!.actions.map { it.title.toString() })
            assertEquals(Notification.VISIBILITY_PRIVATE, posted!!.visibility)
            android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand("cmd statusbar expand-notifications")).use { it.readBytes() }
            var expanded = false
            waitFor("SystemUI transfer action did not appear") {
                if (PlatformUiProof.text("TRANSFERS", "com.android.systemui") != null) true else {
                    if (!expanded) expanded = PlatformUiProof.expandNotification(posted!!.extras.getCharSequence(Notification.EXTRA_TITLE).toString())
                    false
                }
            }
            val file = java.io.File(context.getExternalFilesDir(null), "platform-transfer-notification.png")
            instrumentation.uiAutomation.takeScreenshot().also { bitmap -> file.outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle() }
            PlatformUiProof.touch(PlatformUiProof.text("TRANSFERS", "com.android.systemui")!!)
            var sharing: MainActivity? = null
            waitFor("System notification transfer action did not open Sharing") {
                instrumentation.runOnMainSync { sharing = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<MainActivity>().firstOrNull { it.intent.getStringExtra("tab") == "Sharing" } }
                sharing != null
            }
        } finally {
            PlatformUiProof.collapsePanels()
            if (!wasRunning) context.stopService(Intent(context, BridgeService::class.java))
            store.revoke(trust); previous?.let { store.selectTrust(it) }
            instrumentation.runOnMainSync { activity.finish() }
        }
    }
}

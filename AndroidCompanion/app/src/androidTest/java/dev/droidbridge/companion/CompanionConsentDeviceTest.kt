package dev.droidbridge.companion

import android.app.AlertDialog
import android.content.Intent
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Actual consent UI; only the temporary named test trust can be confirmed. */
class CompanionConsentDeviceTest {
    @Test fun forgetConsentActionsFitAndCancelPreservesExistingTrust() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val store = BridgeStore.get(instrumentation.targetContext)
        fun trustIDs() = store.trusted().keys().asSequence().toSet()
        val original = trustIDs()
        val selected = store.selectedTrust()
        val secret = store.startPairing()
        val pairing = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString())
            .put("pairing_secret", secret).put("mac_id", UUID.randomUUID().toString()).put("mac_name", "Consent regression Mac"))
        store.approvePair(pairing.getString("pairing_id"))
        val temporary = store.pollPair(pairing.getString("pairing_id"), secret).getString("trust_id")
        store.denyPair()
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
        fun nodes(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { nodes(view.getChildAt(it)) } else emptyList()
        fun main(action: () -> Unit) { if (android.os.Looper.myLooper() == android.os.Looper.getMainLooper()) action() else instrumentation.runOnMainSync(action) }
        fun waitUntil(predicate: () -> Boolean) {
            val deadline = android.os.SystemClock.elapsedRealtime() + 5000
            while (!predicate() && android.os.SystemClock.elapsedRealtime() < deadline) {
                Thread.sleep(40); instrumentation.waitForIdleSync()
            }
            assertTrue("Expected asynchronous UI transition", predicate())
        }
        fun forgetButton(): Button? {
            var found: Button? = null
            main { found = nodes(activity.window.decorView).filterIsInstance<Button>().singleOrNull { it.text.toString() == "Forget Consent regression Mac" } }
            return found
        }
        try {
            main { nodes(activity.window.decorView).filterIsInstance<Button>().single { it.text.toString() == "Settings" }.performClick() }
            waitUntil { forgetButton() != null }
            main { forgetButton()!!.performClick() }
            instrumentation.waitForIdleSync()
            main {
                val dialog = activity.activeDialog ?: throw AssertionError("Consent dialog absent")
                for (which in listOf(AlertDialog.BUTTON_POSITIVE, AlertDialog.BUTTON_NEGATIVE)) {
                    val button = dialog.getButton(which)
                    val visible = Rect()
                    assertTrue("Action visible", button.getGlobalVisibleRect(visible))
                    assertEquals("Entire action stays inside dialog", button.height, visible.height())
                    assertTrue("Minimum 48dp action target", button.height >= (48 * activity.resources.displayMetrics.density).toInt())
                    val layout = button.layout ?: throw AssertionError("Missing action text layout")
                    assertTrue("Action text fits vertically", button.height - button.compoundPaddingTop - button.compoundPaddingBottom >= layout.height)
                    for (line in 0 until layout.lineCount) assertEquals("No action text ellipsis", 0, layout.getEllipsisCount(line))
                }
                dialog.getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
            }
            assertEquals("Cancel preserves every trust", original + temporary, trustIDs())
            main { forgetButton()!!.performClick() }
            instrumentation.waitForIdleSync()
            main { activity.activeDialog!!.getButton(AlertDialog.BUTTON_POSITIVE).performClick() }
            waitUntil { temporary !in trustIDs() }
            assertEquals("Confirmation removes only the explicit temporary Mac", original, trustIDs())
            assertEquals("Original receiver preserved", selected, store.selectedTrust())
        } finally {
            main { activity.finish() }
            if (temporary in trustIDs()) store.revoke(temporary)
        }
    }
}

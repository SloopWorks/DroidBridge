package dev.droidbridge.companion

import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.graphics.Rect
import android.net.Uri
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Real native consent/paste controls against a nonce-granted external test provider. */
class CompanionConsentInputDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val target get() = instrumentation.targetContext
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun nodes(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { nodes(view.getChildAt(it)) } else emptyList()
    private fun waitFor(message: String, predicate: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 6000
        while (!predicate() && SystemClock.elapsedRealtime() < deadline) { Thread.sleep(40); instrumentation.waitForIdleSync() }
        assertTrue(message, predicate())
    }
    private fun click(activity: Activity, label: String) = main { nodes(activity.window.decorView).filterIsInstance<Button>().single { it.text.toString() == label }.performClick() }
    private fun launch(intent: Intent = Intent(target, MainActivity::class.java)): MainActivity = instrumentation.startActivitySync(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
    private fun editor(activity: Activity): EditText = nodes(activity.window.decorView).filterIsInstance<EditText>().single()
    private fun text(activity: Activity): String = nodes(activity.window.decorView).filterIsInstance<TextView>().joinToString("\n") { it.text.toString() }
    private class ProviderCounts(val queries: Int, val types: Int, val opens: Int) {
        fun json() = JSONObject().put("query_count", queries).put("type_count", types).put("open_count", opens)
    }
    private fun counts(uri: Uri): ProviderCounts = target.contentResolver.query(uri, null, null, null, null)!!.use {
        assertTrue(it.moveToFirst())
        ProviderCounts(it.getInt(it.getColumnIndexOrThrow("query_count")), it.getInt(it.getColumnIndexOrThrow("type_count")), it.getInt(it.getColumnIndexOrThrow("open_count")))
    }
    private fun unchanged(before: ProviderCounts, after: ProviderCounts) {
        assertEquals("No provider query", before.queries, after.queries)
        assertEquals("No provider MIME lookup", before.types, after.types)
        assertEquals("No provider content open", before.opens, after.opens)
    }
    private fun grant(): Pair<Uri, Uri> {
        val token = UUID.randomUUID().toString()
        val result = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(
            "am start -W -n dev.droidbridge.companion.test/dev.droidbridge.companion.StagingGrantActivity --es token $token")).use { it.readBytes().toString(Charsets.UTF_8) }
        assertTrue("Real owner grant Activity started", result.contains("Status: ok"))
        val status = Uri.parse("content://dev.droidbridge.companion.test.staging/status/$token")
        waitFor("Exact nonce read grant ready") { runCatching { counts(status) }.isSuccess }
        return Uri.parse("content://dev.droidbridge.companion.test.staging/query-stall/$token") to status
    }
    private fun addTemporaryTrust(store: BridgeStore): String {
        val secret = store.startPairing()
        val pending = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret)
            .put("mac_id", UUID.randomUUID().toString()).put("mac_name", "Input regression Mac"))
        store.approvePair(pending.getString("pairing_id"))
        return store.pollPair(pending.getString("pairing_id"), secret).getString("trust_id").also { store.denyPair() }
    }

    @Test fun fileReviewDoesNotQueryStalledProviderBeforeConsentAndCancelPreservesDraft() {
        val store = BridgeStore.get(target); val originalTrusts = store.trusted().keys().asSequence().toSet(); val originalSelected = store.selectedTrust()
        val temporary = addTemporaryTrust(store); store.selectTrust(temporary)
        var base: MainActivity? = null; var share: MainActivity? = null
        try {
            val (uri, status) = grant()
            val baseActivity = launch(); base = baseActivity; click(baseActivity, "Sharing")
            main { editor(baseActivity).setText("Synthetic draft survives cancelled file share") }
            val before = counts(status)
            val started = SystemClock.elapsedRealtime()
            val shareActivity = launch(Intent(Intent.ACTION_SEND).setClass(target, MainActivity::class.java).setType("application/octet-stream").putExtra(Intent.EXTRA_STREAM, uri)); share = shareActivity
            waitFor("Actual file consent sheet appears without provider metadata") { var present = false; main { present = shareActivity.activeDialog != null }; present }
            val elapsed = SystemClock.elapsedRealtime() - started
            main {
                val dialog = shareActivity.activeDialog!!
                val body = nodes(dialog.window!!.decorView).filterIsInstance<TextView>().joinToString("\n") { it.text.toString() }
                assertTrue("Review names selected recipient", body.contains("Input regression Mac"))
                assertTrue("Review honestly describes deferred metadata", body.contains("after", true) && (body.contains("name", true) || body.contains("size", true)))
                val cancel = dialog.getButton(AlertDialog.BUTTON_NEGATIVE)
                assertTrue("Cancel remains actually visible", cancel.getGlobalVisibleRect(Rect()))
                cancel.performClick()
            }
            Thread.sleep(250)
            unchanged(before, counts(status))
            main { assertNull("Cancel closes the sheet", shareActivity.activeDialog?.takeIf { it.isShowing }); shareActivity.finish() }
            instrumentation.waitForIdleSync()
            main { assertEquals("Original editor retained", "Synthetic draft survives cancelled file share", editor(baseActivity).text.toString()) }
            assertEquals("No transfer admitted before consent", 0, (0 until store.transfers.listLocal().length()).count { store.transfers.listLocal().getJSONObject(it).optString("owner") == temporary })
            instrumentation.addResults(Bundle().apply { putString("droidbridge_preconsent_evidence", JSONObject().put("consent_visible_ms", elapsed).put("provider_counts_before", before.json()).put("provider_counts_after", counts(status).json()).put("cancel_preserved_draft", true).toString()) })
        } finally {
            main { share?.finish(); base?.finish() }
            store.revoke(temporary); originalSelected?.let { store.selectTrust(it) }
            assertEquals("Only test trust removed", originalTrusts, store.trusted().keys().asSequence().toSet())
            assertEquals("Original recipient preserved", originalSelected, store.selectedTrust())
        }
    }

    @Test fun uriClipboardAndOversizedTextDoNotReadProviderOrReplaceDraftAndClipboardIsRestored() {
        val (uri, status) = grant(); val activity = launch(); val clipboard = target.getSystemService(ClipboardManager::class.java)
        var original: ClipData? = null; var originalRead = false
        try {
            click(activity, "Sharing")
            main {
                editor(activity).requestFocus()
                original = clipboard.primaryClip; originalRead = true
                editor(activity).setText("Synthetic draft remains unchanged")
                // newRawUri itself does not ask the provider for MIME/type/content.
                clipboard.setPrimaryClip(ClipData.newRawUri("Synthetic stalled URI", uri))
            }
            // ClipboardService asynchronously resolves the URI MIME after setPrimaryClip.
            // Complete that platform setup before measuring the app's Paste action.
            waitFor("Android clipboard MIME classification completed before Paste") { counts(status).types > 0 }
            val before = counts(status)
            assertEquals("Clipboard setup never opens content", 0, before.opens)
            assertEquals("Clipboard setup never queries metadata", 0, before.queries)
            click(activity, "Paste clipboard")
            instrumentation.waitForIdleSync()
            main {
                assertEquals("Unsupported URI keeps draft", "Synthetic draft remains unchanged", editor(activity).text.toString())
                assertTrue("URI rejection has useful next step", text(activity).contains("Share", true) || text(activity).contains("text only", true))
            }
            unchanged(before, counts(status))
            for (oversize in listOf("x".repeat(65537), "€".repeat(22000))) {
                main { clipboard.setPrimaryClip(ClipData.newPlainText("Synthetic oversize", oversize)) }
                click(activity, "Paste clipboard"); instrumentation.waitForIdleSync()
                main {
                    assertEquals("Oversize preserves draft", "Synthetic draft remains unchanged", editor(activity).text.toString())
                    assertTrue("Byte-limit error is visible", text(activity).contains("64", true) || text(activity).contains("large", true))
                }
            }
            main { clipboard.setPrimaryClip(ClipData.newPlainText("Synthetic bounded text", "Deliberate bounded paste")) }
            click(activity, "Paste clipboard"); instrumentation.waitForIdleSync()
            main { assertEquals("Bounded direct text still works", "Deliberate bounded paste", editor(activity).text.toString()) }
            unchanged(before, counts(status))
            instrumentation.addResults(Bundle().apply { putString("droidbridge_clipboard_input_evidence", JSONObject().put("uri_provider_io", false).put("utf16_oversize_rejected", true).put("utf8_oversize_rejected", true).put("bounded_text_pasted", true).toString()) })
        } finally {
            main {
                if (originalRead) { if (original == null) clipboard.clearPrimaryClip() else clipboard.setPrimaryClip(original!!) }
                assertEquals("Clipboard presence restored", original != null, clipboard.hasPrimaryClip())
                if (original != null) {
                    val restored = clipboard.primaryClip!!
                    assertEquals("Original clipboard item count restored", original!!.itemCount, restored.itemCount)
                    for (i in 0 until original!!.itemCount) {
                        val a = original!!.getItemAt(i); val b = restored.getItemAt(i)
                        // Compare in memory; never print clipboard contents in assertion output.
                        assertTrue("Original clipboard text restored", a.text?.toString() == b.text?.toString())
                        assertTrue("Original clipboard URI restored", a.uri == b.uri)
                        assertTrue("Original clipboard intent restored", a.intent?.toUri(0) == b.intent?.toUri(0))
                    }
                }
                activity.finish()
            }
        }
    }
}

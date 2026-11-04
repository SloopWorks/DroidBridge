package dev.droidbridge.companion

import android.app.AlertDialog
import android.content.Intent
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
import com.google.android.material.bottomnavigation.BottomNavigationView
import java.util.UUID

/** Installed Material views, explicit sharing, and durable snippets. Never launches a remote app. */
class CompanionImprovementsUXDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val target get() = instrumentation.targetContext
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun nodes(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { nodes(view.getChildAt(it)) } else emptyList()
    private fun launch(intent: Intent = Intent(target, MainActivity::class.java)) = instrumentation.startActivitySync(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
    private fun click(activity: MainActivity, label: String) = main { val nav = nodes(activity.window.decorView).filterIsInstance<BottomNavigationView>().singleOrNull()
        val item = nav?.menu?.let { menu -> (0 until menu.size()).map { menu.getItem(it) }.singleOrNull { it.title.toString() == label } }
        if (item != null) nav.findViewById<View>(item.itemId).performClick()
        else nodes(activity.window.decorView).filterIsInstance<Button>().single { it.text.toString() == label }.performClick() }
    private fun await(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 5000
        while (!condition() && SystemClock.elapsedRealtime() < deadline) { Thread.sleep(40); instrumentation.waitForIdleSync() }
        assertTrue(message, condition())
    }
    private fun trust(store: BridgeStore, label: String): String {
        val secret = store.startPairing()
        val pair = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret).put("mac_id", UUID.randomUUID().toString()).put("mac_name", label))
        store.approvePair(pair.getString("pairing_id"))
        return store.pollPair(pair.getString("pairing_id"), secret).getString("trust_id").also { store.denyPair() }
    }
    @Test fun shareChoosesRecipientInsideFlowWithoutChangingGeneralReceiverOrSendingBeforeConsent() {
        val store = BridgeStore.get(target); val original = store.selectedTrust()
        val label = "Share UX ${UUID.randomUUID().toString().take(8)}"
        val temporary = trust(store, label)
        val selectionBefore = store.selectedTrust()
        val before = store.commandOutcomes().length()
        val activity = launch(Intent(Intent.ACTION_SEND).setClass(target, MainActivity::class.java).setType("text/plain").putExtra(Intent.EXTRA_TEXT, "https://example.com/explicit-review"))
        try {
            await("Recipient picker appears") { var shown = false; main { shown = activity.activeDialog?.isShowing == true }; shown }
            main {
                val dialog = activity.activeDialog!!; val list = dialog.listView
                val index = (0 until list.adapter.count).single { list.adapter.getItem(it).toString() == label }
                list.performItemClick(list.getChildAt(index), index, list.adapter.getItemId(index))
            }
            instrumentation.waitForIdleSync()
            main {
                val dialog = activity.activeDialog!!; val list = dialog.listView
                assertEquals("Send to inbox", list.adapter.getItem(0).toString())
                assertEquals("Copy on Mac", list.adapter.getItem(1).toString())
                assertEquals("Open link on Mac", list.adapter.getItem(2).toString())
                list.performItemClick(list.getChildAt(2), 2, list.adapter.getItemId(2))
            }
            instrumentation.waitForIdleSync()
            main {
                val dialog = activity.activeDialog!!
                val body = nodes(dialog.window!!.decorView).filterIsInstance<TextView>().joinToString("\n") { it.text.toString() }
                assertTrue(body.contains(label)); assertTrue(body.contains("https://example.com/explicit-review"))
                dialog.getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
            }
            assertEquals("Review never submits", before, store.commandOutcomes().length())
            assertEquals("Share destination does not rewrite general receiver", selectionBefore, store.selectedTrust())
        } finally { main { activity.finish() }; store.revoke(temporary); original?.let(store::selectTrust) }
    }
    @Test fun savedSnippetCanBeFoundPinnedAndSurvivesActivityRecreation() {
        val store = BridgeStore.get(target)
        val marker = "UI snippet ${UUID.randomUUID()}"
        val snippet = store.saveSnippet(marker)
        var activity = launch(Intent(target, MainActivity::class.java).putExtra("tab", "Sharing"))
        try {
            await("Snippet library is loaded") { var enabled = false; main { enabled = nodes(activity.window.decorView).filterIsInstance<Button>().any { it.text.toString() == "Browse and search snippets" && it.isEnabled } }; enabled }
            click(activity, "Browse and search snippets")
            main {
                val dialog = activity.activeDialog!!
                val editor = nodes(dialog.window!!.decorView).filterIsInstance<EditText>().single()
                editor.setText(marker)
                nodes(dialog.window!!.decorView).filterIsInstance<Button>().single { it.text.toString() == marker }.performClick()
            }
            instrumentation.waitForIdleSync()
            main {
                val dialog = activity.activeDialog!!; val list = dialog.listView
                list.performItemClick(list.getChildAt(2), 2, list.adapter.getItemId(2))
            }
            await("Pin is durably saved") { (0 until store.snippets().length()).map { store.snippets().getJSONObject(it) }.single { it.getString("id") == snippet.getString("id") }.optBoolean("pinned") }
            main { activity.finish() }
            activity = launch(Intent(target, MainActivity::class.java).putExtra("tab", "Sharing"))
            await("Pinned snippet is visible after recreation") { var found = false; main { found = nodes(activity.window.decorView).filterIsInstance<Button>().any { it.text.toString() == "Pinned · ${marker.take(60)}" } }; found }
        } finally { main { activity.finish() }; store.deleteSnippet(snippet.getString("id")) }
    }
    @Test fun materialScreensProduceActualInstalledScreenshotsWithoutRemoteActions() {
        val store = BridgeStore.get(target); val original = store.selectedTrust()
        val temporary = trust(store, "Design review Mac"); store.selectTrust(temporary)
        val snippet = store.saveSnippet("Meeting notes: open messaging and share the draft with my Mac."); store.pinSnippet(snippet.getString("id"), true)
        val preset = store.savePreset("Desk setup", listOf(target.packageName), temporary, "mac", "balanced", true)
        var activity: MainActivity? = null
        fun capture(name: String) {
            instrumentation.waitForIdleSync(); Thread.sleep(300)
            val output = java.io.File(target.getExternalFilesDir(null), "verification").apply { mkdirs() }
            val screenshot = instrumentation.uiAutomation.takeScreenshot() ?: throw AssertionError("Screenshot unavailable")
            java.io.File(output, "$name${InstrumentationRegistry.getArguments().getString("design_suffix", "")}.png").outputStream().use { screenshot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
            screenshot.recycle()
        }
        try {
            val screen = launch(); activity = screen
            await("Synthetic Mac and preset visible") { var ready = false; main { ready = nodes(screen.window.decorView).filterIsInstance<TextView>().any { it.text.toString().contains("Desk setup") } }; ready }
            capture("mobile-home")
            main { nodes(screen.window.decorView).filterIsInstance<Button>().single { it.text.toString() == "Run Desk setup" }.requestRectangleOnScreen(android.graphics.Rect(0, 0, 500, 200), true) }
            capture("mobile-presets")
            click(screen, "Sharing"); instrumentation.waitForIdleSync()
            main { nodes(screen.window.decorView).filterIsInstance<EditText>().single().setText("https://example.com/review-on-mac") }
            capture("mobile-sharing")
            click(screen, "Browse and search snippets"); capture("mobile-snippets")
            main { screen.activeDialog?.dismiss() }
            val quick = instrumentation.startActivitySync(Intent(target, QuickAccessActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            capture("mobile-quick-actions")
            main { quick.finish() }
        } finally {
            main { activity?.finish() }; store.deleteSnippet(snippet.getString("id")); store.deletePreset(preset.getString("id")); store.revoke(temporary); original?.let(store::selectTrust)
        }
    }

    @Test fun verifiedImageThumbnailAndGroupedFilesRenderAndShareThroughRealProvider() {
        val store = BridgeStore.get(target); val original = store.selectedTrust()
        val temporary = trust(store, "Transfer design Mac"); store.selectTrust(temporary)
        val bitmap = android.graphics.Bitmap.createBitmap(64, 64, android.graphics.Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.rgb(36, 87, 197))
        android.graphics.Canvas(bitmap).drawCircle(32f, 32f, 18f, android.graphics.Paint().apply { color = android.graphics.Color.rgb(95, 225, 203) })
        val image = java.io.ByteArrayOutputStream().also { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }.toByteArray(); bitmap.recycle()
        val originals = mutableListOf<String>(); var activity: MainActivity? = null
        try {
            for ((name, mime, bytes) in listOf(Triple("Design preview.png", "image/png", image), Triple("Design notes.txt", "text/plain", "A verified batch fixture".toByteArray()))) {
                val id = UUID.randomUUID().toString(); originals.add(id)
                store.transfers.begin(temporary, JSONObject().put("transfer_id", id).put("direction", "mac_to_phone").put("display_name", name).put("mime_type", mime).put("size", bytes.size).put("sha256", ProtocolRules.hash(bytes)))
                store.transfers.put(id, temporary, 0, ProtocolRules.hash(bytes), bytes); store.transfers.commit(id, temporary)
            }
            val uri = store.transfers.shareUri(originals.first())
            assertArrayEquals("Real provider serves only the verified bytes", image, target.contentResolver.openInputStream(uri)!!.use { it.readBytes() })
            val batch = UUID.randomUUID().toString()
            originals.forEach { store.transfers.stage(store.transfers.shareUri(it), temporary, batchId = batch) }
            val screen = launch(Intent(target, MainActivity::class.java).putExtra("tab", "Sharing")); activity = screen
            await("Verified image is decoded into its installed view") { var ready = false; main { ready = nodes(screen.window.decorView).filterIsInstance<android.widget.ImageView>().any { it.contentDescription == "Preview of Design preview.png" && it.drawable != null } }; ready }
            main {
                assertTrue("Both staged files are grouped with honest unconfirmed progress", nodes(screen.window.decorView).filterIsInstance<TextView>().any { it.text.toString() == "File batch · 0 of 2 verified" })
                nodes(screen.window.decorView).filterIsInstance<android.widget.ImageView>().single { it.contentDescription == "Preview of Design preview.png" }.requestRectangleOnScreen(android.graphics.Rect(0, 0, 500, 500), true)
                assertTrue("Share onward is a real enabled action", nodes(screen.window.decorView).filterIsInstance<Button>().single { it.text.toString() == "Share Design preview.png onward…" }.isEnabled)
            }
            instrumentation.waitForIdleSync(); Thread.sleep(300)
            val directory = java.io.File(target.getExternalFilesDir(null), "verification").apply { mkdirs() }
            val shot = instrumentation.uiAutomation.takeScreenshot() ?: throw AssertionError("Screenshot unavailable")
            java.io.File(directory, "mobile-transfers${InstrumentationRegistry.getArguments().getString("design_suffix", "")}.png").outputStream().use { shot.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }; shot.recycle()
            var editor: EditText? = null
            main { editor = nodes(screen.window.decorView).filterIsInstance<EditText>().single(); editor!!.requestFocus(); editor!!.setText("Draft retained through inbox removal") }
            store.transfers.cancelLocal(originals.first())
            await("Removed inbox file has no stale preview or share action while draft keeps focus") { var gone = false; main { gone = nodes(screen.window.decorView).filterIsInstance<android.widget.ImageView>().none { it.contentDescription == "Preview of Design preview.png" } && nodes(screen.window.decorView).filterIsInstance<Button>().none { it.text.toString() == "Share Design preview.png onward…" } }; gone }
            main { assertSame(editor, nodes(screen.window.decorView).filterIsInstance<EditText>().single()); assertEquals("Draft retained through inbox removal", editor!!.text.toString()) }
        } finally { main { activity?.finish() }; store.revoke(temporary); original?.let(store::selectTrust) }
    }

}

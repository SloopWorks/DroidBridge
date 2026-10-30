package dev.droidbridge.companion

import android.app.Activity
import android.content.Intent
import android.graphics.Rect
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.HorizontalScrollView
import android.widget.ListView
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

/** Actual installed native views. Never pairs, changes trust, launches remote apps or reads clipboard. */
class CompanionUXDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private fun nodes(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { nodes(view.getChildAt(it)) } else emptyList()
    private fun launch(): Activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    private fun main(action: () -> Unit) = instrumentation.runOnMainSync(action)
    private fun click(activity: Activity, label: String) = main { nodes(activity.window.decorView).filterIsInstance<Button>().single { it.text.toString() == label }.performClick() }

    @Test fun navigationHasCompleteLabelsAndSelectedSemanticsAtCurrentFontScale() {
        val activity = launch()
        try {
            instrumentation.waitForIdleSync()
            for (label in listOf("Home", "Apps", "Sharing", "Settings")) {
                click(activity, label)
                main {
                    val nav = nodes(activity.window.decorView).filterIsInstance<HorizontalScrollView>().single()
                    val button = nodes(nav).filterIsInstance<Button>().single { it.text.toString() == label }
                    nav.scrollTo(button.left, 0)
                }
                instrumentation.waitForIdleSync()
                main {
                    val button = nodes(activity.window.decorView).filterIsInstance<Button>().single { it.text.toString() == label }
                    assertTrue("$label selected", button.isSelected)
                    assertTrue(button.contentDescription.toString().contains("selected"))
                    assertTrue("$label visible after nav scroll", button.getGlobalVisibleRect(Rect()))
                    val layout = button.layout ?: throw AssertionError("No layout for $label")
                    assertTrue("$label not vertically clipped", button.height - button.compoundPaddingTop - button.compoundPaddingBottom >= layout.height)
                    for (line in 0 until layout.lineCount) assertEquals("$label not ellipsized", 0, layout.getEllipsisCount(line))
                }
            }
        } finally { main { activity.finish() } }
    }
    @Test fun appSearchSurvivesPollingAndNoMatchIsActuallyEmpty() {
        BridgeStore.get(instrumentation.targetContext).refreshCatalog()
        val activity = launch()
        try {
            click(activity, "Apps"); instrumentation.waitForIdleSync()
            var search: EditText? = null
            main {
                search = nodes(activity.window.decorView).filterIsInstance<EditText>().single()
                search!!.setText("droidbridge-ux-no-such-installed-package")
                assertEquals(0, nodes(activity.window.decorView).filterIsInstance<ListView>().single().adapter.count)
            }
            Thread.sleep(2200); instrumentation.waitForIdleSync()
            main {
                assertSame("Polling preserves editor identity", search, nodes(activity.window.decorView).filterIsInstance<EditText>().single())
                assertEquals("droidbridge-ux-no-such-installed-package", search!!.text.toString())
                search!!.setText("")
                val appList = nodes(activity.window.decorView).filterIsInstance<ListView>().single()
                assertTrue("Real installed apps restored", appList.adapter.count > 0)
                assertTrue("App list retains usable viewport at large text", appList.height >= (48 * activity.resources.displayMetrics.density).toInt())
            }
        } finally { main { activity.finish() } }
    }
    @Test fun sharingDraftSurvivesStatusPollingWithoutReadingClipboard() {
        val activity = launch()
        try {
            click(activity, "Sharing"); instrumentation.waitForIdleSync()
            var editor: EditText? = null
            main { editor = nodes(activity.window.decorView).filterIsInstance<EditText>().single(); editor!!.requestFocus(); editor!!.setText("Synthetic UX draft; never sent") }
            Thread.sleep(2200); instrumentation.waitForIdleSync()
            main {
                assertSame(editor, nodes(activity.window.decorView).filterIsInstance<EditText>().single())
                assertEquals("Synthetic UX draft; never sent", editor!!.text.toString())
            }
        } finally { main { activity.finish() } }
    }
}

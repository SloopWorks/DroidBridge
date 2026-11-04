package dev.droidbridge.companion

import android.content.Intent
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CompanionDiagnosticsDeviceTest {
    @Test fun collectionRequiresExplicitConsentAndDisablePurges() {
        CompanionDiagnostics.setEnabled(false)
        CompanionDiagnostics.record("launch", "applied", 19)
        assertTrue(CompanionDiagnostics.ring.entries.value.isEmpty())
        CompanionDiagnostics.setEnabled(true)
        try {
            CompanionDiagnostics.record("launch", "applied", 19)
            val deadline = SystemClock.elapsedRealtime() + 3000
            while (CompanionDiagnostics.ring.entries.value.none { it.rec is works.sloop.swip.DebugRecord.Enqueued } && SystemClock.elapsedRealtime() < deadline) {
                Thread.sleep(10)
            }
            val event = CompanionDiagnostics.ring.entries.value.map { it.rec }.filterIsInstance<works.sloop.swip.DebugRecord.Enqueued>().single()
            assertEquals("swip:event:companion_action_finished:1", event.schema)
            assertEquals(setOf("operation", "outcome", "duration_ms"), event.propsRaw.keys)
            // SDK ANONYMOUS stamps a rotating, memory-only anon_ identity; no session.
            assertTrue(event.distinctId?.startsWith("anon_") == true)
            assertNull(event.sessionId)
            CompanionDiagnostics.setEnabled(false)
            assertTrue(CompanionDiagnostics.ring.entries.value.isEmpty())
            CompanionDiagnostics.record("launch", "applied", 19)
            Thread.sleep(30)
            assertTrue(CompanionDiagnostics.ring.entries.value.isEmpty())
        } finally { CompanionDiagnostics.setEnabled(false) }
    }

    private fun node(label: String): android.view.accessibility.AccessibilityNodeInfo? {
        fun find(value: android.view.accessibility.AccessibilityNodeInfo?): android.view.accessibility.AccessibilityNodeInfo? {
            if (value == null) return null
            if (value.text?.toString() == label || value.contentDescription?.toString() == label) return value
            for (i in 0 until value.childCount) find(value.getChild(i))?.let { return it }
            return null
        }
        return find(InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow)
    }
    private fun awaitNode(label: String): android.view.accessibility.AccessibilityNodeInfo {
        val deadline = SystemClock.elapsedRealtime() + 6000
        while (SystemClock.elapsedRealtime() < deadline) {
            node(label)?.let { return it }
            Thread.sleep(40)
        }
        throw AssertionError("Rendered accessibility node unavailable: $label")
    }
    private fun tap(label: String) {
        val bounds = android.graphics.Rect()
        awaitNode(label).getBoundsInScreen(bounds)
        assertFalse("Actual touch target must have visible bounds", bounds.isEmpty)
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        val down = SystemClock.uptimeMillis()
        for (action in listOf(android.view.MotionEvent.ACTION_DOWN, android.view.MotionEvent.ACTION_UP)) {
            val event = android.view.MotionEvent.obtain(down, SystemClock.uptimeMillis(), action, bounds.centerX().toFloat(), bounds.centerY().toFloat(), 0)
            event.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
            assertTrue(automation.injectInputEvent(event, true))
            event.recycle()
            if (action == android.view.MotionEvent.ACTION_DOWN) Thread.sleep(60)
        }
    }
    private fun screenshot(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        instrumentation.waitForIdleSync()
        Thread.sleep(150)
        val screenshot = instrumentation.uiAutomation.takeScreenshot()
        assertNotNull("Actual diagnostics screen must render", screenshot)
        java.io.File(instrumentation.targetContext.filesDir, name).outputStream().use {
            assertTrue(screenshot!!.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it))
        }
        screenshot!!.recycle()
    }
    @Test fun actualComposeDrawerActivityOpensInsideTheDebugApp() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, CompanionDiagnosticsActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        try {
            awaitNode("Local diagnostics")
            screenshot("diagnostics-screen.png")
            tap("Open debug drawer")
            tap("SWIP")
            awaitNode("No SWIP records.")
            screenshot("diagnostics-swip-inspector.png")
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }
}

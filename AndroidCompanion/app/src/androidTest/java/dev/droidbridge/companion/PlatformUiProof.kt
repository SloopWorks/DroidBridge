package dev.droidbridge.companion

import android.accessibilityservice.AccessibilityServiceInfo
import android.graphics.Rect
import android.os.SystemClock
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.platform.app.InstrumentationRegistry

/** Real OS window nodes and injected touch; no guessed coordinates or constructed views. */
internal object PlatformUiProof {
    private val automation get() = InstrumentationRegistry.getInstrumentation().uiAutomation
    fun collapsePanels() { android.os.ParcelFileDescriptor.AutoCloseInputStream(automation.executeShellCommand("cmd statusbar collapse")).use { it.readBytes() } }
    fun configure() {
        automation.serviceInfo = automation.serviceInfo.apply { flags = flags or AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS }
        collapsePanels()
    }
    private fun roots() = automation.windows.mapNotNull { it.root } + listOfNotNull(automation.rootInActiveWindow)
    private fun descendants(root: AccessibilityNodeInfo): Sequence<AccessibilityNodeInfo> = sequence {
        val pending = java.util.ArrayDeque<AccessibilityNodeInfo>(); pending.add(root)
        var visited = 0
        while (pending.isNotEmpty() && visited++ < 4096) {
            val node = pending.removeFirst(); yield(node)
            for (i in 0 until node.childCount) node.getChild(i)?.let { pending.add(it) }
        }
    }
    fun text(value: String, packageName: String): AccessibilityNodeInfo? = roots().asSequence()
        // Framework text search stops at RemoteViews root namespaces; walk actual OS nodes.
        .flatMap { descendants(it) }
        .firstOrNull { it.packageName?.toString() == packageName && it.isVisibleToUser && it.text?.toString()?.equals(value, ignoreCase = true) == true }
    fun expandNotification(title: String): Boolean {
        var node = text(title, "com.android.systemui") ?: return false
        repeat(8) {
            val expand = descendants(node).firstOrNull { it.viewIdResourceName == "android:id/expand_button" && it.contentDescription?.toString() == "Expand" && it.isVisibleToUser }
            if (expand != null) { touch(expand); return true }
            node = node.parent ?: return false
        }
        return false
    }
    fun touch(node: AccessibilityNodeInfo) {
        val rect = Rect(); node.getBoundsInScreen(rect); check(!rect.isEmpty)
        val now = SystemClock.uptimeMillis()
        val down = MotionEvent.obtain(now, now, MotionEvent.ACTION_DOWN, rect.exactCenterX(), rect.exactCenterY(), 0)
        val up = MotionEvent.obtain(now, now + 60, MotionEvent.ACTION_UP, rect.exactCenterX(), rect.exactCenterY(), 0)
        down.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
        up.source = android.view.InputDevice.SOURCE_TOUCHSCREEN
        try { check(automation.injectInputEvent(down, true)); check(automation.injectInputEvent(up, true)) } finally { down.recycle(); up.recycle() }
    }
    fun settle() { automation.waitForIdle(350, 3000) }
    fun captureFailure(name: String) {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val dir = context.getExternalFilesDir(null)!!
        automation.takeScreenshot()?.also { bitmap -> java.io.File(dir, "$name.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle() }
        val rows = mutableListOf<String>()
        fun visit(node: AccessibilityNodeInfo) { rows.add("${node.packageName}: ${node.text} clickable=${node.isClickable}"); for (i in 0 until node.childCount) node.getChild(i)?.let(::visit) }
        roots().forEach(::visit)
        java.io.File(dir, "$name.txt").writeText(rows.joinToString("\n"))
    }
}

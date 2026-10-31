package dev.droidbridge.companion

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import android.content.Intent
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.TextView
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ReleaseDeliveryDeviceTest {
    private fun manifest() = JSONObject().put("version", "0.2.0").put("architecture", "arm64").put("minimum_macos", "26.0")
        .put("size_bytes", 30000000).put("sha256", "a".repeat(64)).put("signing", "ad_hoc_not_notarized")
        .put("download_url", "https://github.com/SloopWorks/DroidBridge/releases/download/v0.2.0/DroidBridge-0.2.0-arm64.dmg")
        .put("release_url", "https://github.com/SloopWorks/DroidBridge/releases/tag/v0.2.0")
    private fun rejected(bytes: ByteArray) { try { ReleaseDelivery.parse(bytes); fail("Invalid release metadata was accepted") } catch (_: IllegalArgumentException) {} }
    @Test fun exactVersionedMetadataAndWrongPlatformSourceBounds() {
        assertEquals(30000000L, ReleaseDelivery.parse(manifest().toString().toByteArray()).size)
        for ((key, value) in listOf("version" to "0.3.0", "architecture" to "x86_64", "minimum_macos" to "13.0", "signing" to "notarized", "sha256" to "A".repeat(64), "size_bytes" to 0, "size_bytes" to 268435457, "size_bytes" to 1.5, "download_url" to "https://github.com/attacker/DroidBridge/file.dmg")) {
            rejected(manifest().put(key, value).toString().toByteArray())
        }
    }
    @Test fun duplicateDeepAndMalformedUTF8MetadataReject() {
        rejected("{\"version\":\"0.2.0\",\"version\":\"0.2.0\"}".toByteArray())
        rejected(("[".repeat(20) + "0" + "]".repeat(20)).toByteArray())
        try { ReleaseDelivery.parse(byteArrayOf(0xc3.toByte(), 0x28)); fail("Malformed UTF8 accepted") } catch (_: java.nio.charset.CharacterCodingException) {}
    }
    @Test fun offlineLicenseViewerIncludesShippedComponentsAndCanClose() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, ThirdPartyActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        fun nodes(view: View): List<View> = listOf(view) + if (view is ViewGroup) (0 until view.childCount).flatMap { nodes(view.getChildAt(it)) } else emptyList()
        try {
            instrumentation.waitForIdleSync()
            instrumentation.runOnMainSync {
                val content = nodes(activity.window.decorView).filterIsInstance<TextView>().joinToString("\n") { it.text }
                for (required in listOf("ZXing Core 3.5.3", "Kotlin standard library 2.3.21", "IntelliJ IDEA annotations 13.0", "TERMS AND CONDITIONS")) assertTrue(required, content.contains(required))
                val done = nodes(activity.window.decorView).filterIsInstance<Button>().single { it.text == "Done" }
                assertTrue(done.isShown); done.performClick()
            }
        } finally { instrumentation.runOnMainSync { activity.finish() } }
    }
}

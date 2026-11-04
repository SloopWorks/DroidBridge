package dev.droidbridge.companion

import org.junit.Assert.*
import org.junit.Test

class QuickAccessStateTest {
    @Test fun serviceAvailabilityNeverClaimsAuthenticatedMacConnection() {
        assertEquals("Off", QuickAccessState.label(false, false))
        assertEquals("Off", QuickAccessState.label(false, true))
        assertEquals("Waiting for Mac", QuickAccessState.label(true, false))
        assertEquals("Connected", QuickAccessState.label(true, true))
    }
    @Test fun disconnectDescriptionPreservesIndependentVideoBoundary() {
        assertTrue(QuickAccessState.detail(false, false, "Mac", 2).contains("independent app video may continue"))
        assertEquals("Companion ready · waiting for authenticated Mac", QuickAccessState.detail(true, false, "Mac", 0))
        assertEquals("Studio · 1 app window", QuickAccessState.detail(true, true, "Studio", 1))
    }
}

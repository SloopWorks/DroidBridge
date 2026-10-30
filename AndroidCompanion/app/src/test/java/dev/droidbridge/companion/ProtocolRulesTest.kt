package dev.droidbridge.companion

import org.junit.Assert.*
import org.junit.Test

class ProtocolRulesTest {
    @Test fun contentLengthRejectsAmbiguousAndOversizedFraming() {
        listOf("-1", " 2", "262145", "1,1", "abc", "999999999999").forEach { invalid ->
            assertTrue(invalid, runCatching { ProtocolRules.contentLength(mapOf("content-length" to invalid)) }.isFailure)
        }
        assertTrue(runCatching { ProtocolRules.contentLength(mapOf("transfer-encoding" to "chunked")) }.isFailure)
        assertEquals(262144, ProtocolRules.contentLength(mapOf("content-length" to "262144")))
    }
    @Test fun generatedCapabilitiesHaveFullEntropyLengthAndUniqueBytes() {
        val tokens = (1..1000).map { ProtocolRules.token() }
        assertEquals(1000, tokens.toSet().size)
        tokens.forEach { assertTrue(it.matches(Regex("[A-Za-z0-9_-]{43}"))) }
        assertTrue(ProtocolRules.secureEqual(tokens[0], tokens[0])); assertFalse(ProtocolRules.secureEqual(tokens[0], tokens[1]))
    }
    @Test fun filenamesCannotEscapePrivateStorage() {
        assertEquals("report.txt", ProtocolRules.safeName("../../report.txt"))
        assertEquals("report.txt", ProtocolRules.safeName("C:\\private\\report.txt"))
        assertEquals("badname", ProtocolRules.safeName("bad\nname"))
        assertEquals("Shared file", ProtocolRules.safeName("")); assertEquals(120, ProtocolRules.safeName("a".repeat(500)).length)
    }
    @Test fun packageValidationRejectsArgumentsAndTraversal() {
        listOf("com.openai.chatgpt", "dev.droidbridge.testapp", "com.app_2.Main").forEach { assertTrue(ProtocolRules.packageName(it)) }
        listOf("com.app;id", "../app", "com.-x", "com", "com.app x", "").forEach { assertFalse(ProtocolRules.packageName(it)) }
    }
    @Test fun contentAddressesHaveKnownSha256() {
        assertEquals("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", ProtocolRules.hash("abc".toByteArray()))
    }
}

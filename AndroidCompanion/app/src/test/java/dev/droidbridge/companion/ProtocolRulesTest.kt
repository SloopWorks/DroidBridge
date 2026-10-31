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
    @Test fun catalogLabelsPreserveCjkAndSupplementaryScalarsAtTheWireBoundary() {
        // Previously 86 CJK scalars exceeded the consumer's incorrect 256-byte cap.
        val cjk = "界".repeat(86)
        assertEquals(258, cjk.toByteArray(Charsets.UTF_8).size)
        assertEquals(cjk, ProtocolRules.catalogLabel(cjk))
        assertEquals("界".repeat(256), ProtocolRules.catalogLabel("界".repeat(257)))
        val emoji = "\uD83D\uDE00"
        assertEquals(emoji.repeat(256), ProtocolRules.catalogLabel(emoji.repeat(257)))
        assertEquals("a".repeat(255) + emoji, ProtocolRules.catalogLabel("a".repeat(255) + emoji + "tail"))
        assertEquals("e\u0301".repeat(128), ProtocolRules.catalogLabel("e\u0301".repeat(129)))
        assertEquals("", ProtocolRules.catalogLabel(""))
    }

    @Test fun catalogLabelsReplaceMalformedUtf16WithoutPublishingSplitSurrogates() {
        val malformed = "a\uD83Db\uDE00c"
        assertEquals("a\uFFFDb\uFFFDc", ProtocolRules.catalogLabel(malformed))
        val boundary = ProtocolRules.catalogLabel("a".repeat(255) + "\uD83D" + "tail")
        assertEquals("a".repeat(255) + "\uFFFD", boundary)
        val bounded = ProtocolRules.catalogLabel("\uD83D\uDE00".repeat(1000))
        assertEquals(256, bounded.codePointCount(0, bounded.length))
        assertEquals(1024, bounded.toByteArray(Charsets.UTF_8).size)
        assertFalse(bounded.codePoints().anyMatch { it in 0xD800..0xDFFF })
    }

    @Test fun optionalActivityIdentityUsesUtf8BytesAndIsOmittedInsteadOfTruncated() {
        assertEquals("a".repeat(512), ProtocolRules.catalogActivityName("a".repeat(512)))
        assertNull(ProtocolRules.catalogActivityName("a".repeat(513)))
        assertEquals("界".repeat(170), ProtocolRules.catalogActivityName("界".repeat(170)))
        assertNull(ProtocolRules.catalogActivityName("界".repeat(171)))
        val emoji = "\uD83D\uDE00"
        assertEquals(emoji.repeat(128), ProtocolRules.catalogActivityName(emoji.repeat(128)))
        assertNull(ProtocolRules.catalogActivityName(emoji.repeat(129)))
        assertNull(ProtocolRules.catalogActivityName("dev.example.\uD83DActivity"))
    }

}

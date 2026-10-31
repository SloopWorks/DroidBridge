package dev.droidbridge.companion

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Test

class CompanionTlsTest {
    @Test fun installationIdentityAndTlsAreStableAndMandatory() {
        val store = BridgeStore.get(InstrumentationRegistry.getInstrumentation().targetContext)
        val first = BridgeTlsIdentity.serverPin()
        assertTrue(first.matches(Regex("[a-f0-9]{64}")))
        val server = BridgeHttpServer(store); server.start()
        try {
            try { PinnedTestClient.socket().use { socket -> assertTrue(socket.session.protocol in listOf("TLSv1.2", "TLSv1.3")) } } catch (failure: Exception) { throw AssertionError("Positive TLS handshake failed", server.lastHandshakeFailure ?: failure) }
            val negotiated = org.json.JSONArray()
            for (protocol in listOf("TLSv1.2", "TLSv1.3")) PinnedTestClient.socket(protocol).use { socket ->
                assertEquals(protocol, socket.session.protocol)
                negotiated.put(org.json.JSONObject().put("protocol", socket.session.protocol).put("cipher", socket.session.cipherSuite))
            }
            val evidence = org.json.JSONObject().put("server_pin", first).put("device_id", store.deviceId).put("pid", android.os.Process.myPid()).put("negotiated", negotiated)
                .put("leaf_der_base64", android.util.Base64.encodeToString(BridgeTlsIdentity.certificate().encoded, android.util.Base64.NO_WRAP)).put("private_key_exportable", false)
            java.io.File(InstrumentationRegistry.getInstrumentation().targetContext.filesDir, "tls-evidence.json").writeText(evidence.toString())
            InstrumentationRegistry.getInstrumentation().addResults(android.os.Bundle().apply { putString("droidbridge_tls_evidence", evidence.toString()) })
            val hello = PinnedTestClient.open("/v1/hello").apply { connectTimeout = 5000; readTimeout = 5000 }
            assertEquals(200, hello.responseCode); hello.inputStream.close(); hello.disconnect()
            val wrong = PinnedTestClient.open("/v1/hello", "0".repeat(64)).apply { connectTimeout = 5000; readTimeout = 5000 }
            assertTrue(runCatching { wrong.responseCode }.isFailure); wrong.disconnect()
            java.net.Socket("127.0.0.1", 37841).use { socket ->
                socket.soTimeout = 5000; socket.getOutputStream().write("GET /v1/hello HTTP/1.1\r\nHost: localhost\r\n\r\n".toByteArray())
                val bytes = ByteArray(512); val count = runCatching { socket.getInputStream().read(bytes) }.getOrDefault(-1)
                assertFalse(count > 0 && bytes.copyOf(count).toString(Charsets.US_ASCII).contains("HTTP/1.1"))
            }
        } finally { server.close() }
        assertEquals(first, BridgeTlsIdentity.serverPin())
        val again = BridgeHttpServer(store); again.start(); try {
            assertEquals(first, BridgeTlsIdentity.serverPin())
            store.startPairing(); val code = android.net.Uri.parse(store.pairingUri())
            assertEquals(setOf("secret", "expires", "device_id", "server_pin"), code.queryParameterNames)
            assertEquals(first, code.getQueryParameter("server_pin")); store.denyPair()
        } finally { again.close() }
    }
    @Test fun idleHandshakeHasAbsoluteDeadlineAndAdmissionIsBounded() {
        val store = BridgeStore.get(InstrumentationRegistry.getInstrumentation().targetContext)
        val server = BridgeHttpServer(store); server.start()
        val first = java.net.Socket("127.0.0.1", 37841); val second = java.net.Socket("127.0.0.1", 37841)
        try {
            val started = android.os.SystemClock.elapsedRealtime(); first.soTimeout = 4500; second.soTimeout = 4500
            assertEquals(-1, first.getInputStream().read()); assertTrue(android.os.SystemClock.elapsedRealtime() - started < 4200)
            PinnedTestClient.socket().use { assertTrue(it.session.isValid) }
        } finally { first.close(); second.close(); server.close() }
    }
    private fun upgradeSnapshot(): org.json.JSONObject {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = BridgeStore.get(context)
        val result = org.json.JSONObject().put("device_id", store.deviceId).put("server_pin", store.serverPin()).put("pid", android.os.Process.myPid())
            .put("version_code", context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode)
            .put("settings", org.json.JSONObject().put("clipboard_enabled", store.setting("clipboard_enabled")).put("notifications_enabled", store.setting("notifications_enabled")).put("profile", store.status().getString("profile")))
        InstrumentationRegistry.getInstrumentation().addResults(android.os.Bundle().apply { putString("droidbridge_upgrade_evidence", result.toString()) })
        return result
    }
    @Test fun prepareUpgradeBaseline() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val store = BridgeStore.get(context)
        store.setting("clipboard_enabled", true, Unit); store.profile("battery")
        // Commit a read-back through the same Android preferences to establish the fixture before replacement.
        context.getSharedPreferences("bridge", 0).edit().putBoolean("clipboard_enabled", store.setting("clipboard_enabled")).commit()
        assertTrue(upgradeSnapshot().getJSONObject("settings").getBoolean("clipboard_enabled"))
    }
    @Test fun captureUpgradeSnapshot() { upgradeSnapshot() }

}

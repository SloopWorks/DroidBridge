package dev.droidbridge.companion

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test
import org.junit.Assert.*
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/** Executes in the target process; uses public loopback HTTP and real Android package/icon APIs. */
@Suppress("DEPRECATION")
class CompanionDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    @Test fun testPairCatalogTrustRevocationAndFraming() {
        val store = BridgeStore.get(instrumentation.targetContext)
        store.refreshCatalog()
        val server = BridgeHttpServer(store); server.start()
        try {
            fun request(path: String, body: JSONObject? = null, auth: String? = null): Pair<Int, JSONObject> {
                val conn = PinnedTestClient.open(path)
                conn.connectTimeout = 3000; conn.readTimeout = 3000
                auth?.let { conn.setRequestProperty("Authorization", it) }
                if (body != null) { conn.requestMethod = "POST"; conn.doOutput = true; conn.setRequestProperty("Content-Type", "application/json"); conn.outputStream.use { it.write(body.toString().toByteArray()) } }
                val status = conn.responseCode
                val result = JSONObject((if (status < 400) conn.inputStream else conn.errorStream).bufferedReader().use { it.readText() }); conn.disconnect()
                return status to result
            }
            val hello = request("/v1/hello"); assertEquals(200, hello.first); assertEquals(1, hello.second.getJSONObject("data").getInt("protocol_max"))
            assertEquals(401, request("/v1/catalog").first)
            val secret = store.startPairing(); val mac = UUID.randomUUID().toString()
            val begin = request("/v1/pair", JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret).put("mac_id", mac).put("mac_name", "Device test Mac"))
            assertEquals(202, begin.first)
            val id = begin.second.getJSONObject("data").getString("pairing_id")
            assertEquals("pending", request("/v1/pair/$id", auth = "Pairing $secret").second.getJSONObject("data").getString("status"))
            store.approvePair()
            val paired = request("/v1/pair/$id", auth = "Pairing $secret").second.getJSONObject("data")
            assertEquals("approved", paired.getString("status")); val credential = paired.getString("credential")
            val catalog = request("/v1/catalog?limit=2", auth = "Bearer $credential")
            assertEquals(200, catalog.first); assertTrue(catalog.second.getJSONObject("data").getJSONArray("items").length() <= 2)
            val ping = JSONObject().put("request_id", UUID.randomUUID().toString()).put("kind", "ping").put("payload", JSONObject()).put("expires_at", java.time.Instant.now().plusSeconds(25).toString())
            assertEquals(200, request("/v1/commands", ping, "Bearer $credential").first)
            assertEquals(200, request("/v1/commands", ping, "Bearer $credential").first)
            store.revoke(paired.getString("trust_id"))
            assertEquals(401, request("/v1/catalog", auth = "Bearer $credential").first)
            // No credential should be present in ordinary preferences; encrypted trust remains app-private.
            assertFalse(instrumentation.targetContext.getSharedPreferences("bridge", 0).all.values.any { it.toString().contains(credential) })
        } finally { server.close() }
    }
    @Test fun testEpochMismatchAndDuplicateHeadersFailClosed() {
        val store = BridgeStore.get(instrumentation.targetContext)
        store.event("catalog_changed", JSONObject().put("revision", "test"))
        val reset = store.events(9999, 64, 0, "old-service-epoch")
        assertTrue(reset.getBoolean("reset_required"))
        val server = BridgeHttpServer(store); server.start()
        try {
            PinnedTestClient.socket().use { socket ->
                socket.soTimeout = 3000
                socket.getOutputStream().write("POST /v1/pair HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n{}".toByteArray())
                val status = socket.getInputStream().bufferedReader().readLine()
                assertTrue(status.contains("400"))
            }
        } finally { server.close() }
    }

}

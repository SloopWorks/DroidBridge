package dev.droidbridge.companion

import android.Manifest
import android.content.ComponentName
import android.content.pm.PackageManager
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.provider.Settings
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.UUID

/** Actual NotificationListener + separate ordinary test-APK UID + pinned-TLS commands/events. */
class CompanionRealNotificationDeviceTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val target get() = instrumentation.targetContext
    private val fixture = "dev.droidbridge.companion.test"
    private val component = ComponentName("dev.droidbridge.companion", "dev.droidbridge.companion.BridgeNotifications")
    private fun shell(command: String): String = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).use { it.readBytes().toString(Charsets.UTF_8) }
    private fun waitFor(message: String, check: () -> Boolean) {
        val until = SystemClock.elapsedRealtime() + 10_000
        while (!check() && SystemClock.elapsedRealtime() < until) Thread.sleep(60)
        assertTrue(message, check())
    }
    private fun request(path: String, token: String, body: JSONObject? = null): Pair<Int, JSONObject> {
        val c = PinnedTestClient.open(path); c.connectTimeout = 3000; c.readTimeout = 5000
        c.setRequestProperty("Authorization", "Bearer $token")
        if (body != null) { c.requestMethod = "POST"; c.doOutput = true; c.outputStream.use { it.write(body.toString().toByteArray()) } }
        val status = c.responseCode
        val data = JSONObject((if (status < 400) c.inputStream else c.errorStream).bufferedReader().use { it.readText() }); c.disconnect()
        return status to data
    }
    @Test fun actualListenerRemovesExcludedReplacementsAndFencesEveryNotificationCommand() {
        val store = BridgeStore.get(target)
        // Explicit owned-lab recovery only after a prior instrumentation-process crash.
        // Refuse touching any receiver other than this fixture's exact two names.
        if (InstrumentationRegistry.getArguments().getString("cleanup_notification_fixture") == "true") {
            val records = store.trusted()
            val stale = records.keys().asSequence().toList()
            require(stale.size <= 2 && stale.all { records.getJSONObject(it).optString("name") in setOf("Notification regression A", "Notification regression B") })
            stale.forEach { store.revoke(it) }; store.setting("notifications_enabled", false, Unit)
        }
        val originals = store.trusted().keys().asSequence().toSet(); val selected = store.selectedTrust()
        val oldSetting = store.setting("notifications_enabled")
        val oldListener = Settings.Secure.getString(target.contentResolver, "enabled_notification_listeners").orEmpty().split(':').any { ComponentName.unflattenFromString(it) == component }
        val oldPost = target.packageManager.checkPermission(Manifest.permission.POST_NOTIFICATIONS, fixture) == PackageManager.PERMISSION_GRANTED
        val token = UUID.randomUUID().toString(); val created = mutableListOf<String>()
        val server = BridgeHttpServer(store)
        fun pair(name: String): Pair<String, String> {
            val secret = store.startPairing()
            val begun = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret).put("mac_id", UUID.randomUUID().toString()).put("mac_name", name))
            val id = store.approvePair(begun.getString("pairing_id")).trustId
            val credential = store.pollPair(begun.getString("pairing_id"), secret).getString("credential")
            store.denyPair(); created.add(id); return credential to id
        }
        fun command(kind: String, payload: JSONObject) = clockedCommand(store, JSONObject().put("request_id", UUID.randomUUID().toString()).put("kind", kind).put("payload", payload))
        fun prefs(peer: Pair<String, String>, enabled: Boolean, packages: JSONArray = JSONArray().put(fixture)): JSONObject {
            val c = command("notification_preferences", JSONObject().put("expected_trust_id", peer.second).put("enabled", enabled).put("packages", packages))
            assertEquals(200, request("/v1/commands", peer.first, c).first); return c
        }
        fun post(mode: String, generation: Int) {
            val result = shell("am start -W -n $fixture/dev.droidbridge.companion.NotificationProbeActivity --es token $token --es mode $mode --ei generation $generation")
            assertTrue("Ordinary fixture Activity ran", result.contains("Status: ok"))
        }
        fun status(): Map<String, Int> = target.contentResolver.query(Uri.parse("content://$fixture.staging/notification-status/$token"), null, null, null, null)!!.use { c ->
            assertTrue(c.moveToFirst()); listOf("deliveries", "reply_generation", "active_count").associateWith { c.getInt(c.getColumnIndexOrThrow(it)) }
        }
        fun events(peer: Pair<String, String>): List<JSONObject> {
            val response = request("/v1/events?after=0&wait_ms=0", peer.first); assertEquals(200, response.first)
            val rows = response.second.getJSONObject("data").getJSONArray("events")
            return (0 until rows.length()).map { rows.getJSONObject(it) }.filter { it.getString("kind").startsWith("notification_") }
        }
        fun posted(peer: Pair<String, String>, generation: Int): JSONObject? = events(peer).lastOrNull { it.getString("kind") == "notification_posted" && it.getJSONObject("payload").optString("title") == "Notification probe $generation" }?.getJSONObject("payload")
        fun postSequence(peer: Pair<String, String>, generation: Int): Long = events(peer).last { it.getString("kind") == "notification_posted" && it.getJSONObject("payload").optString("title") == "Notification probe $generation" }.getLong("sequence")
        fun removed(peer: Pair<String, String>, key: String, after: Long = 0): Boolean = events(peer).any {
            it.getLong("sequence") > after && it.getString("kind") == "notification_removed" && it.getJSONObject("payload").optString("notification_key") == key &&
                it.getJSONObject("payload").keys().asSequence().toSet() == setOf("notification_key")
        }
        try {
            store.setting("notifications_enabled", true, Unit); server.start()
            assertTrue(store.hello().getJSONArray("capabilities").toString().contains("notification_scope_v2"))
            val a = pair("Notification regression A"); val b = pair("Notification regression B")
            prefs(a, true)
            if (!oldPost) instrumentation.uiAutomation.grantRuntimePermission(fixture, Manifest.permission.POST_NOTIFICATIONS)
            if (!oldListener) shell("cmd notification allow_listener ${component.flattenToString()}")
            post("public", 1)
            waitFor("Actual public notification traversed listener and TLS events") { posted(a, 1) != null }
            val first = posted(a, 1)!!; val key = first.getString("notification_key"); val action = first.getString("action_id")
            assertTrue("Never opted-in Mac sees no notification existence", events(b).isEmpty())
            val validPayloads = mapOf(
                "notification_preferences" to JSONObject().put("expected_trust_id", a.second).put("enabled", false).put("packages", JSONArray().put(fixture)),
                "notification_reply" to JSONObject().put("expected_trust_id", a.second).put("notification_key", key).put("action_id", action).put("text", "€".repeat(1365) + "x"),
                "dismiss_notification" to JSONObject().put("expected_trust_id", a.second).put("notification_key", key).put("action_id", action))
            for ((kind, original) in validPayloads) {
                val missing = JSONObject(original.toString()).apply { remove("expected_trust_id") }
                for (payload in listOf(missing, JSONObject(original.toString()).put("expected_trust_id", b.second), JSONObject(original.toString()).put("expected_trust_id", "not-a-uuid"))) {
                    val denied = request("/v1/commands", a.first, command(kind, payload))
                    assertEquals(409, denied.first); assertEquals("trust_changed", denied.second.getJSONObject("error").getString("code"))
                }
            }
            assertTrue("Mismatched preference had no effect", store.notificationsAllowed(a.second, fixture))
            assertEquals("Mismatched reply had no delivery", 0, status().getValue("deliveries"))
            assertEquals("Mismatched dismissal kept notification", 1, status().getValue("active_count"))
            val tooLarge = JSONObject(validPayloads.getValue("notification_reply").toString()).put("text", "€".repeat(1365) + "xx")
            assertEquals("4097UTF8 bytes rejected before RemoteInput", 400, request("/v1/commands", a.first, command("notification_reply", tooLarge)).first)
            assertEquals(0, status().getValue("deliveries"))
            val reply = command("notification_reply", validPayloads.getValue("notification_reply"))
            assertEquals(200, request("/v1/commands", a.first, reply).first)
            waitFor("Actual RemoteInput delivered once") { status().getValue("deliveries") == 1 }
            assertEquals(200, request("/v1/commands", a.first, reply).first)
            assertEquals(1, status().getValue("deliveries"))
            val cross = request("/v1/commands", b.first, reply)
            assertEquals(409, cross.first); assertEquals("trust_changed", cross.second.getJSONObject("error").getString("code"))
            val rewritten = JSONObject(reply.toString()).put("payload", JSONObject(reply.getJSONObject("payload").toString()).put("expected_trust_id", b.second))
            val replay = request("/v1/commands", b.first, rewritten)
            assertEquals(409, replay.first); assertEquals("request_conflict", replay.second.getJSONObject("error").getString("code"))
            post("public", 2); waitFor("Public replacement reached Mac A") { posted(a, 2) != null }
            val a2 = postSequence(a, 2)
            post("private", 3); waitFor("Private replacement removed prior public row") { removed(a, key, a2) }
            assertTrue("Private content never appears", events(a).none { it.getJSONObject("payload").toString().contains("private", true) })
            assertTrue("Never exposed Mac receives no private existence/removal", events(b).isEmpty())
            val stale = command("notification_reply", validPayloads.getValue("notification_reply"))
            assertEquals(400, request("/v1/commands", a.first, stale).first); assertEquals(1, status().getValue("deliveries"))
            prefs(b, true); post("public", 4)
            waitFor("Both recipients receive current public generation") { posted(a, 4) != null && posted(b, 4) != null }
            val a4 = postSequence(a, 4); val b4 = postSequence(b, 4)
            prefs(a, false)
            assertTrue("Opt-out cleanup passes even when content permission is off", removed(a, key, a4))
            assertNull("Opted-out content suppressed", posted(a, 4)); assertNotNull(posted(b, 4))
            prefs(b, true, JSONArray().put("com.android.settings"))
            assertTrue("Package-filter transition removes old row", removed(b, key, b4)); assertNull(posted(b, 4))
            prefs(a, true); prefs(b, true); post("public", 5)
            waitFor("Both recipients receive another generation") { posted(a, 5) != null && posted(b, 5) != null }
            val a5 = postSequence(a, 5); val b5 = postSequence(b, 5)
            post("ongoing", 6)
            waitFor("Ongoing exclusion removes both previous recipients") { posted(a, 5) == null && posted(b, 5) == null && removed(a, key, a5) && removed(b, key, b5) }
            post("public", 7); waitFor("Public generation before global disable") { posted(a, 7) != null && posted(b, 7) != null }
            val a7 = postSequence(a, 7); val b7 = postSequence(b, 7)
            store.setting("notifications_enabled", false, Unit)
            assertNull(posted(a, 7)); assertTrue(removed(a, key, a7)); assertTrue(removed(b, key, b7))
            store.setting("notifications_enabled", true, Unit); post("public", 8)
            waitFor("Public generation before listener revoke") { posted(a, 8) != null && posted(b, 8) != null }
            val a8 = postSequence(a, 8); val b8 = postSequence(b, 8); val previousAction = posted(a, 8)!!.getString("action_id")
            shell("cmd notification disallow_listener ${component.flattenToString()}")
            waitFor("Listener loss suppresses posts and cleans previous audience") { posted(a, 8) == null && removed(a, key, a8) && removed(b, key, b8) }
            shell("cmd notification allow_listener ${component.flattenToString()}")
            waitFor("Listener reconnect safely replays current public generation") { posted(a, 8) != null && posted(b, 8) != null }
            val latest = posted(b, 8)!!
            assertNotEquals("Reconnect never revives the previous action generation", previousAction, latest.getString("action_id"))
            val newA8 = postSequence(a, 8); val newB8 = postSequence(b, 8)
            val dismiss = command("dismiss_notification", JSONObject().put("expected_trust_id", b.second).put("notification_key", key).put("action_id", latest.getString("action_id")))
            assertEquals(200, request("/v1/commands", b.first, dismiss).first)
            waitFor("Actual scoped dismissal removes Android notification") { status().getValue("active_count") == 0 }
            assertTrue(removed(a, key, newA8)); assertTrue(removed(b, key, newB8))
            store.revoke(b.second)
            assertEquals("Revoked credential sees no events/metadata", 401, request("/v1/events?after=0&wait_ms=0", b.first).first)
            instrumentation.addResults(android.os.Bundle().apply { putString("droidbridge_notification_v2_evidence", JSONObject()
                .put("actual_android_listener", true).put("separate_ordinary_fixture_uid", true).put("pinned_tls_commands_events", true)
                .put("missing_wrong_scope_rejected_all_three_kinds", true).put("cross_trust_replay_rejected", true).put("reply_deliveries", status().getValue("deliveries")).put("utf8_4097_rejected_without_effect", true).put("utf8_4096_delivered_once", true)
                .put("private_replacement_cleanup", true).put("never_exposed_removal_leak", false).put("two_recipient_ongoing_cleanup", true)
                .put("optout_filter_global_listener_cleanup", true).put("scoped_dismissal", true).put("revoked_events_status", 401).toString()) })
        } finally {
            runCatching { post("cancel", 99) }
            if (!oldListener) shell("cmd notification disallow_listener ${component.flattenToString()}")
            created.forEach { if (store.trusted().has(it)) store.revoke(it) }
            selected?.let { store.selectTrust(it) }; store.setting("notifications_enabled", oldSetting, Unit); store.denyPair()
            server.close()
            if (!oldPost) instrumentation.uiAutomation.revokeRuntimePermission(fixture, Manifest.permission.POST_NOTIFICATIONS)
            assertEquals(originals, store.trusted().keys().asSequence().toSet()); assertEquals(selected, store.selectedTrust())
        }
    }
}

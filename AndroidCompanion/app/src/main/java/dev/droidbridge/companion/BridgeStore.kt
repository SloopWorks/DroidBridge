package dev.droidbridge.companion

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.BatteryManager
import android.os.PowerManager
import android.provider.Settings
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.LinkedHashMap

class BridgeStore private constructor(val context: Context) {
    private val tlsContext = BridgeTlsIdentity.configure(context.applicationContext)
    private val prefs = context.getSharedPreferences("bridge", Context.MODE_PRIVATE)
    private val credentials = SecurePreferences(context)
    private val phoneJournal = SecureJournal(context, "phone-commands", 262144)
    private val outcomes = LinkedHashMap<String, JSONObject>()
    private val peerStates = java.util.concurrent.ConcurrentHashMap<String, JSONObject>()
    private var phoneJournalHealthy = true
    private val receivedJournal = SecureJournal(context, "received-text", 524288)
    private val received = LinkedHashMap<String, JSONObject>()
    private var receivedHealthy = true
    private val eventLock = java.lang.Object()
    private val events = ArrayDeque<JSONObject>()
    private var sequence = 0L
    private val epoch = java.util.UUID.randomUUID().toString()
    private var pairingSecret: String? = null
    private var pairingDeadline = 0L
    private var pendingPair: JSONObject? = null
    private var pairWindowStart = 0L
    private var pairAttempts = 0
    private val receiptsFile = File(context.filesDir, "command-receipts.json")
    private data class CatalogView(val generation: String, val items: JSONArray, val source: String, val selection: Long)
    private val catalogViews = LinkedHashMap<String, ArrayDeque<CatalogView>>()
    private val commandReceipts = LinkedHashMap<String, String>()
    private var eventBytes = 0
    private var receiptsHealthy = true
    init {
        runCatching {
            receivedJournal.read()?.let { val array = JSONArray(it); require(array.length() <= 8); for (i in 0 until array.length()) { val item = array.getJSONObject(i); received[item.getString("event_id")] = item } }
        }.onFailure { receivedHealthy = false }
        runCatching {
            phoneJournal.read()?.let { encoded ->
                val stored = JSONArray(encoded); require(stored.length() <= 32)
                for (i in 0 until stored.length()) {
                    val value = stored.getJSONObject(i); val id = value.getString("request_id")
                    require(runCatching { java.util.UUID.fromString(id) }.isSuccess)
                    val expiry = java.time.Instant.parse(value.getString("expires_at"))
                    if (value.getString("status") in listOf("queued", "accepted")) {
                        if (expiry.isAfter(java.time.Instant.now())) event("command", value.getJSONObject("command"), value.getString("trust_id"))
                        else value.put("status", "expired")
                    }
                    outcomes[id] = value
                }
            }
        }.onFailure { phoneJournalHealthy = false }
        runCatching {
            if (!receiptsFile.exists()) return@runCatching
            require(receiptsFile.length() <= 262_144)
            val saved = JSONObject(receiptsFile.readText())
            require(saved.length() <= 512)
            saved.keys().asSequence().take(512).forEach { commandId -> commandReceipts[commandId] = saved.getString(commandId) }
        }.onFailure { receiptsHealthy = false }
    }


    val transfers by lazy { BridgeTransfers(context, this) }
    @Volatile var running = false
    @Volatile var lastError: String? = null
    val state: JSONObject get() = peerStatus()
    @Volatile private var apps = JSONArray()
    @Volatile private var revision = "empty"
    private val icons = object : LinkedHashMap<String, ByteArray>(128, .75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ByteArray>?) = size > 128
    }
    val deviceId: String = prefs.getString("device_id", null) ?: java.util.UUID.randomUUID().toString().also { prefs.edit().putString("device_id", it).apply() }
    fun setting(name: String, default: Boolean = false) = prefs.getBoolean(name, default)
    fun setting(name: String, value: Boolean, unused: Unit = Unit) { prefs.edit().putBoolean(name, value).apply() }
    @Synchronized fun startPairing(): String {
        pendingPair = null; pairingSecret = ProtocolRules.token(); pairingDeadline = android.os.SystemClock.elapsedRealtime() + 120_000
        return pairingSecret!!
    }
    fun serverPin(): String = BridgeTlsIdentity.serverPin()
    @Synchronized fun pairingUri(): String {
        val secret = pairing() ?: throw IllegalStateException("Open a pairing window first")
        val expires = System.currentTimeMillis() / 1000 + ((pairingDeadline - android.os.SystemClock.elapsedRealtime()) / 1000)
        return "droidbridge://pair?secret=$secret&expires=$expires&device_id=$deviceId&server_pin=${serverPin()}"
    }
    @Synchronized fun pairing(): String? = pairingSecret?.takeIf { android.os.SystemClock.elapsedRealtime() < pairingDeadline }
    @Synchronized private fun issueCredential(secret: String, macId: String, name: String): JSONObject {
        require(ProtocolRules.identifier(macId) && name.length in 1..80) { "Invalid Mac identity" }
        val active = pairing() ?: throw SecurityException("Enable pairing on phone")
        if (!ProtocolRules.secureEqual(active, secret)) throw SecurityException("Pairing denied")
        val trusted = JSONObject(credentials.read())
        require(trusted.length() < 8) { "Trusted Mac capacity reached" }
        require(trusted.keys().asSequence().none { trusted.getJSONObject(it).optString("mac_id") == macId }) { "Mac identity already paired; forget before replacing" }
        val trustId = java.util.UUID.randomUUID().toString()
        val credential = ProtocolRules.token()
        trusted.put(trustId, JSONObject().put("name", name).put("mac_id", macId).put("credential", credential).put("notifications", false))
        credentials.write(trusted.toString())
        return JSONObject().put("credential", credential).put("trust_id", trustId).put("device_id", deviceId).put("protocol", 1).put("capabilities", hello().getJSONArray("capabilities"))
    }

    @Synchronized fun requestPair(request: JSONObject): JSONObject {
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - pairWindowStart >= 60_000) { pairWindowStart = now; pairAttempts = 0 }
        require(pairAttempts++ < 5) { "Pairing rate limit" }
        val secret = request.getString("pairing_secret")
        if (pairing() == null || !ProtocolRules.secureEqual(pairing()!!, secret)) {
            if (pairAttempts >= 5) { pairingSecret = null; pendingPair = null }
            throw SecurityException("Pairing denied")
        }
        val macId = request.getString("mac_id"); val name = request.getString("mac_name")
        require(runCatching { java.util.UUID.fromString(macId) }.isSuccess && name.length in 1..80)
        val existing = pendingPair
        if (existing != null) {
            require(existing.getString("mac_id") == macId && existing.getString("request_id") == request.getString("request_id")) { "Pairing in progress" }
            return JSONObject().put("pairing_id", existing.getString("pairing_id")).put("status", "pending").put("expires_at", existing.getString("expires_at"))
        }
        val id = java.util.UUID.randomUUID().toString()
        val expiry = java.time.Instant.now().plusMillis(pairingDeadline - now).toString()
        val comparison = ProtocolRules.hash((secret + ":" + macId).toByteArray()).take(8).uppercase()
        pendingPair = JSONObject().put("pairing_id", id).put("request_id", request.getString("request_id")).put("mac_id", macId).put("mac_name", name).put("expires_at", expiry).put("status", "pending").put("comparison_code", comparison)
        return JSONObject().put("pairing_id", id).put("status", "pending").put("expires_at", expiry).put("comparison_code", comparison)
    }
    @Synchronized fun pendingPair(): JSONObject? = pendingPair?.takeIf { pairing() != null && it.optString("status") == "pending" }
    @Synchronized fun approvePair() {
        val pending = pendingPair ?: return
        val secret = pairing() ?: return
        val credential = issueCredential(secret, pending.getString("mac_id"), pending.getString("mac_name"))
        pending.put("status", "approved").put("response", credential)
    }
    @Synchronized fun denyPair() { pendingPair = null; pairingSecret = null }
    @Synchronized fun pollPair(id: String, secret: String): JSONObject {
        val current = pairing() ?: throw SecurityException("Pairing expired")
        if (!ProtocolRules.secureEqual(current, secret)) throw SecurityException("Pairing denied")
        val pending = pendingPair ?: throw SecurityException("Pairing unavailable")
        require(pending.getString("pairing_id") == id)
        return if (pending.getString("status") == "approved") JSONObject(pending.getJSONObject("response").toString()).put("status", "approved") else JSONObject().put("status", "pending")
    }
    @Synchronized fun trustPublic(requestingTrust: String? = null): JSONObject {
        val records = trusted()
        return JSONObject().put("items", JSONArray(records.keys().asSequence().filter { requestingTrust == null || it == requestingTrust }.map { JSONObject().put("trust_id", it).put("mac_name", records.getJSONObject(it).getString("name")) }.toList()))
    }
    @Synchronized fun authenticate(token: String): String? {
        if (token.length != 43) return null
        val trusted = JSONObject(credentials.read())
        return trusted.keys().asSequence().firstOrNull { ProtocolRules.secureEqual(trusted.getJSONObject(it).getString("credential"), token) }
    }
    fun trusted(): JSONObject = JSONObject(credentials.read())
    @Synchronized fun revoke(macId: String) {
        val value = trusted(); value.remove(macId); credentials.write(value.toString())
        peerStates.remove(macId); catalogViews.remove(macId)
        received.entries.removeAll { it.value.getString("trust_id") == macId }; runCatching { receivedJournal.write(JSONArray(received.values.toList()).toString()) }
        outcomes.values.filter { it.getString("trust_id") == macId && it.getString("status") in listOf("queued", "accepted") }.forEach { it.put("status", "rejected").put("error_code", "trust_revoked") }
        runCatching { savePhoneCommands(); transfers.revoke(macId) }.onFailure { lastError = "Revoked trust; staged cleanup requires retry." }
        synchronized(eventLock) { val retained = events.filter { it.optString("target_trust_id") != macId }; events.clear(); events.addAll(retained); eventBytes = events.sumOf { it.toString().toByteArray().size }; eventLock.notifyAll() }
    }

    fun hello(): JSONObject = JSONObject().put("protocol_min", 1).put("protocol_max", 1).put("device_id", deviceId)
        .put("device_name", "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}")
        .put("capabilities", JSONArray(listOf("catalog", "icons", "events", "commands", "sessions", "share", "files", "clipboard", "notifications", "notification_replies", "profiles", "diagnostics", "delivery", "state_heartbeat")))
        .put("catalog_revision", revision).put("pairing_available", pairing() != null).put("permissions", JSONObject().put("notifications", setting("notifications_enabled").toString()).put("clipboard", setting("clipboard_enabled").toString()))
    fun event(kind: String, payload: JSONObject, recipient: String? = null): Long = synchronized(eventLock) {
        require(payload.toString().toByteArray().size <= 70_000)
        val seq = ++sequence
        val item = JSONObject().put("sequence", seq).put("event_id", java.util.UUID.randomUUID().toString()).put("kind", kind).put("payload", payload).put("created_at", java.time.Instant.now().toString()).put("target_trust_id", recipient ?: JSONObject.NULL)
        events.addLast(item); eventBytes += item.toString().toByteArray().size
        while (events.size > 512 || eventBytes > 1_048_576) eventBytes -= events.removeFirst().toString().toByteArray().size
        eventLock.notifyAll()
        seq
    }
    fun events(after: Long, limit: Int, waitMs: Long = 0, requestedEpoch: String? = null, trustId: String? = null): JSONObject = synchronized(eventLock) {
        require(after >= 0 && limit in 1..64 && waitMs in 0..25_000)
        if (sequence <= after && waitMs > 0 && (requestedEpoch == null || requestedEpoch == epoch)) eventLock.wait(waitMs)
        val mismatch = requestedEpoch != null && requestedEpoch != epoch
        val gap = mismatch || (events.firstOrNull()?.getLong("sequence")?.let { after < it - 1 || after > sequence } ?: (after > sequence))
        val selected = JSONArray(); var bytes = 0; var next = if (mismatch) 0 else after
        for (event in events) {
            if (!mismatch && event.getLong("sequence") <= after) continue
            val target = event.optString("target_trust_id", "")
            if (trustId != null && target.isNotEmpty() && target != trustId) { next = event.getLong("sequence"); continue }
            if (trustId != null && event.getString("kind").startsWith("notification_") && !notificationsAllowed(trustId)) { next = event.getLong("sequence"); continue }
            val length = event.toString().toByteArray().size
            if (selected.length() >= limit || bytes + length > 240_000) break
            selected.put(event); bytes += length; next = event.getLong("sequence")
        }
        JSONObject().put("events", selected).put("epoch", epoch).put("next_sequence", next).put("reset_required", gap)
    }
    fun selectedTrust(): String? = prefs.getString("selected_trust", null)?.takeIf { trusted().has(it) } ?: trusted().keys().asSequence().singleOrNull()
    fun selectTrust(id: String) { require(trusted().has(id)); prefs.edit().putString("selected_trust", id).apply() }
    fun notificationsAllowed(id: String, packageName: String? = null): Boolean {
        val record = trusted().optJSONObject(id) ?: return false
        if (!setting("notifications_enabled") || !record.optBoolean("notifications", false)) return false
        val selected = record.optJSONArray("notification_packages") ?: return true
        return packageName == null || selected.length() == 0 || (0 until selected.length()).any { selected.getString(it) == packageName }
    }
    @Synchronized fun allowNotifications(id: String, allowed: Boolean) { val value = trusted(); value.getJSONObject(id).put("notifications", allowed); credentials.write(value.toString()) }
    @Synchronized fun refreshCatalog() {
        val pm = context.packageManager
        val intent = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val records = pm.queryIntentActivities(intent, PackageManager.ResolveInfoFlags.of(0)).groupBy { it.activityInfo.packageName }
            .toSortedMap().entries.take(4096).map { (pkg, candidates) ->
                val activity = candidates.minBy { it.activityInfo.name }
                val drawable = activity.loadIcon(pm)
                val bitmap = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888)
                drawable.setBounds(0, 0, 128, 128); drawable.draw(Canvas(bitmap))
                val output = ByteArrayOutputStream(); bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle()
                val data = output.toByteArray(); val hash = ProtocolRules.hash(data)
                synchronized(icons) { icons[hash] = data }
                JSONObject().put("package_name", pkg).put("label", activity.loadLabel(pm).toString().take(256))
                    .put("activity_name", activity.activityInfo.name).put("icon_sha256", hash).put("export_to_mac", true).put("version_code", pm.getPackageInfo(pkg, 0).longVersionCode).put("launchable", true)
            }
        val json = JSONArray(records); val next = ProtocolRules.hash(json.toString().toByteArray())
        apps = json
        if (next != revision) { revision = next; event("catalog_changed", JSONObject().put("revision", revision)) }
    }
    private fun repairExportIntents(trustId: String) {
        var current = prefs.getLong("selection_revision_$trustId", 0)
        val excluded = (prefs.getStringSet("excluded_$trustId", emptySet()) ?: emptySet()).toMutableSet()
        var changed = false
        for (outcome in outcomes.values.filter { it.getString("trust_id") == trustId && it.getString("kind") == "set_export" }) {
            val payload = outcome.getJSONObject("command").getJSONObject("payload")
            val revision = payload.optLong("selection_revision", 0)
            if (revision > current) { val pkg = payload.getString("package_name"); if (payload.getBoolean("selected")) excluded.remove(pkg) else excluded.add(pkg); current = revision; changed = true }
        }
        if (changed) check(prefs.edit().putStringSet("excluded_$trustId", excluded).putLong("selection_revision_$trustId", current).commit())
    }
    @Synchronized private fun catalogView(trustId: String?): CatalogView {
        if (trustId != null) repairExportIntents(trustId)
        val key = trustId ?: "unpaired"
        val selection = if (trustId == null) 0 else prefs.getLong("selection_revision_$trustId", 0)
        val history = catalogViews.getOrPut(key) { ArrayDeque() }
        history.lastOrNull()?.takeIf { it.source == revision && it.selection == selection }?.let { return it }
        val excluded = if (trustId == null) emptySet() else prefs.getStringSet("excluded_$trustId", emptySet()) ?: emptySet()
        val generation = ProtocolRules.hash((revision + ":" + key + ":" + selection).toByteArray())
        val items = JSONArray((0 until apps.length()).map { i -> JSONObject(apps.getJSONObject(i).toString()).apply { put("export_to_mac", getString("package_name") !in excluded) } })
        val view = CatalogView(generation, items, revision, selection); history.addLast(view)
        while (history.size > 2) history.removeFirst()
        while (catalogViews.size > 9) catalogViews.remove(catalogViews.keys.first())
        return view
    }
    @Synchronized fun catalog(cursor: String, limit: Int, trustId: String? = selectedTrust()): JSONObject {
        val snapshot = catalogView(trustId); val parts = cursor.split(':')
        if (cursor.isNotEmpty() && (parts.size != 2 || parts[0] != snapshot.generation)) throw BridgeFailure(409, "stale_cursor")
        val offset = if (cursor.isEmpty()) 0 else parts[1].toInt()
        require(offset >= 0 && offset <= snapshot.items.length() && limit in 1..64)
        val values = JSONArray()
        for (i in offset until minOf(offset + limit, snapshot.items.length())) values.put(snapshot.items.getJSONObject(i))
        return JSONObject().put("generation", snapshot.generation).put("items", values).put("next_cursor", if (offset + limit < snapshot.items.length()) "${snapshot.generation}:${offset + limit}" else JSONObject.NULL)
    }
    @Synchronized fun catalogChanges(after: String, trustId: String? = selectedTrust()): JSONObject {
        val currentView = catalogView(trustId)
        if (after == currentView.generation) return JSONObject().put("generation", currentView.generation).put("items", JSONArray()).put("deleted", JSONArray())
        val oldView = catalogViews[trustId ?: "unpaired"]?.firstOrNull { it.generation == after } ?: throw BridgeFailure(409, "stale_cursor")
        fun mapped(array: JSONArray) = (0 until array.length()).associate { array.getJSONObject(it).getString("package_name") to array.getJSONObject(it) }
        val old = mapped(oldView.items); val current = mapped(currentView.items)
        val changed = current.values.filter { old[it.getString("package_name")]?.toString() != it.toString() }; val deleted = old.keys - current.keys
        if (changed.size + deleted.size > 64) throw BridgeFailure(409, "stale_cursor")
        return JSONObject().put("generation", currentView.generation).put("items", JSONArray(changed)).put("deleted", JSONArray(deleted.toList()))
    }
    private fun savePhoneCommands() { phoneJournal.write(JSONArray(outcomes.values.toList()).toString()) }
    @Synchronized fun phoneCommand(kind: String, payload: JSONObject, recipientTrustId: String? = null): String {
        if (!phoneJournalHealthy) throw BridgeFailure(503, "phone_command_journal_unavailable")
        val trust = recipientTrustId ?: selectedTrust() ?: throw IllegalArgumentException("Choose a trusted Mac first")
        require(trusted().has(trust))
        require(kind in listOf("open_app", "stop_session", "set_audio_route", "set_profile", "clipboard_text", "share_text", "share_url", "set_screen_power", "set_export", "retry_audio"))
        require(payload.toString().toByteArray().size <= 65536)
        when (kind) {
            "open_app" -> require(ProtocolRules.packageName(payload.getString("package_name")))
            "stop_session" -> require(runCatching { java.util.UUID.fromString(payload.getString("session_id")) }.isSuccess)
            "set_audio_route" -> require(payload.getString("route") in listOf("mac", "phone", "mac_and_phone"))
            "set_profile" -> require(payload.getString("profile") in listOf("balanced", "responsive", "battery"))
            "set_screen_power" -> require(payload.get("off") is Boolean)
            "set_export" -> { require(ProtocolRules.packageName(payload.getString("package_name"))); require(payload.get("selected") is Boolean) }
            "clipboard_text", "share_text" -> require(payload.getString("text").toByteArray().size <= 65536)
            "share_url" -> { val url = payload.optString("url", payload.optString("text")); require(url.length <= 8192 && android.net.Uri.parse(url).scheme in listOf("http", "https")) }
        }
        repairExportIntents(trust)
        expireOutcomes()
        if (outcomes.size >= 32) {
            val removable = outcomes.entries.firstOrNull { it.value.getString("status") !in listOf("queued", "accepted") }?.key
                ?: throw BridgeFailure(429, "phone_command_capacity")
            outcomes.remove(removable)
        }
        val id = java.util.UUID.randomUUID().toString(); val now = java.time.Instant.now()
        val command = JSONObject().put("request_id", id).put("kind", kind).put("payload", payload).put("expires_at", now.plusSeconds(30).toString())
        val value = JSONObject().put("request_id", id).put("kind", kind).put("trust_id", trust).put("status", "queued")
            .put("created_at", now.toString()).put("expires_at", now.plusSeconds(30).toString()).put("command", command)
        outcomes[id] = value
        try { savePhoneCommands() } catch (failure: Exception) { outcomes.remove(id); throw BridgeFailure(429, "phone_command_byte_capacity") }
        event("command", command, trust)
        return id
    }
    private fun expireOutcomes() {
        val now = java.time.Instant.now()
        outcomes.values.filter { it.getString("status") in listOf("queued", "accepted") && !java.time.Instant.parse(it.getString("expires_at")).isAfter(now) }
            .forEach { it.put("status", "expired") }
    }
    @Synchronized fun commandOutcomes(): JSONArray {
        expireOutcomes()
        return JSONArray(outcomes.values.map { value -> JSONObject(value.toString()).apply { remove("command"); remove("receipt_hash") } })
    }
    @Synchronized fun commandReceipt(id: String, request: JSONObject, trustId: String): JSONObject {
        val value = outcomes[id] ?: throw BridgeFailure(409, "unknown_phone_command")
        if (value.getString("trust_id") != trustId) throw SecurityException("Wrong command recipient")
        require(request.getString("request_id") == id)
        require(request.getString("status") in listOf("accepted", "applied", "rejected", "unknown"))
        val hash = ProtocolRules.hash(canonical(request).toByteArray())
        if (value.has("receipt_hash") && value.getString("status") != "accepted") {
            if (value.getString("receipt_hash") != hash) throw BridgeFailure(409, "receipt_conflict")
            return JSONObject().put("accepted", true).put("command_id", id).put("status", value.getString("status"))
        }
        expireOutcomes()
        if (value.getString("status") == "expired") throw BridgeFailure(409, "phone_command_expired")
        val status = request.getString("status")
        val previous = JSONObject(value.toString())
        value.put("receipt_hash", hash).put("status", status).put("error_code", request.optString("error_code", request.optJSONObject("result")?.optString("code", "") ?: "").take(80))
        try { savePhoneCommands() } catch (failure: Exception) { outcomes[id] = previous; throw BridgeFailure(503, "receipt_persistence_failed") }
        // // Receipt publication follows durable original outcome.
        return JSONObject().put("accepted", true).put("command_id", id).put("status", status)
    }
    @Synchronized fun updatePeerState(trustId: String, request: JSONObject): JSONObject {
        // Serialize with revoke(): an earlier HTTP authentication must not
        // publish a new dashboard snapshot after its trust was removed.
        if (!trusted().has(trustId)) throw SecurityException("Trust revoked")
        if (request.has("unchanged")) {
            require(request.get("unchanged") is Boolean && request.getBoolean("unchanged"))
            require(request.keys().asSequence().all { it in setOf("request_id", "protocol", "unchanged") })
            val previous = peerStates[trustId] ?: throw BridgeFailure(409, "snapshot_required")
            val refreshed = JSONObject(previous.toString()).put("last_seen_elapsed", android.os.SystemClock.elapsedRealtime()).put("last_seen_at", java.time.Instant.now().toString())
            peerStates[trustId] = refreshed
            return JSONObject().put("accepted", true).put("unchanged", true)
        }
        val sessions = request.optJSONArray("sessions") ?: JSONArray(); require(sessions.length() <= 32)
        for (i in 0 until sessions.length()) {
            val session = sessions.getJSONObject(i)
            require(runCatching { java.util.UUID.fromString(session.getString("session_id")) }.isSuccess)
            require(ProtocolRules.packageName(session.getString("package_name")))
        }
        val value = JSONObject(request.toString()).put("last_seen_elapsed", android.os.SystemClock.elapsedRealtime()).put("last_seen_at", java.time.Instant.now().toString())
        peerStates[trustId] = value
        return JSONObject().put("accepted", true)
    }
    fun peerStatus(): JSONObject {
        val trust = selectedTrust()
        val record = trust?.let { trusted().optJSONObject(it) }
        val snapshot = trust?.let { peerStates[it] }
        val fresh = snapshot != null && android.os.SystemClock.elapsedRealtime() - snapshot.getLong("last_seen_elapsed") in 0..15000
        val result = JSONObject().put("trust_id", trust ?: JSONObject.NULL).put("mac_name", record?.optString("name") ?: JSONObject.NULL)
            .put("connected", running && fresh && snapshot?.optString("connection_state", "connected") == "connected")
            .put("sessions", if (fresh) snapshot?.optJSONArray("sessions") ?: JSONArray() else JSONArray())
        if (snapshot != null) { result.put("last_seen_at", snapshot.getString("last_seen_at")); listOf("audio_route", "audio_status", "profile").forEach { key -> if (snapshot.has(key)) result.put(key, snapshot.get(key)) } }
        return result
    }
    fun catalogLocal(): JSONArray = catalogView(selectedTrust()).items
    fun catalogRevisionLocal(): String = catalogView(selectedTrust()).generation
    @Synchronized fun chooseExport(pkg: String, enabled: Boolean, trustId: String = selectedTrust() ?: throw IllegalArgumentException("Choose a trusted Mac")): String {
        require(ProtocolRules.packageName(pkg) && trusted().has(trustId))
        val revision = prefs.getLong("selection_revision_$trustId", 0) + 1
        val payload = JSONObject().put("package_name", pkg).put("selected", enabled).put("selection_revision", revision)
        val request = phoneCommand("set_export", payload, trustId)
        applyExportLocal(pkg, enabled, trustId, request, revision)
        return request
    }
    private fun applyExportLocal(pkg: String, enabled: Boolean, trustId: String, requestId: String, requestedRevision: Long? = null): JSONObject {
        val current = prefs.getLong("selection_revision_$trustId", 0)
        val revision = requestedRevision ?: (current + 1)
        if (revision < current) throw BridgeFailure(409, "stale_selection")
        val excluded = (prefs.getStringSet("excluded_$trustId", emptySet()) ?: emptySet()).toMutableSet()
        if (enabled) excluded.remove(pkg) else excluded.add(pkg)
        check(prefs.edit().putStringSet("excluded_$trustId", excluded).putLong("selection_revision_$trustId", revision).commit())
        val result = JSONObject().put("package_name", pkg).put("selected", enabled).put("generation", catalogView(trustId).generation).put("request_id", requestId).put("selection_revision", revision)
        event("catalog_preferences", result, trustId)
        return result
    }
    fun icon(hash: String): ByteArray? {
        require(hash.matches(Regex("[a-f0-9]{64}")))
        synchronized(icons) { icons[hash]?.let { return it } }
        // The bounded memory cache may evict an icon; recreate only the exact catalog-bound drawable.
        val records = apps
        for (i in 0 until records.length()) {
            val app = records.getJSONObject(i)
            if (app.getString("icon_sha256") == hash) {
                val drawable = context.packageManager.getActivityIcon(android.content.ComponentName(app.getString("package_name"), app.getString("activity_name")))
                val bitmap = Bitmap.createBitmap(128, 128, Bitmap.Config.ARGB_8888)
                drawable.setBounds(0, 0, 128, 128); drawable.draw(Canvas(bitmap))
                val output = ByteArrayOutputStream(); bitmap.compress(Bitmap.CompressFormat.PNG, 100, output); bitmap.recycle()
                return output.toByteArray().takeIf { ProtocolRules.hash(it) == hash }
            }
        }
        return null
    }
    private fun expireReceived() {
        val now = java.time.Instant.now()
        received.entries.removeAll { (_, item) -> runCatching { java.time.Instant.parse(item.getString("created_at")).isBefore(now.minusSeconds(1800)) }.getOrDefault(true) }
    }
    @Synchronized private fun receiveText(trustId: String, text: String) {
        if (!receivedHealthy) throw BridgeFailure(503, "received_text_journal_unavailable")
        expireReceived()
        val id = java.util.UUID.randomUUID().toString()
        val item = JSONObject().put("event_id", id).put("trust_id", trustId).put("created_at", java.time.Instant.now().toString()).put("text", text)
        received[id] = item
        while (received.size > 8 || JSONArray(received.values.toList()).toString().toByteArray().size > 524288) received.remove(received.keys.first())
        receivedJournal.write(JSONArray(received.values.toList()).toString())
        event("clipboard_received", JSONObject().put("event_id", id), trustId)
    }
    @Synchronized fun receivedTexts(): JSONArray {
        expireReceived(); val trust = selectedTrust()
        return JSONArray(received.values.filter { it.getString("trust_id") == trust }.map { JSONObject(it.toString()) })
    }
    @Synchronized fun clearReceivedText(eventId: String) {
        require(runCatching { java.util.UUID.fromString(eventId) }.isSuccess)
        received.remove(eventId); receivedJournal.write(JSONArray(received.values.toList()).toString())
    }
    private fun canonical(value: Any?): String = when (value) {
        is JSONObject -> value.keys().asSequence().sorted().joinToString(prefix = "{", postfix = "}") { JSONObject.quote(it) + ":" + canonical(value.get(it)) }
        is JSONArray -> (0 until value.length()).joinToString(prefix = "[", postfix = "]") { canonical(value.get(it)) }
        is String -> JSONObject.quote(value)
        else -> value.toString()
    }
    private fun persistReceipts() {
        val saved = JSONObject(); commandReceipts.forEach { (key, value) -> saved.put(key, value) }
        val temporary = File(context.filesDir, "command-receipts.tmp")
        java.io.FileOutputStream(temporary).use { it.write(saved.toString().toByteArray()); it.fd.sync() }
        check(temporary.renameTo(receiptsFile))
    }
    @Synchronized fun command(request: JSONObject, trustId: String): JSONObject {
        if (!receiptsHealthy) throw BridgeFailure(503, "receipt_store_unavailable")
        val id = request.getString("request_id"); require(runCatching { java.util.UUID.fromString(id) }.isSuccess)
        val hash = ProtocolRules.hash((trustId + ":" + canonical(request)).toByteArray())
        commandReceipts[id]?.let {
            val receipt = JSONObject(it); if (receipt.getString("hash") != hash) throw BridgeFailure(409, "request_conflict")
            return JSONObject().put("accepted", true).put("request_id", id).put("status", receipt.optString("status", "unknown")).put("result", receipt.optJSONObject("result") ?: JSONObject())
        }
        val now = java.time.Instant.now(); val expiry = java.time.Instant.parse(request.getString("expires_at"))
        require(expiry.isAfter(now) && !expiry.isAfter(now.plusSeconds(30))) { "Command expired" }
        val kind = request.getString("kind"); val payload = request.optJSONObject("payload") ?: JSONObject()
        require(kind in listOf("clipboard_text", "share_text", "share_url", "notification_reply", "dismiss_notification", "set_profile", "set_export", "notification_preferences", "ping"))
        when (kind) {
            "set_profile" -> require(payload.getString("profile") in listOf("balanced", "responsive", "battery"))
            "set_export" -> { require(ProtocolRules.packageName(payload.getString("package_name"))); require(payload.get("selected") is Boolean) }
            "notification_preferences" -> { require(payload.get("enabled") is Boolean); val packages = payload.getJSONArray("packages"); require(packages.length() <= 256); for (i in 0 until packages.length()) require(ProtocolRules.packageName(packages.getString(i))); if (payload.getBoolean("enabled")) require(setting("notifications_enabled")) { "Enable notification sharing on phone" } }
        }
        val stale = commandReceipts.filterValues { runCatching { java.time.Instant.parse(JSONObject(it).getString("created_at")).isBefore(now.minusSeconds(86400)) }.getOrDefault(false) }.keys
        stale.forEach { commandReceipts.remove(it) }
        if (commandReceipts.size >= 512) throw BridgeFailure(429, "receipt_capacity")
        val receipt = JSONObject().put("hash", hash).put("status", "unknown").put("created_at", now.toString())
        commandReceipts[id] = receipt.toString()
        persistReceipts() // Durable intent precedes effects; uncertain retries never replay an effect.
        var effectResult = JSONObject()
        when (kind) {
            "clipboard_text", "share_text", "share_url" -> {
                require(setting("clipboard_enabled")) { "Enable explicit sharing on phone" }
                val text = payload.optString("text", payload.optString("url")); require(text.toByteArray().size <= 65_536)
                if (kind == "share_url") require(android.net.Uri.parse(text).scheme in listOf("http", "https") && text.length <= 8192)
                receiveText(trustId, text)
            }
            "notification_reply" -> { require(notificationsAllowed(trustId)); BridgeNotifications.reply(context, payload.getString("notification_key"), payload.getString("action_id"), payload.getString("text")) }
            "dismiss_notification" -> { require(notificationsAllowed(trustId)); BridgeNotifications.dismiss(payload.getString("notification_key"), payload.getString("action_id")) }
            "set_profile" -> profile(payload.getString("profile"))
            "notification_preferences" -> { val value = trusted(); value.getJSONObject(trustId).put("notifications", payload.getBoolean("enabled")).put("notification_packages", payload.getJSONArray("packages")); credentials.write(value.toString()) }
            "set_export" -> { effectResult = applyExportLocal(payload.getString("package_name"), payload.getBoolean("selected"), trustId, id) }
        }
        receipt.put("status", "applied").put("result", effectResult); commandReceipts[id] = receipt.toString(); persistReceipts()
        return JSONObject().put("accepted", true).put("request_id", id).put("status", "applied").put("result", effectResult)
    }
    fun status(): JSONObject {
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = battery?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = battery?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val power = context.getSystemService(PowerManager::class.java)
        return JSONObject().put("battery_percent", if (level >= 0 && scale > 0) level * 100 / scale else JSONObject.NULL)
            .put("charging", if (battery?.hasExtra(BatteryManager.EXTRA_PLUGGED) == true) battery.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0 else JSONObject.NULL)
            .put("thermal_status", power.currentThermalStatus).put("power_save", power.isPowerSaveMode)
            .put("profile", prefs.getString("profile", "balanced")).put("sdk", android.os.Build.VERSION.SDK_INT)
            .put("observed_at", java.time.Instant.now().toString()).put("network_class", networkClass())
            .put("phone_command_journal", if (phoneJournalHealthy) "available" else "unavailable")
            .put("received_text_journal", if (receivedHealthy) "available" else "unavailable")
    }
    private fun networkClass(): Any = runCatching {
        val manager = context.getSystemService(android.net.ConnectivityManager::class.java)
        val capabilities = manager.getNetworkCapabilities(manager.activeNetwork) ?: return@runCatching "none"
        when {
            capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
            capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(android.net.NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
    }.getOrDefault(JSONObject.NULL)
    fun profile(value: String) { require(value in listOf("balanced", "responsive", "battery")); prefs.edit().putString("profile", value).apply(); event("profile_changed", JSONObject().put("profile", value)) }
    companion object {
        @Volatile private var instance: BridgeStore? = null
        fun get(context: Context): BridgeStore = instance ?: synchronized(this) { instance ?: BridgeStore(context.applicationContext).also { instance = it } }
    }
}

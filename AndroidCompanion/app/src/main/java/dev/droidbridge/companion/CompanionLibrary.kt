package dev.droidbridge.companion

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.UUID

/** Deliberately saved content, separate from the expiring received-content inbox. */
class CompanionLibrary(context: Context) {
    private val journal = SecureJournal(context, "saved-library", 524288)
    private var value = JSONObject().put("snippets", JSONArray()).put("presets", JSONArray())
    private var healthy = true
    @Volatile private var revision = "empty"
    init {
        runCatching {
            journal.read()?.let { encoded ->
                val saved = JSONObject(encoded)
                require(saved.getJSONArray("snippets").length() <= 64 && saved.getJSONArray("presets").length() <= 8)
                value = saved
                revision = ProtocolRules.hash(encoded.toByteArray())
            }
        }.onFailure { healthy = false }
    }
    private fun checkHealthy() { if (!healthy) throw BridgeFailure(503, "saved_library_unavailable") }
    @Synchronized private fun mutate(change: (JSONObject) -> Unit) {
        checkHealthy()
        val next = JSONObject(value.toString())
        change(next)
        journal.write(next.toString())
        value = next
        revision = ProtocolRules.hash(next.toString().toByteArray())
    }
    fun revision(): String { checkHealthy(); return revision }
    @Synchronized fun snippets(): JSONArray {
        checkHealthy()
        val rows = value.getJSONArray("snippets")
        return JSONArray((0 until rows.length()).map { JSONObject(rows.getJSONObject(it).toString()) }
            .sortedWith(compareByDescending<JSONObject> { it.getBoolean("pinned") }.thenByDescending { it.getString("created_at") }))
    }
    fun saveSnippet(text: String, sourceTrustId: String?): JSONObject {
        require(text.isNotBlank() && text.toByteArray().size <= 65536) { "Use nonempty text up to 64 KiB" }
        val row = JSONObject().put("id", UUID.randomUUID().toString()).put("text", text).put("pinned", false)
            .put("created_at", Instant.now().toString()).put("source_trust_id", sourceTrustId ?: JSONObject.NULL)
        mutate { next ->
            val rows = next.getJSONArray("snippets")
            require(rows.length() < 64) { "Saved snippet capacity reached. Remove a snippet first." }
            rows.put(row)
        }
        return JSONObject(row.toString())
    }
    fun pinSnippet(id: String, pinned: Boolean) = mutate { next -> find(next.getJSONArray("snippets"), id).put("pinned", pinned) }
    fun deleteSnippet(id: String) = mutate { next -> remove(next, "snippets", id) }
    @Synchronized fun presets(): JSONArray { checkHealthy(); return JSONArray(value.getJSONArray("presets").toString()) }
    @Synchronized fun preset(id: String): JSONObject { checkHealthy(); return JSONObject(find(value.getJSONArray("presets"), id).toString()) }
    fun savePreset(name: String, packages: List<String>, trustId: String, audioRoute: String, profile: String, screenOff: Boolean): JSONObject {
        require(name.isNotBlank() && name.length <= 80 && ProtocolRules.identifier(trustId))
        require(packages.size in 1..8 && packages.distinct().size == packages.size && packages.all(ProtocolRules::packageName))
        require(audioRoute in listOf("mac", "phone", "mac_and_phone") && profile in listOf("battery", "balanced", "responsive"))
        val row = JSONObject().put("id", UUID.randomUUID().toString()).put("name", name.trim()).put("packages", JSONArray(packages))
            .put("trust_id", trustId).put("audio_route", audioRoute).put("profile", profile).put("screen_off", screenOff).put("created_at", Instant.now().toString())
        mutate { next ->
            val rows = next.getJSONArray("presets")
            require(rows.length() < 8) { "Preset capacity reached. Remove a preset first." }
            rows.put(row)
        }
        return JSONObject(row.toString())
    }
    fun deletePreset(id: String) = mutate { next -> remove(next, "presets", id) }
    private fun find(rows: JSONArray, id: String): JSONObject = (0 until rows.length()).map { rows.getJSONObject(it) }
        .firstOrNull { it.getString("id") == id } ?: throw BridgeFailure(404, "saved_item_unavailable")
    private fun remove(next: JSONObject, key: String, id: String) {
        val rows = next.getJSONArray(key); find(rows, id)
        next.put(key, JSONArray((0 until rows.length()).map { rows.getJSONObject(it) }.filter { it.getString("id") != id }))
    }
}

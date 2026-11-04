package dev.droidbridge.companion

import android.app.Activity
import android.app.AlertDialog
import android.app.KeyguardManager
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.google.android.material.button.MaterialButton
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors

/** Small unlocked review surface for tiles, widgets, shortcuts and selected text. */
class QuickAccessActivity : Activity() {
    private val work = Executors.newSingleThreadExecutor()
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var store: BridgeStore
    private lateinit var body: LinearLayout
    private lateinit var status: TextView
    private var target: String? = null
    private var requestId: String? = null
    private var sending = false
    private var reviewDialog: AlertDialog? = null
    private var resumed = false
    private var generation = 0
    private var fingerprint = ""
    private val poll = object : Runnable { override fun run() { snapshot(); if (resumed) handler.postDelayed(this, 1500) } }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState); store = BridgeStore.get(this)
        target = savedInstanceState?.getString("target") ?: intent.getStringExtra(QuickAccess.TRUST) ?: store.selectedTrust()
        requestId = savedInstanceState?.getString("request_id")
        val locked = getSystemService(KeyguardManager::class.java)
        if (locked.isDeviceLocked) locked.requestDismissKeyguard(this, null)
        val scroll = ScrollView(this); body = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(24), dp(20), dp(24)) }
        scroll.addView(body); setContentView(scroll)
        window.decorView.setOnApplyWindowInsetsListener { view, insets -> val bars = insets.getInsets(android.view.WindowInsets.Type.systemBars()); view.setPadding(bars.left, bars.top, bars.right, bars.bottom); insets }
        render(JSONObject(), JSONArray()); snapshot()
    }
    override fun onResume() { super.onResume(); resumed = true; handler.post(poll) }
    override fun onPause() { resumed = false; handler.removeCallbacks(poll); reviewDialog?.dismiss(); reviewDialog = null; super.onPause() }
    override fun onDestroy() { generation++; reviewDialog?.dismiss(); reviewDialog = null; work.shutdownNow(); super.onDestroy() }
    override fun onSaveInstanceState(out: Bundle) { out.putString("target", target); out.putString("request_id", requestId); super.onSaveInstanceState(out) }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun text(value: String, size: Float = 16f) = TextView(this).apply { text = value; textSize = size; setPadding(0, dp(8), 0, dp(8)) }
    private fun button(label: String, enabled: Boolean = true, action: () -> Unit) = MaterialButton(this).apply {
        text = label; isAllCaps = false; minHeight = dp(48); isEnabled = enabled; setOnClickListener { action() }
    }
    private fun unlocked(): Boolean {
        if (getSystemService(KeyguardManager::class.java).isDeviceLocked) { status.text = "Unlock your phone to use companion actions."; return false }; return true
    }
    private fun snapshot() {
        if (isFinishing || work.isShutdown) return
        val token = generation; val expected = target
        work.execute {
            val result = runCatching { Triple(store.peerStatus(expected), store.catalogLocal(), store.commandOutcomes()) }
            handler.post {
                if (isDestroyed || token != generation || expected != target) return@post
                result.onSuccess { (peer, apps, receipts) ->
                    if (requestId == null) {
                        val next = "${store.running}:${target}:${peer.optBoolean("connected")}:${peer.optJSONArray("sessions")}:${store.setting("clipboard_enabled")}:$apps:${getSharedPreferences("companion-ui", MODE_PRIVATE).getStringSet("favorites", emptySet())}"
                        if (fingerprint != next) { fingerprint = next; render(peer, apps) }
                    }
                    else {
                        val receipt = (0 until receipts.length()).map { receipts.getJSONObject(it) }.firstOrNull { it.optString("request_id") == requestId }
                        status.text = if (receipt == null) "Request $requestId · outcome unavailable. No automatic retry." else "Request ${requestId?.take(8)} · ${receiptLabel(receipt)}"
                    }
                }.onFailure { status.text = "Companion status unavailable. Open DroidBridge for diagnostics." }
            }
        }
    }
    private fun receiptLabel(receipt: JSONObject): String {
        val result = receipt.optJSONObject("result")
        val label = when (receipt.optString("status")) {
            "queued" -> "Requested · waiting for Mac"
            "accepted" -> "Accepted · waiting for operation"
            "admitted" -> "Running on Mac"
            "unknown" -> "Outcome unknown · check Mac before repeating"
            "expired" -> "Expired · check Mac before repeating"
            "applied" -> if (result?.has("output_confirmed") == true && !result.optBoolean("output_confirmed")) "Preference saved · output unconfirmed" else "Applied"
            else -> receipt.optString("status")
        }
        return label + (receipt.optString("error_code").takeIf { it.isNotBlank() }?.let { " · $it" } ?: "")
    }
    private fun render(peer: JSONObject, apps: JSONArray) {
        body.removeAllViews()
        body.addView(text("Quick actions", 26f))
        val trusted = store.trusted(); val name = target?.let { trusted.optJSONObject(it)?.optString("name") } ?: "Choose a trusted Mac"
        status = text("${QuickAccessState.label(store.running, peer.optBoolean("connected"))} · $name").apply { accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }; body.addView(status)
        body.addView(button("Mac: $name") {
            val ids = trusted.keys().asSequence().toList()
            if (ids.isEmpty()) startActivity(QuickAccess.mainIntent(this, "Settings"))
            else AlertDialog.Builder(this).setTitle("Choose action destination").setItems(ids.map { trusted.getJSONObject(it).optString("name") }.toTypedArray()) { _, index -> target = ids[index]; requestId = null; generation++; snapshot() }.show()
        })
        body.addView(button(if (store.running) "Disconnect companion…" else "Enable companion connection") {
            if (!unlocked()) return@button
            if (store.running) AlertDialog.Builder(this).setTitle("Disconnect companion?").setMessage("Companion commands and transfers stop. Independent app video and audio connections may continue.")
                .setPositiveButton("Disconnect") { _, _ -> stopService(Intent(this, BridgeService::class.java)); handler.postDelayed({ snapshot() }, 400) }.setNegativeButton("Cancel", null).show()
            else runCatching { startForegroundService(Intent(this, BridgeService::class.java)) }.onFailure { status.text = "Connection could not start. Open DroidBridge diagnostics." }
        })
        val valid = target != null && trusted.has(target) && store.running && peer.optBoolean("connected")
        val pinnedPackage = intent.getStringExtra(QuickAccess.PACKAGE)
        if (intent.action == QuickAccess.OPEN_APP) {
            val pkg = pinnedPackage.orEmpty()
            body.addView(text("This shortcut targets $name. Opening creates a separate Android app window on that Mac."))
            val app = (0 until apps.length()).map { apps.getJSONObject(it) }.firstOrNull { it.optString("package_name") == pkg }
            body.addView(button("Open ${app?.optString("label") ?: pkg} on $name", valid && ProtocolRules.packageName(pkg)) { confirm("Open app on $name?", "open_app", JSONObject().put("package_name", pkg)) })
        }
        val sharing = valid && store.setting("clipboard_enabled")
        if (!store.setting("clipboard_enabled")) body.addView(text("Enable explicit clipboard and text sharing in DroidBridge Settings to send text."))
        if (intent.action == Intent.ACTION_PROCESS_TEXT) {
            val value = intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString().orEmpty()
            body.addView(text(value.take(2048)))
            body.addView(button("Send selected text to $name", sharing && value.isNotEmpty() && value.toByteArray().size <= 65536) { confirm("Send selected text to $name?", "share_text", JSONObject().put("text", value)) })
        }
        val favorites = getSharedPreferences("companion-ui", MODE_PRIVATE).getStringSet("favorites", emptySet()) ?: emptySet()
        val rows = (0 until apps.length()).map { apps.getJSONObject(it) }.filter { it.optString("package_name") in favorites }.take(5)
        rows.forEach { app -> body.addView(button("${app.optString("label")} on Mac", valid) { confirm("Open ${app.optString("label")} on $name?", "open_app", JSONObject().put("package_name", app.getString("package_name"))) }) }
        body.addView(button("Send clipboard…", sharing) {
            if (!unlocked()) return@button
            // Clipboard is accessed only from this foreground, explicit user gesture.
            val value = getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.text?.toString()
            if (value.isNullOrEmpty() || value.toByteArray().size > 65536) status.text = "Copy plain text first (maximum 64 KiB)."
            else confirm("Send clipboard to $name?", "clipboard_text", JSONObject().put("text", value), value.take(2048))
        })
        for ((label, route) in listOf("Audio on Mac" to "mac", "Audio on phone" to "phone", "Audio on Mac + phone" to "mac_and_phone")) {
            body.addView(button(label, valid) { confirm("$label?", "set_audio_route", JSONObject().put("route", route)) })
        }
        body.addView(button("Turn physical phone display off…", valid) { confirm("Turn phone display off?", "set_screen_power", JSONObject().put("off", true)) })
        body.addView(button("Turn physical phone display on", valid) { confirm("Turn phone display on?", "set_screen_power", JSONObject().put("off", false)) })
        val sessions = peer.optJSONArray("sessions") ?: JSONArray()
        for (i in 0 until sessions.length()) {
            val session = sessions.getJSONObject(i)
            body.addView(button("Stop ${session.optString("package_name")} window…", valid) { confirm("Stop this app window?", "stop_session", JSONObject().put("session_id", session.getString("session_id"))) })
        }
        body.addView(button("Open full DroidBridge") { startActivity(QuickAccess.mainIntent(this, "Home")); finish() })
    }
    private fun confirm(title: String, kind: String, payload: JSONObject, preview: String? = null) {
        if (isDestroyed || isFinishing || !resumed || !unlocked() || sending) return
        val trust = target ?: return; val name = store.trusted().optJSONObject(trust)?.optString("name") ?: return
        reviewDialog?.dismiss()
        val dialog = AlertDialog.Builder(this).setTitle(title).setMessage("Destination: $name${preview?.let { "\n\n$it" } ?: ""}")
            .setNegativeButton("Cancel", null).setPositiveButton("Send") { _, _ ->
                if (isDestroyed || isFinishing || !resumed || work.isShutdown || !unlocked() || sending) return@setPositiveButton
                sending = true
                work.execute {
                    val result = runCatching { require(store.running && store.peerStatus(trust).optBoolean("connected")) { "Mac unavailable" }; store.phoneCommand(kind, payload, trust) }
                    handler.post { if (isDestroyed || isFinishing) return@post; sending = false; result.onSuccess { requestId = it; status.text = "Requested · ${it.take(8)}" }.onFailure { status.text = "Action was not sent: ${it.message}" }; snapshot() }
                }
            }.create()
        reviewDialog = dialog
        dialog.setOnDismissListener { if (reviewDialog === dialog) reviewDialog = null }
        dialog.show()
    }
}

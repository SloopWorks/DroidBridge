package dev.droidbridge.companion

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.text.Editable
import android.text.TextWatcher
import android.util.LruCache
import android.view.View
import android.view.ViewGroup
import android.widget.*
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.Future

/** Phone controls acknowledge local work immediately and reserve success for peer receipts. */
class MainActivity : Activity() {
    private val work = Executors.newSingleThreadExecutor()
    private val imageWork = Executors.newFixedThreadPool(2)
    private val fileWork = Executors.newSingleThreadExecutor()
    private val releaseWork = Executors.newSingleThreadExecutor()
    private var releaseRequest: ReleaseDelivery? = null
    private var releaseMetadata: ReleaseDelivery.Metadata? = null
    internal var activeDialog: AlertDialog? = null
        private set
    private var releaseLoading = false
    private var releaseMessage = "Refresh installer details to contact the official GitHub release. No phone identifiers or content are sent."
    private val pendingRequests = mutableMapOf<String, String>()
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var store: BridgeStore
    private lateinit var host: LinearLayout
    private lateinit var content: LinearLayout
    private lateinit var receiver: Button
    private lateinit var feedback: TextView
    private var scroll: ScrollView? = null
    private var tab = "Home"
    private var alive = true
    private var polling = false
    private var pairDialogId: String? = null
    private var presentation = ""
    private var peer = JSONObject()
    private var trusts = JSONObject()
    private var outcomes = JSONArray()
    private var transfers = JSONArray()
    private var catalog = listOf<JSONObject>()
    @Volatile private var catalogVersion = ""
    private var receivedTexts = JSONArray()
    private var health = JSONObject()
    private var selected: String? = null
    private var query = ""
    private var draft = ""
    private var savingTransfer: String? = null
    private var diagnosticExport: ByteArray? = null
    private var preparation: Future<*>? = null
    private var preparing = false
    private var adapter: AppsAdapter? = null
    private var outcomeList: LinearLayout? = null
    private var pendingShare: Intent? = null
    private val preferences by lazy { getSharedPreferences("companion-ui", MODE_PRIVATE) }
    private val cache = object : LruCache<String, Bitmap>(4 * 1024 * 1024) { override fun sizeOf(key: String, value: Bitmap) = value.byteCount }
    private val loadingIcons = mutableSetOf<String>()
    private val refresh = object : Runnable { override fun run() { snapshot(); handler.postDelayed(this, 1000) } }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Color.rgb(247, 249, 252)
        window.decorView.systemUiVisibility = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR
        store = BridgeStore.get(this); tab = savedInstanceState?.getString("tab") ?: "Home"; query = savedInstanceState?.getString("query") ?: ""
        shell(); showTab()
        if (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE) pendingShare = intent
        work.execute { runCatching { store.refreshCatalog() }; handler.post { snapshot() } }
    }
    override fun onResume() { super.onResume(); handler.post(refresh); presentation = "" }
    override fun onPause() { handler.removeCallbacks(refresh); super.onPause() }
    override fun onDestroy() { alive = false; activeDialog?.dismiss(); activeDialog = null; releaseRequest?.cancel(); releaseWork.shutdownNow(); preparation?.cancel(true); work.shutdownNow(); imageWork.shutdownNow(); fileWork.shutdownNow(); super.onDestroy() }
    override fun onSaveInstanceState(outState: Bundle) { outState.putString("tab", tab); outState.putString("query", query); super.onSaveInstanceState(outState) }
    private fun dp(v: Int) = (v * resources.displayMetrics.density).toInt()
    private fun text(value: String, size: Float = 16f, bold: Boolean = false) = TextView(this).apply {
        text = value; textSize = size; setTextColor(Color.rgb(22, 35, 54)); setPadding(0, dp(4), 0, dp(8)); if (bold) setTypeface(typeface, android.graphics.Typeface.BOLD)
    }
    private fun button(value: String, action: () -> Unit) = Button(this).apply { text = value; isAllCaps = false; minHeight = dp(48); setPadding(dp(12), dp(8), dp(12), dp(8)); setOnClickListener { action() } }
    /** Keep platform dialog actions readable at the user's actual font scale. */
    private fun AlertDialog.Builder.showAccessible(): AlertDialog = create().also { it.showAccessible() }
    private fun AlertDialog.showAccessible() {
        activeDialog = this
        setOnShowListener {
            val actions = listOf(AlertDialog.BUTTON_POSITIVE, AlertDialog.BUTTON_NEGATIVE, AlertDialog.BUTTON_NEUTRAL)
                .mapNotNull { getButton(it) }.filter { it.visibility == View.VISIBLE }
            actions.forEach { button ->
                button.isSingleLine = false
                button.maxLines = Int.MAX_VALUE
                button.ellipsize = null
                button.minimumHeight = maxOf(dp(48), button.lineHeight + button.compoundPaddingTop + button.compoundPaddingBottom)
            }
            val panel = actions.firstOrNull()?.parent as? LinearLayout
            if (panel != null && actions.all { it.parent === panel }) {
                // Android's legacy button bar reserves only the first stacked action
                // plus a small peek, clipping the second action at large font sizes.
                // One intrinsic-height group preserves native buttons/listeners and
                // makes the stock dialog reserve every action before the message.
                val group = LinearLayout(this@MainActivity).apply {
                    orientation = LinearLayout.VERTICAL
                    minimumHeight = actions.sumOf { it.minimumHeight }
                }
                panel.removeAllViews()
                actions.forEach { group.addView(it, LinearLayout.LayoutParams(-1, -2)) }
                panel.addView(group, LinearLayout.LayoutParams(-1, -2))
                panel.minimumHeight = group.minimumHeight + panel.paddingTop + panel.paddingBottom
                panel.requestLayout()
            }
        }
        show()
    }
    private fun title(value: String) = text(value, 22f, true).apply { isAccessibilityHeading = true }
    private fun card(name: String, description: String = "", build: LinearLayout.() -> Unit = {}) {
        content.addView(LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(14), dp(12), dp(14), dp(12)); setBackgroundColor(Color.WHITE); addView(title(name)); if (description.isNotEmpty()) addView(text(description)); build() }, LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(12) })
    }
    private fun shell() {
        val outer = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.rgb(247, 249, 252)) }
        receiver = button("Choose a trusted Mac") { chooseReceiver() }.apply { maxLines = 2; ellipsize = android.text.TextUtils.TruncateAt.END }; outer.addView(receiver, LinearLayout.LayoutParams(-1, -2))
        feedback = text("Start the connection service, then pair your Mac.", 14f).apply { maxLines = 3; ellipsize = android.text.TextUtils.TruncateAt.END; setOnClickListener { AlertDialog.Builder(this@MainActivity).setTitle("Action status").setMessage(text).setPositiveButton("Close", null).showAccessible() }; contentDescription = "Action status; tap to read full message"; setPadding(dp(12), dp(4), dp(12), dp(8)); accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }; outer.addView(feedback)
        host = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }; outer.addView(host, LinearLayout.LayoutParams(-1, 0, 1f))
        val nav = LinearLayout(this)
        fun updateNav() { for (i in 0 until nav.childCount) nav.getChildAt(i).apply { isSelected = tag == tab; (this as? Button)?.setTypeface(null, if (isSelected) android.graphics.Typeface.BOLD else android.graphics.Typeface.NORMAL); contentDescription = "$tag${if (isSelected) ", selected" else ""}" } }
        listOf("Home", "Apps", "Sharing", "Settings").forEach { name -> nav.addView(button(name) { tab = name; showTab(); updateNav() }.apply { tag = name }, LinearLayout.LayoutParams(-2, -2)) }
        // Complete labels remain reachable horizontally instead of clipping into four fixed columns.
        outer.addView(HorizontalScrollView(this).apply { isFillViewport = true; addView(nav) }, LinearLayout.LayoutParams(-1, -2))
        outer.setOnApplyWindowInsetsListener { view, insets -> val bars = insets.getInsets(android.view.WindowInsets.Type.systemBars() or android.view.WindowInsets.Type.ime()); view.setPadding(dp(12) + bars.left, bars.top, dp(12) + bars.right, bars.bottom); insets }
        setContentView(outer); outer.requestApplyInsets(); updateNav()
    }
    private fun showTab() {
        host.removeAllViews(); adapter = null; scroll = null; outcomeList = null
        if (tab == "Apps") { content = host; apps(); return }
        content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        scroll = ScrollView(this).apply { isFillViewport = true; addView(content) }; host.addView(scroll, LinearLayout.LayoutParams(-1, -1))
        when (tab) { "Home" -> home(); "Sharing" -> sharing(); else -> settings() }
    }
    private fun updateVisible() {
        // Polls never replace editors, list/search focus or a scrolled accessibility tree.
        if (tab == "Apps") { adapter?.notifyDataSetChanged(); return }
        if (currentFocus is EditText) { updateOutcomes(); return }
        val position = scroll?.scrollY ?: 0
        showTab(); scroll?.post { scroll?.scrollTo(0, position) }
    }
    private fun announce(value: String) { if (feedback.text.toString() != value) { feedback.text = value; feedback.contentDescription = "$value. Tap to read the full action status." } }
    private fun name() = selected?.let { trusts.optJSONObject(it)?.optString("name") }?.takeIf { it.isNotBlank() } ?: "a trusted Mac"
    private fun chooseReceiver() {
        val ids = trusts.keys().asSequence().toList()
        if (ids.isEmpty()) { announce("No trusted Mac yet. Start the service and choose Pair a new Mac on Home."); return }
        val labels = ids.map { id -> val n = trusts.getJSONObject(id).optString("name", "Mac"); n + if (ids.count { trusts.getJSONObject(it).optString("name") == n } > 1) " · ${id.take(6)}" else "" }.toTypedArray()
        AlertDialog.Builder(this).setTitle("Use this Mac for new actions").setSingleChoiceItems(labels, ids.indexOf(selected)) { dialog, i ->
            work.execute { store.selectTrust(ids[i]); handler.post { announce("Using ${labels[i]} for new actions"); snapshot() } }; dialog.dismiss()
        }.setNegativeButton("Cancel", null).showAccessible()
    }
    private fun snapshot() {
        if (!alive || polling) return; polling = true
        work.execute {
            val result = runCatching {
                val revision = store.catalogRevisionLocal()
                val changedCatalog = if (revision != catalogVersion) store.catalogLocal() else null
                listOf(store.trusted(), store.peerStatus(), store.commandOutcomes(), store.transfers.listLocal(), changedCatalog, store.pendingPair(), store.receivedTexts(), store.status(), revision)
            }
            handler.post {
                polling = false; if (!alive) return@post
                result.onSuccess { v ->
                    val previousOutcomes = (0 until outcomes.length()).associate { outcomes.getJSONObject(it).optString("request_id") to outcomes.getJSONObject(it).optString("status") }
                    trusts = v[0] as JSONObject; peer = v[1] as JSONObject; outcomes = v[2] as JSONArray; transfers = v[3] as JSONArray
                    val terminalIds = (0 until outcomes.length()).map { outcomes.getJSONObject(it) }.filter { it.optString("status") in listOf("applied", "rejected", "expired") }.map { it.optString("request_id") }.toSet()
                    pendingRequests.entries.removeAll { it.value in terminalIds }
                    (v[4] as? JSONArray)?.let { apps -> catalog = (0 until apps.length()).map { apps.getJSONObject(it) } }
                    catalogVersion = v[8] as String; receivedTexts = v[6] as JSONArray; health = v[7] as JSONObject
                    selected = peer.optString("trust_id").takeIf { it.isNotBlank() && it != "null" }
                    receiver.text = if (selected == null) "Choose a trusted Mac" else "Using: ${name()} · ${if (peer.optBoolean("connected")) "Connected" else "Not connected"}"
                    val stablePeer = JSONObject(peer.toString()).apply { remove("last_seen_at"); remove("last_seen_elapsed") }
                    val publicTrust = trusts.keys().asSequence().map { it + trusts.getJSONObject(it).optString("name") + trusts.getJSONObject(it).optBoolean("notifications") }.toList()
                    val receivedIDs = (0 until receivedTexts.length()).map { receivedTexts.getJSONObject(it).optString("event_id") }
                    val stableHealth = JSONObject(health.toString()).apply { remove("observed_at") }
                    val next = "${store.running}:${store.lastError}:$stablePeer:$outcomes:$transfers:$catalogVersion:$publicTrust:$receivedIDs:$stableHealth"
                    if (next != presentation) { presentation = next; updateVisible() }
                    (0 until outcomes.length()).map { outcomes.getJSONObject(it) }.lastOrNull { it.optString("trust_id") == selected && previousOutcomes[it.optString("request_id")] != it.optString("status") }?.let { changed ->
                        when (changed.optString("status")) {
                            "applied" -> if (changed.optJSONObject("result")?.optBoolean("materialization_pending") == true)
                                announce("Spotlight choice saved on ${name()}; its Mac app is pending. Use Retry Spotlight in Recent actions.")
                            else announce("Completed on ${name()}: ${changed.optString("kind").replace('_', ' ')}")
                            "rejected" -> announce("Rejected by ${name()}: ${changed.optString("error_code", "check Diagnostics")}")
                            "unknown" -> announce("Outcome not confirmed on ${name()}. Do not repeat this action until its receipt is resolved.")
                            "expired" -> announce("Action expired without confirmed completion. Check Recent actions before trying again.")
                        }
                    }
                    (v[5] as? JSONObject)?.let { approveDialog(it) }
                    pendingShare?.let { pendingShare = null; reviewShare(it) }
                }.onFailure { announce("Connection status could not refresh. Existing Mac app windows are independent. Retry from Home.") }
            }
        }
    }
    private fun approveDialog(pair: JSONObject) {
        if (pairDialogId == pair.getString("pairing_id")) return; pairDialogId = pair.getString("pairing_id")
        AlertDialog.Builder(this).setTitle("Trust ${pair.getString("mac_name")}?")
            .setMessage("This Mac can read your app catalog and control its DroidBridge sessions. Sharing permissions remain separate.\n\nComparison code: ${pair.optString("comparison_code", "Unavailable — do not approve")}. Check the same code on the Mac.")
            .setPositiveButton("Trust Mac") { _, _ -> work.execute { val r = runCatching { store.approvePair(pair.getString("pairing_id")) }; handler.post { announce(if (r.isSuccess) "Mac approved. Waiting for pairing to finish." else "Pairing expired or failed. Start a new attempt."); snapshot() } } }
            .setNegativeButton("Deny") { _, _ -> store.denyPair(); announce("Pairing denied") }.setOnCancelListener { store.denyPair() }.showAccessible()
    }
    private fun send(kind: String, payload: JSONObject, description: String) {
        if (kind in listOf("clipboard_text", "share_text", "share_url") && !store.setting("clipboard_enabled")) { announce("Explicit text sharing is off. Enable it in Settings → Sharing permissions before sending."); return }
        val target = selected
        if (target == null || !store.running) { announce("Start the service, pair, and choose the receiving Mac first."); return }
        val key = "$target:$kind:$payload"
        pendingRequests[key]?.let { id ->
            val outcome = (0 until outcomes.length()).map { outcomes.getJSONObject(it) }.firstOrNull { it.optString("request_id") == id }
            if (id == "admitting" || outcome == null || outcome.optString("status") in listOf("queued", "accepted", "admitted", "unknown")) { announce("This action is already pending. Check Recent actions; no duplicate was sent."); return }
            pendingRequests.remove(key)
        }
        if (pendingRequests.size >= 32) { announce("Too many unresolved actions. Wait for their receipts or expiry before trying again."); return }
        pendingRequests[key] = "admitting"
        val receiverName = name(); announce("Waiting for $receiverName · $description")
        work.execute { val r = runCatching { require(store.selectedTrust() == target) { "Receiver changed; review again" }; store.phoneCommand(kind, payload) }
            handler.post { r.onSuccess { id -> pendingRequests[key] = id; announce("Queued for $receiverName · $description. Completion not confirmed yet."); snapshot() }.onFailure { pendingRequests.remove(key); announce("Action was not queued: ${it.message?.take(180) ?: "check the selected Mac"}") } } }
    }
    private fun action(label: String, kind: String, payload: JSONObject, description: String = label) = button(label) { send(kind, payload, description) }.apply { isEnabled = selected != null && store.running }
    private fun home() {
        val status = when { !store.running -> "Connection service off"; selected == null -> "Service on · Pair a Mac"; peer.optBoolean("connected") -> "Connected to ${name()}"; else -> "Waiting for ${name()}" }
        card(status, store.lastError ?: "Keep DroidBridge available to your trusted Mac. Android debugging authorization and companion pairing are separate.") {
            addView(button(if (store.running) "Stop connection service" else "Start connection service") {
                if (store.running) AlertDialog.Builder(this@MainActivity).setTitle("Stop companion connection?").setMessage("Companion commands and transfers stop. Existing app video has its own connection.").setPositiveButton("Stop service") { _, _ -> stopService(Intent(this@MainActivity, BridgeService::class.java)); announce("Stopping service…"); handler.postDelayed({ snapshot() }, 500) }.setNegativeButton("Cancel", null).showAccessible()
                else if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) AlertDialog.Builder(this@MainActivity).setTitle("Connection notification").setMessage("Android shows a notification while the connection service runs. This permission does not share your notifications.").setPositiveButton("Continue") { _, _ -> requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 100); startConnection() }.setNegativeButton("Cancel", null).showAccessible()
                else startConnection()
            })
            addView(button("Connection setup") { setup() }); addView(button("Pair a new Mac") { pair() }); addView(button("Refresh status") { snapshot(); announce("Refreshing connection status…") })
        }
        val sessions = peer.optJSONArray("sessions") ?: JSONArray()
        card("Mac sessions", if (!peer.optBoolean("connected")) "Last known state · ${peer.optString("last_seen_at", "No report received")}" else if (sessions.length() == 0) "No apps running on ${name()}" else "${sessions.length()} app windows on ${name()}") {
            for (i in 0 until sessions.length()) { val s = sessions.getJSONObject(i); val label = s.optString("label", s.optString("package_name")); addView(text("$label · ${s.optString("phase", "Unknown")}", bold = true)); addView(action("Stop $label", "stop_session", JSONObject().put("session_id", s.getString("session_id")))) }
            if (sessions.length() > 0) addView(button("Stop all on ${name()}") { AlertDialog.Builder(this@MainActivity).setTitle("Stop ${sessions.length()} windows?").setMessage("Only these DroidBridge sessions on ${name()} are targeted. Check Recent actions for partial failures.").setPositiveButton("Stop all") { _, _ -> for (i in 0 until sessions.length()) send("stop_session", JSONObject().put("session_id", sessions.getJSONObject(i).getString("session_id")), "Stop app window") }.setNegativeButton("Cancel", null).showAccessible() })
        }
        card("Audio destination", "Device-wide, including other Android apps. Capture restrictions may keep Mac output silent. Actual output: ${peer.optString("audio_status", "Not reported")}") {
            val group = RadioGroup(this@MainActivity)
            listOf("Mac" to "mac", "Phone" to "phone", "Mac + Phone" to "mac_and_phone").forEach { (label, value) -> group.addView(RadioButton(this@MainActivity).apply { text = label; minHeight = dp(48); isChecked = peer.optString("audio_route") == value; isEnabled = selected != null && store.running; setOnClickListener { send("set_audio_route", JSONObject().put("route", value), "Select $label audio") } }) }; addView(group)
            addView(action("Retry Mac audio", "retry_audio", JSONObject()).apply { isEnabled = selected != null && store.running && peer.optString("audio_route") in listOf("mac", "mac_and_phone") })
        }
        card("Phone display", "Display power does not lock or unlock the phone. Mac app windows can continue on supported devices.") { addView(action("Turn phone display off", "set_screen_power", JSONObject().put("off", true))); addView(action("Turn phone display on", "set_screen_power", JSONObject().put("off", false))) }
        operations()
    }
    private fun startConnection() { runCatching { startForegroundService(Intent(this, BridgeService::class.java)); announce("Starting connection service…"); handler.postDelayed({ snapshot() }, 500) }.onFailure { announce("Connection service could not start. Check Diagnostics.") } }
    private fun setup() { AlertDialog.Builder(this).setTitle("Connect phone and Mac").setMessage("1. Connect a USB data cable and enable USB debugging in Developer options. Approve Android’s debugging prompt only for your trusted Mac.\n\n2. Or enable Wireless debugging and use Connect over Wi-Fi on the Mac. Android’s pairing and connection addresses have different ports.\n\n3. Start this app’s service and pair DroidBridge separately. Pairing here does not authorize Android debugging.").setPositiveButton("Open Developer options") { _, _ -> runCatching { startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS)) }.onFailure { announce("Enable Developer options in Android Settings → About phone, then return here.") } }.setNegativeButton("Close", null).showAccessible() }
    private fun pair() {
        if (!store.running) { announce("Start the connection service first"); return }
        store.startPairing(); val deadline = android.os.SystemClock.elapsedRealtime() + 120000
        val uri = store.pairingUri()
        val box = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(12), dp(16), dp(12)) }
        box.addView(text("On your Mac, open Phone → Companion → Pair Phone. Scan this QR, import its image, or paste the pairing link. Approve the same Mac name and comparison code here."))
        val matrix = com.google.zxing.qrcode.QRCodeWriter().encode(uri, com.google.zxing.BarcodeFormat.QR_CODE, 600, 600); val bitmap = Bitmap.createBitmap(600, 600, Bitmap.Config.ARGB_8888)
        for (y in 0 until 600) for (x in 0 until 600) bitmap.setPixel(x, y, if (matrix[x, y]) Color.BLACK else Color.WHITE)
        box.addView(ImageView(this).apply { setImageBitmap(bitmap); contentDescription = "Temporary pairing QR code"; adjustViewBounds = true }, LinearLayout.LayoutParams(-1, dp(240)))
        val countdown = text("Expires in 120 seconds"); box.addView(countdown)
        box.addView(button("Copy pairing link") { getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("DroidBridge pairing", uri).apply { description.extras = android.os.PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) } }); announce("Temporary pairing link copied") })
        val dialog = AlertDialog.Builder(this).setTitle("Pair a trusted Mac").setView(ScrollView(this).apply { addView(box) }).setNegativeButton("Cancel pairing") { _, _ -> store.denyPair() }.create()
        val timer = object : Runnable { override fun run() { val seconds = ((deadline - android.os.SystemClock.elapsedRealtime()) / 1000).coerceAtLeast(0); countdown.text = if (seconds > 0) "Expires in $seconds seconds" else "Pairing expired. Start again."; if (seconds > 0 && dialog.isShowing) handler.postDelayed(this, 1000) } }
        dialog.setOnCancelListener { store.denyPair() }; dialog.setOnDismissListener { handler.removeCallbacks(timer) }; dialog.showAccessible(); handler.post(timer)
    }
    private fun apps() {
        content.addView(title("Apps on your Mac"))
        if (resources.configuration.fontScale < 1.4f) content.addView(text("Spotlight choices apply to the selected Mac. Publication status is shown on that Mac → Companion → Apps.", 14f))
        val search = EditText(this).apply { hint = "Search installed apps"; setSingleLine(); setText(query); contentDescription = "Search installed apps" }; content.addView(search)
        val list = ListView(this).apply { dividerHeight = dp(8) }; adapter = AppsAdapter(); list.adapter = adapter; content.addView(list, LinearLayout.LayoutParams(-1, 0, 1f))
        search.addTextChangedListener(watcher { query = it; adapter?.notifyDataSetChanged() })
    }
    private fun watcher(change: (String) -> Unit) = object : TextWatcher { override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}; override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) { change(s.toString()) }; override fun afterTextChanged(s: Editable?) {} }
    private inner class AppsAdapter : BaseAdapter() {
        private var rows = listOf<JSONObject>()
        override fun notifyDataSetChanged() { rows = filteredRows(); super.notifyDataSetChanged() }
        init { rows = filteredRows() }
        private fun filteredRows() = catalog.filter { query.isBlank() || it.optString("label").contains(query, true) || it.optString("package_name").contains(query, true) }.sortedByDescending { preferences.getStringSet("favorites", emptySet())?.contains(it.optString("package_name")) == true }
        override fun getCount() = rows.size
        override fun getItem(position: Int) = rows[position]
        override fun getItemId(position: Int) = position.toLong()
        override fun getView(position: Int, convertView: View?, parent: ViewGroup?): View {
            val app = getItem(position); val pkg = app.getString("package_name"); val label = app.getString("label"); val exportTrust = selected
            return LinearLayout(this@MainActivity).apply {
                orientation = LinearLayout.VERTICAL; setPadding(dp(10), dp(8), dp(10), dp(8)); setBackgroundColor(Color.WHITE)
                val row = LinearLayout(this@MainActivity).apply { gravity = android.view.Gravity.CENTER_VERTICAL }; val icon = ImageView(this@MainActivity).apply { setImageResource(android.R.drawable.sym_def_app_icon) }; row.addView(icon, LinearLayout.LayoutParams(dp(40), dp(40)).apply { marginEnd = dp(10) }); row.addView(text(label, 18f, true), LinearLayout.LayoutParams(0, -2, 1f)); addView(row); loadIcon(app.optString("icon_sha256"), icon)
                if (catalog.count { it.optString("label") == label } > 1) addView(text(pkg, 12f))
                addView(CheckBox(this@MainActivity).apply { text = "Include in Spotlight"; minHeight = dp(48); isEnabled = exportTrust != null; isChecked = app.optBoolean("export_to_mac"); setOnCheckedChangeListener { _, enabled -> work.execute { val r = runCatching { store.chooseExport(pkg, enabled, exportTrust ?: throw IllegalArgumentException("Choose a trusted Mac")) }; handler.post { announce(if (r.isSuccess) "Spotlight choice saved on phone and queued for this Mac. Availability is not confirmed yet." else "Choice could not be saved. Try again."); snapshot() } } } })
                addView(CheckBox(this@MainActivity).apply { text = "Favorite"; minHeight = dp(48); isChecked = preferences.getStringSet("favorites", emptySet())?.contains(pkg) == true; setOnCheckedChangeListener { _, checked -> val set = (preferences.getStringSet("favorites", emptySet()) ?: emptySet()).toMutableSet(); if (checked) set.add(pkg) else set.remove(pkg); preferences.edit().putStringSet("favorites", set).apply(); notifyDataSetChanged() } })
                addView(action("Open on ${name()}", "open_app", JSONObject().put("package_name", pkg), "Open $label"))
            }
        }
    }
    private fun loadIcon(hash: String, view: ImageView) {
        if (!hash.matches(Regex("[a-f0-9]{64}"))) return
        cache.get(hash)?.let { view.setImageBitmap(it); return }; if (loadingIcons.size >= 16 || !loadingIcons.add(hash)) return
        imageWork.execute { val image = runCatching { val bytes = store.icon(hash) ?: return@runCatching null; require(bytes.size <= 262144 && ProtocolRules.hash(bytes) == hash); val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }; BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options); require(options.outWidth in 1..512 && options.outHeight in 1..512); BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }.getOrNull()
            handler.post { loadingIcons.remove(hash); if (alive && image != null) { cache.put(hash, image); adapter?.notifyDataSetChanged() } } }
    }
    private fun sharing() {
        card("Send selected text", "To ${name()}. Paste reads clipboard only after your action. Received text needs an explicit Copy.") {
            val input = EditText(this@MainActivity).apply { hint = "Text or https:// link"; minLines = 2; maxLines = 6; setText(draft); contentDescription = "Text to send to Mac" }; input.addTextChangedListener(watcher { draft = it }); addView(input)
            addView(button("Paste clipboard") {
                val clip = getSystemService(ClipboardManager::class.java).primaryClip
                val item = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)
                val plain = item?.text
                when {
                    item?.uri != null || item?.intent != null -> {
                        input.error = "Text only. Share this file to DroidBridge instead; your draft is unchanged."
                        announce("Clipboard file or intent was not read. Share this file instead.")
                    }
                    plain == null || plain.isEmpty() -> { input.error = "No clipboard text; your draft is unchanged."; announce("No text to paste.") }
                    plain.length > 65536 -> { input.error = "Clipboard text exceeds 64 KiB; your draft is unchanged."; announce("Clipboard text is too large; 64 KiB maximum.") }
                    else -> {
                        val value = plain.toString()
                        if (value.toByteArray(Charsets.UTF_8).size > 65536) {
                            input.error = "Clipboard text exceeds 64 KiB; your draft is unchanged."; announce("Clipboard text is too large; 64 KiB maximum.")
                        } else { input.error = null; input.setText(value); announce("Text pasted. Review it before sending.") }
                    }
                }
            })
            addView(button("Send to ${name()}") { val value = input.text.toString(); val url = value.startsWith("https://") || value.startsWith("http://"); val limit = if (url) 8192 else 65536; if (value.toByteArray().size !in 1..limit) input.error = "Enter 1–${limit / 1024} KiB; your draft is unchanged." else send(if (url) "share_url" else "share_text", JSONObject().put("text", value), "Send selected text") }.apply { isEnabled = selected != null && store.running })
        }
        card("Files and photos", "From an Android app, choose Share → DroidBridge. Review the receiver first. Two files, 50 MiB each.") {
            if (preparing) { addView(text("Preparing in private phone storage…")); addView(ProgressBar(this@MainActivity)); addView(button("Cancel preparation") { preparation?.cancel(true); announce("Cancelling preparation…") }) }
            for (i in 0 until transfers.length()) { val file = transfers.getJSONObject(i); val id = file.getString("transfer_id"); val label = file.getString("display_name"); val stagingState = file.optString("status") == "staging"; val size = if (stagingState) -1 else file.optLong("size", -1); val bytes = file.optLong(if (stagingState) "staged_bytes" else "accepted_bytes", 0)
                val ownerName = trusts.optJSONObject(file.optString("owner"))?.optString("name") ?: "previously selected Mac"
                val stageName = when (file.optString("status")) { "staging" -> "Preparing on phone"; "ready" -> "Waiting for Mac download"; "receiving" -> "Receiving on phone"; "received" -> "Verified on phone"; "downloaded" -> "Verified on Mac"; "cancelled" -> "Cancelled"; "failed" -> "Failed"; else -> "Outcome not confirmed" }
                addView(text("$label · $ownerName", bold = true)); addView(text("$stageName · ${formatBytes(bytes)}${if (size >= 0) " / ${formatBytes(size)}" else " · size unknown"}", 14f))
                if (size > 0 && file.optString("status") in listOf("ready", "receiving", "staging")) addView(ProgressBar(this@MainActivity, null, android.R.attr.progressBarStyleHorizontal).apply { max = 1000; progress = (bytes * 1000 / size).toInt(); contentDescription = "$label transfer progress" })
                if (file.optString("direction") == "mac_to_phone" && file.optBoolean("committed")) addView(button("Save $label…") { savingTransfer = id; startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).setType(file.optString("mime_type", "application/octet-stream")).addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE, label), 202) })
                if (file.optBoolean("can_cancel")) addView(button(if (file.optBoolean("committed") && file.optString("direction") == "mac_to_phone") "Remove inbox copy" else "Cancel transfer") { work.execute { val r = runCatching { store.transfers.cancelLocal(id) }; handler.post { announce(if (r.isSuccess) "Owned transfer copy removed. Externally saved files are unchanged." else "Could not cancel transfer. Check its latest state."); snapshot() } } })
            }
        }
        for (i in 0 until receivedTexts.length()) {
            val item = receivedTexts.getJSONObject(i); val receivedValue = item.getString("text")
            val sender = trusts.optJSONObject(item.optString("trust_id"))?.optString("name") ?: "trusted Mac"
            card("Received from $sender", receivedValue.take(2048) + if (receivedValue.length > 2048) "\nPreview shortened; Copy includes all text." else "") {
                addView(text("${item.optString("created_at")} · Removed after 30 minutes", 12f))
                addView(button("Copy received text") { getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("From $sender", receivedValue)); announce("Received text copied on this phone") })
                addView(button("Remove received text") { work.execute { store.clearReceivedText(item.getString("event_id")); handler.post { announce("Received text removed from DroidBridge. Your clipboard is unchanged."); snapshot() } } })
            }
        }
        operations()
    }
    private fun operations() {
        card("Recent actions", "Queued is not completed. Results below belong to the selected receiving Mac.") {
            outcomeList = LinearLayout(this@MainActivity).apply { orientation = LinearLayout.VERTICAL }; addView(outcomeList)
        }
        updateOutcomes()
    }
    private fun updateOutcomes() {
        val list = outcomeList ?: return
        list.removeAllViews()
        val selectedOutcomes = (0 until outcomes.length()).map { outcomes.getJSONObject(it) }.filter { it.optString("trust_id") == selected }
        if (selectedOutcomes.isEmpty()) list.addView(text("No recent commands", 14f))
        selectedOutcomes.forEach { o ->
            val state = when (o.optString("status")) { "queued" -> "Waiting for Mac"; "accepted", "admitted" -> "Accepted · completing"; "applied" -> if (o.optJSONObject("result")?.optBoolean("materialization_pending") == true) "Selection saved · Mac app pending" else "Completed"; "rejected" -> "Rejected"; "expired" -> "Expired · try original action again"; else -> "Outcome not confirmed" }
            list.addView(text("${o.optString("kind").replace('_', ' ')} · $state${o.optString("error_code").takeIf { it.isNotBlank() }?.let { " · $it" } ?: ""}", 14f))
            if (o.optString("kind") == "set_export" && o.optString("status") == "applied" && o.optJSONObject("result")?.optBoolean("materialization_pending") == true && o.optJSONObject("result")?.optBoolean("retryable") == true) {
                val originalId = o.getString("request_id"); val trust = o.getString("trust_id"); val key = "retry_spotlight:$originalId"
                list.addView(button("Retry Spotlight on ${trusts.optJSONObject(trust)?.optString("name", "Mac") ?: "Mac"}") {
                    if (selected != trust || pendingRequests.containsKey(key)) { announce("Check the selected receiver and pending action first."); return@button }
                    pendingRequests[key] = "admitting"
                    work.execute {
                        val result = runCatching { store.retrySpotlight(originalId, trust) }
                        handler.post { if (!alive) return@post; result.onSuccess { id -> pendingRequests[key] = id; announce("Spotlight retry queued for ${trusts.optJSONObject(trust)?.optString("name", "Mac") ?: "Mac"}; completion is not confirmed."); snapshot() }
                            .onFailure { pendingRequests.remove(key); announce("Spotlight retry was not queued. Check the receiver and try again.") } }
                    }
                }.apply { isEnabled = store.running && !pendingRequests.containsKey(key) })
            }
        }
    }
    private fun notificationAccess() = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")?.split(':')?.any { it.startsWith("$packageName/") } == true
    private fun settings() {
        card("Trusted Macs", "Choose the receiver at the top. Forgetting stops future access; saved copies on a Mac are not erased.") {
            if (trusts.length() == 0) addView(text("No trusted Macs. Pair from Home."))
            trusts.keys().forEach { id -> val record = trusts.getJSONObject(id); val n = record.optString("name", "Mac"); addView(text("$n${if (selected == id) " · Selected" else ""}", bold = true))
                addView(CheckBox(this@MainActivity).apply { text = "Share public notifications with $n"; minHeight = dp(48); isChecked = record.optBoolean("notifications", false); setOnCheckedChangeListener { _, value -> work.execute { store.allowNotifications(id, value); handler.post { announce("Notification permission for $n saved. Android access and global sharing remain separate."); snapshot() } } } })
                addView(button("Forget $n") { AlertDialog.Builder(this@MainActivity).setTitle("Forget $n?").setMessage("Companion sharing and commands from this Mac stop immediately. Existing ADB or scrcpy app windows can continue. Revoke USB and wireless debugging separately in Android developer settings to stop that access. Pairing requires approval again. Saved external files remain.").setPositiveButton("Forget Mac") { _, _ -> work.execute { store.revoke(id); handler.post { announce("$n forgotten"); snapshot() } } }.setNegativeButton("Cancel", null).showAccessible() })
            }
        }
        card("Sharing permissions", "Pairing grants neither clipboard collection nor notification access.") {
            addView(CheckBox(this@MainActivity).apply { text = "Allow explicit clipboard and text sharing"; minHeight = dp(48); isChecked = store.setting("clipboard_enabled"); setOnCheckedChangeListener { _, checked -> store.setting("clipboard_enabled", checked, Unit) } })
            addView(text("Android notification access: ${if (notificationAccess()) "Granted" else "Not granted"}"))
            addView(CheckBox(this@MainActivity).apply { text = "Enable notification sharing"; minHeight = dp(48); isChecked = store.setting("notifications_enabled"); setOnCheckedChangeListener { _, value -> store.setting("notifications_enabled", value, Unit); announce(if (value) "Sharing enabled; grant Android access and select each Mac above." else "New notification sharing stopped") } })
            addView(button("Review Android notification access") { AlertDialog.Builder(this@MainActivity).setTitle("Notification access").setMessage("Android grants broad notification access. DroidBridge shares supported public notifications only with Macs you allow. Sensitive, hidden and ongoing notifications are excluded by default.").setPositiveButton("Open Android settings") { _, _ -> startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }.setNegativeButton("Cancel", null).showAccessible() })
            addView(text("Connection notification permission: ${if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) "Granted" else "Not granted"}. This does not permit reading notifications.", 14f))
        }
        val battery = if (health.isNull("battery_percent") || !health.has("battery_percent")) "Unknown" else "${health.optInt("battery_percent")}%"
        val charging = if (health.isNull("charging") || !health.has("charging")) "Charging unknown" else if (health.optBoolean("charging")) "Charging" else "Not charging"
        val thermal = if (health.isNull("thermal_status") || !health.has("thermal_status")) "Unknown" else when (health.optInt("thermal_status")) { 0 -> "Normal"; 1 -> "Light"; 2 -> "Moderate"; 3 -> "Severe"; 4 -> "Critical"; 5 -> "Emergency"; 6 -> "Shutdown"; else -> "Unknown" }
        card("Phone health", "Battery: $battery · $charging\nThermal: $thermal\nNetwork: ${if (health.isNull("network_class")) "Unknown" else health.optString("network_class", "Unknown")}\nObserved: ${health.optString("observed_at", "Not reported")}")
        card("Connection profile", "Video changes apply to newly opened Mac windows. Existing windows keep their settings. No Android global battery/network settings change.") {
            val group = RadioGroup(this@MainActivity); listOf("Balanced — recommended" to "balanced", "Responsive — higher quality and resource use" to "responsive", "Battery — reduced video and background work" to "battery").forEach { (label, value) -> group.addView(RadioButton(this@MainActivity).apply { text = label; minHeight = dp(48); isChecked = peer.optString("profile", "balanced") == value; setOnClickListener { send("set_profile", JSONObject().put("profile", value), "Use $value profile for new windows") } }) }; addView(group)
        }
        card("Get DroidBridge for Mac", "On your Mac, download the official release, open its DMG, copy DroidBridge to Applications, then pair this phone. Android cannot install or approve Mac software. Check architecture, checksum and signing notes.") {
            addView(text(releaseMetadata?.summary() ?: releaseMessage, 14f))
            addView(button(if (releaseLoading) "Checking official installer…" else "Refresh Mac installer details") { refreshRelease() }.apply { isEnabled = !releaseLoading })
            addView(button("Open versioned Mac download") { releaseMetadata?.let { metadata ->
                runCatching { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(metadata.downloadUrl))) }.onFailure { announce("No browser can open the official download. Copy its link and open it on your Mac.") }
            } }.apply { isEnabled = releaseMetadata != null })
            addView(button("Copy Mac download link") { releaseMetadata?.let { metadata ->
                getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("DroidBridge ${metadata.version} for Mac", metadata.downloadUrl)); announce("Versioned installer link copied. Open it on your Apple Silicon Mac.")
            } }.apply { isEnabled = releaseMetadata != null })
            addView(text("Companion ${packageManager.getPackageInfo(packageName, 0).versionName} · Protocol 1. Update the named app on version mismatch; video remains independent.", 14f))
            addView(button("Third-party licenses") { startActivity(Intent(this@MainActivity, ThirdPartyActivity::class.java)) })
        }
        card("Diagnostics", "Scoped versions, permissions, battery, thermal and connection facts. No files, clipboard, notifications, hardware IDs or credentials.") {
            addView(button("Show diagnostics") { work.execute { val report = store.status().toString(2); handler.post { AlertDialog.Builder(this@MainActivity).setTitle("Device diagnostics").setMessage(report).setPositiveButton("Close", null).showAccessible() } } })
            addView(button("Export redacted diagnostics…") { work.execute { val bytes = store.status().toString(2).toByteArray(); handler.post { if (bytes.size > 65536) announce("Diagnostic report exceeded its safe size limit") else { diagnosticExport = bytes; startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).setType("application/json").addCategory(Intent.CATEGORY_OPENABLE).putExtra(Intent.EXTRA_TITLE, "DroidBridge-diagnostics.json"), 203) } } } })
        }
    }
    private fun refreshRelease() {
        if (releaseLoading) return
        releaseLoading = true; releaseMessage = "Checking official versioned installer metadata…"
        val request = ReleaseDelivery(); releaseRequest = request
        updateVisible(); announce("Checking official GitHub installer details. Phone content stays private.")
        releaseWork.execute {
            val result = runCatching { request.fetch() }; runCatching { request.close() }
            handler.post {
                if (!alive || releaseRequest !== request) return@post
                releaseRequest = null; releaseLoading = false
                result.onSuccess { releaseMetadata = it; releaseMessage = it.summary(); announce("Versioned installer details loaded. Nothing was downloaded or installed.") }
                    .onFailure { releaseMetadata = null; releaseMessage = "Official installer details are unavailable. Check the phone's internet connection or try again after this version is released. No installer was downloaded."; announce("Installer unavailable; no download was started.") }
                if (tab == "Settings") updateVisible()
            }
        }
    }
    private fun formatBytes(n: Long) = when { n < 1024 -> "$n B"; n < 1048576 -> "${n / 1024} KiB"; else -> String.format(java.util.Locale.ROOT, "%.1f MiB", n / 1048576.0) }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode != RESULT_OK || data?.data == null) { if (requestCode == 202) savingTransfer = null; if (requestCode == 203) diagnosticExport = null; return }
        val uri = data.data!!
        if (requestCode == 202) { val id = savingTransfer ?: return; savingTransfer = null; work.execute { val r = runCatching { store.transfers.exportReceived(id, uri) }; handler.post { announce(if (r.isSuccess) "File saved to selected destination" else "Unable to save; inbox copy retained") } } }
        if (requestCode == 203) { val bytes = diagnosticExport ?: return; diagnosticExport = null; work.execute { val r = runCatching { contentResolver.openOutputStream(uri)!!.use { it.write(bytes) } }; handler.post { announce(if (r.isSuccess) "Redacted diagnostics exported" else "Could not save diagnostics") } } }
    }
    private fun reviewShare(intent: Intent) {
        val recipient = selected ?: run { announce("Choose a trusted Mac, then share again from the sending app."); return }
        val receiverName = name()
        val value = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val uris = if (intent.action == Intent.ACTION_SEND_MULTIPLE) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) ?: arrayListOf() else arrayListOf<Uri>().apply { intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)?.let { add(it) } }
        if (uris.any { it.scheme != "content" } || uris.size > 2) { announce("Share up to two Android content files, 50 MiB each. Nothing was sent."); return }
        if (uris.isNotEmpty()) {
            // Never call an external provider before the user approves this named receiver.
            val summary = "${uris.size} selected ${if (uris.size == 1) "file" else "files"}\n" +
                uris.indices.joinToString("\n") { "File ${it + 1}" } +
                "\nFile names and sizes are checked after you approve."
            showFileReview(uris, recipient, receiverName, summary)
        } else if (value != null) {
            if (value.toByteArray().size !in 1..65536) { announce("Text exceeds the 64 KiB limit. Nothing was sent."); return }
            AlertDialog.Builder(this).setTitle("Send text to $receiverName?").setMessage(value.take(2048)).setNegativeButton("Cancel", null)
                .setPositiveButton("Send text") { _, _ -> if (selected == recipient) send("share_text", JSONObject().put("text", value), "Send selected text") else announce("Receiver changed. Review the share again.") }.showAccessible()
        } else announce("Share contained no supported text or files")
    }
    private fun showFileReview(uris: List<Uri>, recipient: String, receiverName: String, summary: String) {
        AlertDialog.Builder(this).setTitle("Send to $receiverName?")
            .setMessage("$summary\n\nTwo files, 50 MiB each. Files are staged privately, then downloaded and verified by this named Mac. Nothing opens automatically.")
            .setNegativeButton("Cancel", null).setPositiveButton("Send files") { _, _ ->
                preparing = true; tab = "Sharing"; showTab(); announce("Preparing files for $receiverName…")
                preparation = fileWork.submit {
                    val ids = mutableListOf<String>()
                    val result = runCatching { for (uri in uris) { require(!Thread.currentThread().isInterrupted); ids.add(store.transfers.stage(uri, recipient).getString("transfer_id")) } }
                    if (result.isFailure) ids.forEach { runCatching { store.transfers.cancelLocal(it) } }
                    handler.post {
                        if (!alive) return@post
                        preparing = false; preparation = null
                        announce(if (result.isSuccess) "Files staged for $receiverName. Delivery is not confirmed yet." else "Preparation stopped. Check transfer state before retrying.")
                        snapshot(); updateVisible()
                    }
                }
            }.showAccessible()
    }
}

package dev.droidbridge.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.IBinder
import android.service.quicksettings.TileService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class BridgeService : Service() {
    private val closing = java.util.concurrent.atomic.AtomicBoolean(false)
    @Volatile private var server: BridgeHttpServer? = null
    private val work = Executors.newSingleThreadScheduledExecutor()
    private var notificationFingerprint: String? = null
    private val changes = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) { if (!closing.get()) work.execute { runCatching { BridgeStore.get(context).refreshCatalog() } } }
    }
    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(NotificationChannel("connection", "Mac connection", NotificationManager.IMPORTANCE_LOW))
        // Foreground admission happens immediately; state remains Waiting until authenticated heartbeat.
        startForeground(1, notification("Starting", "Preparing local companion connection", 0, 0))
        registerReceiver(changes, IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED); addAction(Intent.ACTION_PACKAGE_REMOVED); addAction(Intent.ACTION_PACKAGE_CHANGED); addDataScheme("package")
        })
        work.execute {
            val store = BridgeStore.get(this)
            runCatching {
                store.refreshCatalog(); if (closing.get()) return@execute
                val created = BridgeHttpServer(store); server = created
                if (closing.get()) { created.close(); return@execute }
                created.start(); store.running = true
                if (closing.get()) { store.running = false; created.close(); return@execute }
                store.lastError = null; refreshPresentation()
            }.onFailure { store.lastError = "Connection service unavailable. Stop and try again."; stopSelf() }
        }
        work.scheduleWithFixedDelay({ if (!closing.get()) runCatching { refreshPresentation() } }, 2, 2, TimeUnit.SECONDS)
    }
    private fun notification(title: String, detail: String, progress: Int, total: Int): Notification {
        val connection = QuickAccess.intent(this).setAction(QuickAccess.CONNECTION)
        return Notification.Builder(this, "connection").setSmallIcon(R.drawable.ic_bridge_status)
            .setContentTitle("DroidBridge · $title").setContentText(detail).setStyle(Notification.BigTextStyle().bigText(detail))
            .setContentIntent(QuickAccess.pending(this, QuickAccess.mainIntent(this, "Home"), 300))
            .setVisibility(Notification.VISIBILITY_PRIVATE).setOnlyAlertOnce(true).setOngoing(true)
            .addAction(Notification.Action.Builder(null, "Quick actions", QuickAccess.pending(this, QuickAccess.intent(this), 301)).build())
            .addAction(Notification.Action.Builder(null, "Transfers", QuickAccess.pending(this, QuickAccess.mainIntent(this, "Sharing"), 302)).build())
            .addAction(Notification.Action.Builder(null, "Disconnect…", QuickAccess.pending(this, connection, 303)).build())
            .apply { if (total > 0) setProgress(total, progress, false) else if (total < 0) setProgress(0, 0, true) }.build()
    }
    private fun refreshPresentation() {
        if (closing.get()) return
        val store = BridgeStore.get(this); val peer = store.peerStatus()
        val connected = peer.optBoolean("connected")
        val title = QuickAccessState.label(store.running, connected)
        val detail = QuickAccessState.detail(store.running, connected, peer.optString("mac_name", "Mac"), peer.optJSONArray("sessions")?.length() ?: 0)
        val transfers = store.transfers.listLocal()
        val active = (0 until transfers.length()).map { transfers.getJSONObject(it) }.filter { it.optString("status") in listOf("staging", "receiving", "ready", "sending", "transferring") }
        val totalBytes = active.sumOf { it.optLong("size").coerceAtLeast(0) }
        val acceptedBytes = active.sumOf { it.optLong("accepted_bytes").coerceAtLeast(0) }
        val progress = if (totalBytes > 0) ((acceptedBytes.toDouble() / totalBytes).coerceIn(0.0, 1.0) * 1000).toInt() else 0
        val preparing = active.any { it.optString("status") == "staging" }
        val text = if (active.isEmpty()) detail else if (preparing) "$detail · Preparing ${active.size} file(s)" else "$detail · ${active.size} transfer(s), ${acceptedBytes / 1024} / ${totalBytes / 1024} KiB"
        val fingerprint = "$title:$text:$progress"
        if (fingerprint != notificationFingerprint) {
            getSystemService(NotificationManager::class.java).notify(1, notification(title, text, progress, if (preparing) -1 else if (totalBytes > 0) 1000 else 0))
            notificationFingerprint = fingerprint
            TileService.requestListeningState(this, ComponentName(this, ConnectionTileService::class.java))
            BridgeWidget.refresh(this)
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_NOT_STICKY
    override fun onDestroy() {
        closing.set(true); BridgeStore.get(this).running = false
        runCatching { unregisterReceiver(changes) }; runCatching { server?.close() }; work.shutdownNow()
        TileService.requestListeningState(this, ComponentName(this, ConnectionTileService::class.java))
        // Widget refresh does not restart the service or dispatch commands.
        Thread { BridgeWidget.refresh(applicationContext) }.start()
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}

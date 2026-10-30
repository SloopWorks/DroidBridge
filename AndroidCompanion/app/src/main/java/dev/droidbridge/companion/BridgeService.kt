package dev.droidbridge.companion

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.IBinder
import java.util.concurrent.Executors

class BridgeService : Service() {
    private val closing = java.util.concurrent.atomic.AtomicBoolean(false)
    private var server: BridgeHttpServer? = null
    private val work = Executors.newSingleThreadExecutor()
    private val changes = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) { work.execute { runCatching { BridgeStore.get(context).refreshCatalog() } } }
    }
    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("connection", "Mac connection", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        startForeground(1, Notification.Builder(this, "connection").setSmallIcon(R.drawable.ic_bridge)
            .setContentTitle("DroidBridge is available to your Mac").setContentText("Tap to manage trusted Macs and sharing. Stop in DroidBridge.")
            .setContentIntent(open).setOngoing(true).build())
        registerReceiver(changes, IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED); addAction(Intent.ACTION_PACKAGE_REMOVED); addAction(Intent.ACTION_PACKAGE_CHANGED); addDataScheme("package")
        })
        work.execute {
            val store = BridgeStore.get(this)
            runCatching { store.refreshCatalog(); if (closing.get()) return@execute; val created = BridgeHttpServer(store); server = created; if (closing.get()) { created.close(); return@execute }; created.start(); store.running = true; if (closing.get()) { store.running = false; created.close(); return@execute }; store.lastError = null }
                .onFailure { store.lastError = "Connection service unavailable. Stop and try again."; stopSelf() }
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int) = START_NOT_STICKY
    override fun onDestroy() {
        closing.set(true)
        BridgeStore.get(this).running = false
        runCatching { unregisterReceiver(changes) }; runCatching { server?.close() }; work.shutdownNow()
        super.onDestroy()
    }
    override fun onBind(intent: Intent?): IBinder? = null
}

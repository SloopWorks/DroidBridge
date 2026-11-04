package dev.droidbridge.companion

import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Android owns this tile lifecycle. A periodic foreground-only read keeps freshness honest. */
class ConnectionTileService : TileService() {
    private val handler = Handler(Looper.getMainLooper())
    private val update = object : Runnable { override fun run() { refresh(); handler.postDelayed(this, 2000) } }
    override fun onStartListening() { super.onStartListening(); handler.post(update) }
    override fun onStopListening() { handler.removeCallbacks(update); super.onStopListening() }
    private fun refresh() {
        val store = BridgeStore.get(this); val peer = store.peerStatus(); val connected = peer.optBoolean("connected")
        qsTile?.apply { state = if (store.running) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
            label = "DroidBridge connection"; subtitle = QuickAccessState.label(store.running, connected) + if (connected) " · ${peer.optString("mac_name")}" else ""
            contentDescription = "$label, $subtitle. Tap to toggle companion connection; independent app video continues"; updateTile() }
    }
    override fun onClick() {
        super.onClick()
        unlockAndRun {
            val store = BridgeStore.get(this)
            if (store.running) {
                stopService(Intent(this, BridgeService::class.java))
                android.widget.Toast.makeText(this, "Companion off; app video continues", android.widget.Toast.LENGTH_LONG).show()
            } else {
                runCatching { startForegroundService(Intent(this, BridgeService::class.java)) }
                    .onSuccess { android.widget.Toast.makeText(this, "Starting companion connection", android.widget.Toast.LENGTH_SHORT).show() }
                    .onFailure { android.widget.Toast.makeText(this, "Connection could not start. Open DroidBridge diagnostics.", android.widget.Toast.LENGTH_LONG).show() }
            }
            handler.postDelayed({ refresh() }, 500)
        }
    }

}
class OperationsTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening(); qsTile?.apply { label = "DroidBridge actions"; subtitle = "Apps, audio and phone display"
            state = Tile.STATE_ACTIVE; contentDescription = "$label. Open foreground quick actions"; updateTile() }
    }
    override fun onClick() {
        super.onClick(); unlockAndRun {
            if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(QuickAccess.pending(this, QuickAccess.intent(this), 102))
            else { @Suppress("DEPRECATION") startActivityAndCollapse(QuickAccess.intent(this).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        }
    }
}

package dev.droidbridge.companion

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import java.util.concurrent.Executors

class BridgeWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val pending = goAsync()
        executor.execute { try { updateAll(context, manager, ids) } finally { pending.finish() } }
    }
    companion object {
        private val executor = Executors.newSingleThreadExecutor()
        fun refresh(context: Context) {
            val manager = context.getSystemService(AppWidgetManager::class.java)
            val ids = manager.getAppWidgetIds(ComponentName(context, BridgeWidget::class.java))
            if (ids.isNotEmpty()) runCatching { updateAll(context, manager, ids) }
        }
        private fun updateAll(context: Context, manager: AppWidgetManager, ids: IntArray) {
            val store = BridgeStore.get(context); val peer = store.peerStatus()
            val connected = peer.optBoolean("connected"); val trust = store.selectedTrust()
            val favorites = context.getSharedPreferences("companion-ui", Context.MODE_PRIVATE).getStringSet("favorites", emptySet()) ?: emptySet()
            val catalog = store.catalogLocal()
            val apps = (0 until catalog.length()).map { catalog.getJSONObject(it) }.filter { it.optString("package_name") in favorites }.take(2)
            val view = RemoteViews(context.packageName, R.layout.bridge_widget)
            // Timestamp makes a killed service's last projection visibly historical.
            val time = java.text.DateFormat.getTimeInstance(java.text.DateFormat.SHORT).format(java.util.Date())
            view.setTextViewText(R.id.widget_status, "DroidBridge · ${QuickAccessState.label(store.running, connected)}")
            val windows = if (connected) " · ${peer.optJSONArray("sessions")?.length() ?: 0} app windows" else ""
            val mac = if (peer.isNull("mac_name")) "Choose a Mac" else peer.optString("mac_name").take(60)
            view.setTextViewText(R.id.widget_detail, "$mac$windows · updated $time")
            view.setOnClickPendingIntent(R.id.widget_status, QuickAccess.pending(context, QuickAccess.mainIntent(context, "Home"), 200))
            view.setOnClickPendingIntent(R.id.widget_actions, QuickAccess.pending(context, QuickAccess.intent(context), 201))
            for ((index, id) in listOf(R.id.widget_favorite1, R.id.widget_favorite2).withIndex()) {
                val app = apps.getOrNull(index)
                val intent: Intent
                if (app != null && trust != null) {
                    view.setTextViewText(id, "${app.optString("label")} on Mac")
                    intent = QuickAccess.appIntent(context, trust, app.getString("package_name"))
                } else {
                    view.setTextViewText(id, if (index == 0) "Apps on Mac" else "Sharing")
                    intent = QuickAccess.mainIntent(context, if (index == 0) "Apps" else "Sharing")
                }
                view.setOnClickPendingIntent(id, QuickAccess.pending(context, intent, 202 + index))
            }
            ids.forEach { manager.updateAppWidget(it, view) }
        }
    }
}

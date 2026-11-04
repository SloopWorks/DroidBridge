package dev.droidbridge.companion

import android.app.PendingIntent
import android.app.StatusBarManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.net.Uri

/** All external entry points open a foreground review. Intent extras never authorize an effect. */
object QuickAccess {
    const val OPEN_APP = "dev.droidbridge.companion.OPEN_ON_MAC"
    const val CONNECTION = "dev.droidbridge.companion.CONNECTION"
    const val TRUST = "trust_id"
    const val PACKAGE = "package_name"
    fun intent(context: Context) = Intent(context, QuickAccessActivity::class.java).setAction("dev.droidbridge.companion.QUICK_ACTIONS")
    fun open(context: Context) = context.startActivity(intent(context).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    fun appIntent(context: Context, trustId: String, packageName: String): Intent = intent(context).setAction(OPEN_APP)
        .setData(Uri.Builder().scheme("droidbridge").authority("open").appendPath(trustId).appendPath(packageName).build())
        .putExtra(TRUST, trustId).putExtra(PACKAGE, packageName)
    fun pinApp(context: Context, trustId: String, packageName: String, label: String): Boolean {
        require(ProtocolRules.packageName(packageName) && BridgeStore.get(context).trusted().has(trustId))
        val manager = context.getSystemService(ShortcutManager::class.java)
        if (!manager.isRequestPinShortcutSupported) return false
        val id = ProtocolRules.hash("$trustId:$packageName".toByteArray())
        val mac = BridgeStore.get(context).trusted().getJSONObject(trustId).optString("name", "Mac")
        return manager.requestPinShortcut(ShortcutInfo.Builder(context, id)
            .setShortLabel(label.take(35).ifBlank { packageName }).setLongLabel("Open $label on $mac")
            .setIcon(Icon.createWithResource(context, R.drawable.ic_bridge)).setIntent(appIntent(context, trustId, packageName)).build(), null)
    }
    fun pinWidget(context: Context): Boolean {
        val manager = context.getSystemService(AppWidgetManager::class.java)
        return manager.isRequestPinAppWidgetSupported && manager.requestPinAppWidget(ComponentName(context, BridgeWidget::class.java), null, null)
    }
    fun requestTile(context: Context, operations: Boolean, result: (Int) -> Unit = {}) {
        val component = ComponentName(context, if (operations) OperationsTileService::class.java else ConnectionTileService::class.java)
        context.getSystemService(StatusBarManager::class.java).requestAddTileService(component,
            if (operations) "DroidBridge actions" else "DroidBridge connection", Icon.createWithResource(context, R.drawable.ic_bridge_status),
            context.mainExecutor, result)
    }
    fun pending(context: Context, intent: Intent, request: Int = 0) = PendingIntent.getActivity(context, request, intent,
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    fun mainIntent(context: Context, tab: String) = Intent(context, MainActivity::class.java).setAction("dev.droidbridge.companion.$tab").putExtra("tab", tab)
}

/** Kept independent of Android so state and privacy semantics can be tested directly. */
internal object QuickAccessState {
    fun label(running: Boolean, connected: Boolean) = if (!running) "Off" else if (connected) "Connected" else "Waiting for Mac"
    fun detail(running: Boolean, connected: Boolean, mac: String, count: Int) = when {
        !running -> "Companion off · independent app video may continue"
        connected -> "$mac · $count app ${if (count == 1) "window" else "windows"}"
        else -> "Companion ready · waiting for authenticated Mac"
    }
}

package dev.droidbridge.companion

import android.app.Notification
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

class BridgeNotifications : NotificationListenerService() {
    private data class Reply(val notification: StatusBarNotification, val action: Notification.Action?, val actionId: String)
    override fun onListenerConnected() { listener = this }
    override fun onNotificationPosted(notification: StatusBarNotification) {
        val store = BridgeStore.get(this)
        val key = ProtocolRules.hash(notification.key.toByteArray())
        replies.remove(key) // A replacement invalidates every previously displayed action identity.
        if (!store.setting("notifications_enabled") || notification.packageName == packageName ||
            notification.notification.visibility != Notification.VISIBILITY_PUBLIC || notification.isOngoing ||
            notification.notification.flags and Notification.FLAG_FOREGROUND_SERVICE != 0) return
        val action = notification.notification.actions?.firstOrNull { it.remoteInputs?.any { input -> input.allowFreeFormInput } == true }
        val actionId = UUID.randomUUID().toString()
        replies[key] = Reply(notification, action, actionId)
        if (replies.size > 256) replies.keys.firstOrNull()?.let { replies.remove(it) }
        val extras = notification.notification.extras
        val payload = JSONObject().put("notification_key", key).put("package_name", notification.packageName)
            .put("title", extras.getCharSequence("android.title")?.toString()?.take(256) ?: "")
            .put("text", extras.getCharSequence("android.text")?.toString()?.take(4096) ?: "")
            .put("can_reply", action != null).put("action_id", actionId)
        store.trusted().keys().forEach { trustId -> if (store.notificationsAllowed(trustId, notification.packageName)) store.event("notification_posted", payload, trustId) }
    }
    override fun onNotificationRemoved(notification: StatusBarNotification) {
        val key = ProtocolRules.hash(notification.key.toByteArray()); replies.remove(key)
        val store = BridgeStore.get(this)
        store.trusted().keys().forEach { trustId -> if (store.notificationsAllowed(trustId, notification.packageName)) store.event("notification_removed", JSONObject().put("notification_key", key), trustId) }
    }
    override fun onListenerDisconnected() { replies.clear(); listener = null }
    companion object {
        private val replies = ConcurrentHashMap<String, Reply>()
        @Volatile private var listener: BridgeNotifications? = null
        fun reply(context: Context, key: String, actionId: String, text: String) {
            require(text.length in 1..4096)
            require(listener != null && android.provider.Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners").orEmpty().split(':').any { it.startsWith(context.packageName + "/") }) { "Notification access revoked" }
            val stored = replies[key] ?: throw IllegalArgumentException("Notification no longer available")
            require(stored.actionId == actionId) { "Notification action changed" }
            val current = listener?.activeNotifications?.firstOrNull { it.key == stored.notification.key }
                ?: throw IllegalArgumentException("Notification no longer available")
            require(current.postTime == stored.notification.postTime) { "Notification replaced" }
            val currentAction = stored.action ?: throw IllegalArgumentException("Notification does not support reply")
            val inputs = currentAction.remoteInputs.filter { it.allowFreeFormInput }.toTypedArray()
            val intent = Intent()
            RemoteInput.addResultsToIntent(inputs, intent, Bundle().apply { inputs.forEach { putCharSequence(it.resultKey, text) } })
            currentAction.actionIntent.send(context, 0, intent)
        }
        fun dismiss(key: String, actionId: String) {
            val stored = replies[key] ?: throw IllegalArgumentException("Notification identity unavailable")
            require(stored.actionId == actionId) { "Notification replaced" }
            val current = listener?.activeNotifications?.firstOrNull { ProtocolRules.hash(it.key.toByteArray()) == key }
                ?: throw IllegalArgumentException("Notification no longer available")
            require(current.postTime == stored.notification.postTime) { "Notification replaced" }
            listener?.cancelNotification(current.key)
        }
    }
}

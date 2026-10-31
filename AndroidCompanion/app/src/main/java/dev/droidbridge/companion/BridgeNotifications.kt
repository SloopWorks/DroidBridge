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

class BridgeNotifications : NotificationListenerService() {
    private data class Reply(val sourceKey: String, val postTime: Long, val action: Notification.Action?, val actionId: String)
    override fun onListenerConnected() {
        listener = this
        synchronized(replyLock) { replies.clear() }
        BridgeStore.get(this).clearNotificationExposure()
        activeNotifications?.take(256)?.forEach { onNotificationPosted(it) }
    }
    override fun onNotificationPosted(notification: StatusBarNotification) {
        val store = BridgeStore.get(this)
        val key = ProtocolRules.hash(notification.key.toByteArray())
        forgetAction(key) // Any replacement invalidates the previous action generation.
        if (!store.setting("notifications_enabled") || notification.packageName == packageName || !ProtocolRules.packageName(notification.packageName) || !eligible(notification) || !store.hasNotificationAudience(notification.packageName)) {
            store.publishNotification(key, notification.packageName, null)
            return
        }
        val action = notification.notification.actions?.firstOrNull { it.remoteInputs?.any { input -> input.allowFreeFormInput } == true }
        val actionId = UUID.randomUUID().toString()
        val evicted = synchronized(replyLock) {
            replies[key] = Reply(notification.key, notification.postTime, action, actionId)
            if (replies.size > 256) replies.keys.first().also { replies.remove(it) } else null
        }
        // Never acquire Store while holding replyLock. Store may revoke actions.
        evicted?.let { store.removeNotification(it) }
        val extras = notification.notification.extras
        val payload = JSONObject().put("notification_key", key).put("package_name", notification.packageName)
            .put("title", extras.getCharSequence("android.title")?.toString()?.take(256) ?: "")
            .put("text", extras.getCharSequence("android.text")?.toString()?.take(4096) ?: "")
            .put("can_reply", action != null).put("action_id", actionId)
        store.publishNotification(key, notification.packageName, payload)
    }
    override fun onNotificationRemoved(notification: StatusBarNotification) {
        val key = ProtocolRules.hash(notification.key.toByteArray())
        val current = synchronized(replyLock) { replies[key] }
        if (current != null && current.postTime != notification.postTime) return
        forgetAction(key); BridgeStore.get(this).removeNotification(key)
    }
    override fun onListenerDisconnected() {
        synchronized(replyLock) { replies.clear() }; listener = null
        BridgeStore.get(this).clearNotificationExposure()
    }
    companion object {
        private val replyLock = Any()
        private val replies = LinkedHashMap<String, Reply>()
        @Volatile private var listener: BridgeNotifications? = null
        internal fun forgetAction(key: String) { synchronized(replyLock) { replies.remove(key) } }
        private fun eligible(notification: StatusBarNotification): Boolean = notification.notification.visibility == Notification.VISIBILITY_PUBLIC &&
            !notification.isOngoing && notification.notification.flags and Notification.FLAG_FOREGROUND_SERVICE == 0
        fun reply(context: Context, key: String, actionId: String, text: String) {
            require(text.length <= 4096 && text.toByteArray(Charsets.UTF_8).size in 1..4096)
            require(listener != null && android.provider.Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners").orEmpty().split(':').any { it.startsWith(context.packageName + "/") }) { "Notification access revoked" }
            val stored = synchronized(replyLock) { replies[key] } ?: throw IllegalArgumentException("Notification no longer available")
            require(stored.actionId == actionId) { "Notification action changed" }
            val current = listener?.activeNotifications?.firstOrNull { it.key == stored.sourceKey }
                ?: throw IllegalArgumentException("Notification no longer available")
            require(current.postTime == stored.postTime && eligible(current)) { "Notification replaced or private" }
            val currentAction = stored.action ?: throw IllegalArgumentException("Notification does not support reply")
            val inputs = currentAction.remoteInputs.filter { it.allowFreeFormInput }.toTypedArray()
            val intent = Intent()
            RemoteInput.addResultsToIntent(inputs, intent, Bundle().apply { inputs.forEach { putCharSequence(it.resultKey, text) } })
            currentAction.actionIntent.send(context, 0, intent)
        }
        fun dismiss(key: String, actionId: String) {
            val stored = synchronized(replyLock) { replies[key] } ?: throw IllegalArgumentException("Notification identity unavailable")
            require(stored.actionId == actionId) { "Notification replaced" }
            val activeListener = listener ?: throw IllegalArgumentException("Notification access unavailable")
            val current = activeListener.activeNotifications?.firstOrNull { it.key == stored.sourceKey }
                ?: throw IllegalArgumentException("Notification no longer available")
            require(current.postTime == stored.postTime && eligible(current)) { "Notification replaced or private" }
            activeListener.cancelNotification(current.key)
        }
    }
}

package dev.droidbridge.companion

import android.app.Activity
import android.content.Context

/** Release twin contains no diagnostic collector, SWIP identity, inspector or transport. */
object CompanionDiagnostics {
    const val available = false
    fun initialize(context: Context) {}
    fun open(activity: Activity) {}
    fun setEnabled(value: Boolean) {}
    fun record(operation: String, outcome: String, durationMs: Long) {}
}

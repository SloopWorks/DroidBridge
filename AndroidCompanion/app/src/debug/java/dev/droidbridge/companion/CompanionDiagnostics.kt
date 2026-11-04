package dev.droidbridge.companion

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.SystemClock
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.sloopworks.debugdrawer.BuildInfo
import com.sloopworks.debugdrawer.DebugDrawer
import com.sloopworks.debugdrawer.DebugDrawerConfig
import com.sloopworks.debugdrawer.DebugDrawerHost
import com.sloopworks.debugdrawer.swip.SecureWindow
import com.sloopworks.debugdrawer.swip.SwipInspectorPlugin
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import works.sloop.swip.CollectionMode
import works.sloop.swip.ConsentDecision
import works.sloop.swip.ConsentScope
import works.sloop.swip.InMemorySwipStorage
import works.sloop.swip.Swip
import works.sloop.swip.SwipDebugSink
import works.sloop.swip.debug.RingDebugSink
import works.sloop.swip.schema.droidbridge.CompanionActionFinished
import works.sloop.swip.schema.droidbridge.DroidbridgeSwip
import kotlin.random.Random

/** Debug source-set boundary: no collectors, source keys, Compose inspector or upload in release. */
object CompanionDiagnostics {
    const val available = true
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    internal var collectionEnabled by mutableStateOf(false)
        private set
    internal val ring = RingDebugSink(scope, System::currentTimeMillis, maxEntries = 200)
    // Gate observation too: denied-consent drop records must not become a shadow history.
    private val sink = object : SwipDebugSink {
        override fun record(rec: works.sloop.swip.DebugRecord) { if (collectionEnabled) ring.record(rec) }
    }
    private val swip by lazy {
        Swip.init(
            DroidbridgeSwip.androidDev(),
            DroidbridgeSwip.platformDeps(
                storage = InMemorySwipStorage(), appVersion = BuildConfig.VERSION_NAME,
                os = "android", nowMs = System::currentTimeMillis,
                monotonicNowMs = SystemClock::elapsedRealtime, random = Random::nextDouble,
            ).copy(debuggable = true, debugSink = sink), scope,
        )
    }
    fun initialize(context: Context) { /* Remains lazy until explicit debug UI/opt-in. */ }
    fun open(activity: Activity) { activity.startActivity(Intent(activity, CompanionDiagnosticsActivity::class.java)) }
    fun setEnabled(value: Boolean) {
        if (value) {
            collectionEnabled = true
            swip.analytics.setConsent(mapOf(ConsentScope.ANALYTICS to ConsentDecision.GRANTED))
            swip.analytics.setCollectionMode(CollectionMode.ANONYMOUS)
        } else {
            collectionEnabled = false
            swip.analytics.setCollectionMode(CollectionMode.OFF)
            swip.analytics.setConsent(mapOf(ConsentScope.ANALYTICS to ConsentDecision.DENIED))
            ring.clear()
        }
    }
    /** Only bounded categorical data crosses into SWIP; no trust/package/URL/path/content. */
    fun record(operation: String, outcome: String, durationMs: Long) {
        if (!collectionEnabled) return
        val op = CompanionActionFinished.Operation.entries.firstOrNull { it.name.equals(operation, true) } ?: return
        val result = CompanionActionFinished.Outcome.entries.firstOrNull { it.name.equals(outcome, true) } ?: return
        if (durationMs !in 0..300000) return
        swip.analytics.track(CompanionActionFinished(op, result, durationMs))
    }
}

class CompanionDiagnosticsActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val secure = object : SecureWindow {
            override fun set() { window.addFlags(WindowManager.LayoutParams.FLAG_SECURE) }
            override fun clear() { window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE) }
        }
        DebugDrawer.install(DebugDrawerConfig(
            buildInfo = BuildInfo(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE.toString(), BuildConfig.BUILD_TYPE),
            plugins = listOf(SwipInspectorPlugin(CompanionDiagnostics.ring.entries, secure, false)),
        ), applicationContext)
        setContent {
            MaterialTheme {
                Box(Modifier.fillMaxSize().safeDrawingPadding()) {
                    DebugDrawerHost {
                        Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                            Text("Local diagnostics", style = MaterialTheme.typography.headlineMedium)
                            Text("Debug build only. Off at process start. When enabled, up to 200 bounded action outcomes stay in memory. No shared text, files, app or Mac identities, uploads, or persistent analytics.")
                            Row {
                                Text("Collect local diagnostics", Modifier.weight(1f))
                                Switch(CompanionDiagnostics.collectionEnabled, CompanionDiagnostics::setEnabled)
                            }
                            Text("Open the SloopWorks debug bubble to inspect SWIP events. Turning collection off immediately clears the ring.")
                            Button(onClick = { finish() }) { Text("Back to DroidBridge") }
                        }
                    }
                }
            }
        }
    }
}

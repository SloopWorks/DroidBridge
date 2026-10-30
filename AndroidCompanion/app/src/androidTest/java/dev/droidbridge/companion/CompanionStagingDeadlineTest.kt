package dev.droidbridge.companion

import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.net.Uri
import android.os.SystemClock
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class CompanionStagingDeadlineTest {
    @Test fun stalledPipeDeadlineAndCancelUnblockReadersAndRestoreCapacity() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val target = instrumentation.targetContext
        val token = UUID.randomUUID().toString()
        val prefix = "content://dev.droidbridge.companion.test.staging/"
        fun uri(path: String) = Uri.parse(prefix + path)
        // Shell starts only this exported test-APK grant Activity; the URI owner itself
        // grants nonce-scoped reads. No shell grant or provider permission bypass occurs.
        val launched = android.os.ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(
            "am start -W -n dev.droidbridge.companion.test/dev.droidbridge.companion.StagingGrantActivity --es token $token")).use { it.readBytes().toString(Charsets.UTF_8) }
        assertTrue("Fixture grant Activity started", launched.contains("Status: ok"))
        fun pipeCount(): Int = target.contentResolver.query(uri("status/$token"), null, null, null, null)!!.use { check(it.moveToFirst()); it.getInt(0) }
        val grantDeadline = SystemClock.elapsedRealtime() + 5000
        while (runCatching { pipeCount() }.isFailure && SystemClock.elapsedRealtime() < grantDeadline) Thread.sleep(40)
        assertEquals("Explicit nonce URI grant active", 0, pipeCount())
        val directory = File(target.cacheDir, "staging-$token").apply { mkdirs() }
        val context = object : ContextWrapper(target) {
            override fun getFilesDir() = directory
            override fun getSharedPreferences(name: String, mode: Int) = target.getSharedPreferences("staging-$token-$name", mode)
        }
        val store = BridgeStore::class.java.getDeclaredConstructor(Context::class.java).apply { isAccessible = true }.newInstance(context)
        val secret = store.startPairing()
        val pending = store.requestPair(JSONObject().put("request_id", UUID.randomUUID().toString()).put("pairing_secret", secret)
            .put("mac_id", UUID.randomUUID().toString()).put("mac_name", "Staging deadline fixture"))
        store.approvePair()
        val trust = store.pollPair(pending.getString("pairing_id"), secret).getString("trust_id")
        store.denyPair()
        val workers = Executors.newFixedThreadPool(2)
        fun awaitPipes(count: Int) {
            val until = SystemClock.elapsedRealtime() + 5000
            while (pipeCount() != count && SystemClock.elapsedRealtime() < until) Thread.sleep(40)
            assertEquals("Real provider pipes opened", count, pipeCount())
        }
        fun cleanupProvider() { target.contentResolver.openFileDescriptor(uri("cleanup/$token"), "r")!!.close() }
        fun ready() = store.transfers.stage(uri("small/$token"), trust).also { assertEquals("ready", it.getString("status")); assertEquals(21L, it.getLong("size")) }
        try {
            val start = SystemClock.elapsedRealtime()
            val reads = listOf("a", "b").map { suffix -> workers.submit<Boolean> { runCatching { store.transfers.stage(uri("stall/$token/$suffix"), trust) }.isFailure } }
            awaitPipes(2)
            try { store.transfers.stage(uri("small/$token"), trust); fail("Third staging reader admitted") } catch (expected: BridgeFailure) { assertEquals(429, expected.status) }
            reads.forEach { assertTrue("Deadline unblocks a real stalled pipe", it.get(37, TimeUnit.SECONDS)) }
            val elapsed = SystemClock.elapsedRealtime() - start
            assertTrue("Actual production 30s deadline exercised", elapsed in 29000..37000)
            assertEquals("Provider never sent EOF; reader cancellation unblocked read", 2, pipeCount())
            assertTrue((0 until store.transfers.listLocal().length()).all { store.transfers.listLocal().getJSONObject(it).getString("status") == "failed" })
            cleanupProvider()
            val recovered = ready(); store.transfers.cancelLocal(recovered.getString("transfer_id"))
            val cancelled = workers.submit<Boolean> { runCatching { store.transfers.stage(uri("stall/$token/a"), trust) }.isFailure }
            awaitPipes(1)
            val records = store.transfers.listLocal()
            val active = (0 until records.length()).map { records.getJSONObject(it) }.single { it.getString("status") == "staging" }
            val cancelStart = SystemClock.elapsedRealtime()
            store.transfers.cancelLocal(active.getString("transfer_id"))
            assertTrue("Explicit cancel unblocks pipe read", cancelled.get(4, TimeUnit.SECONDS))
            val cancelElapsed = SystemClock.elapsedRealtime() - cancelStart
            assertEquals(1, pipeCount()); cleanupProvider()
            val afterCancel = ready(); store.transfers.cancelLocal(afterCancel.getString("transfer_id"))
            instrumentation.addResults(android.os.Bundle().apply { putString("droidbridge_staging_evidence", JSONObject()
                .put("deadline_ms", elapsed).put("cancel_ms", cancelElapsed).put("stalled_pipes", 2)
                .put("deadline_freed_capacity", true).put("cancel_freed_capacity", true).put("provider_eof_before_cleanup", false).toString()) })
        } finally {
            cleanupProvider(); workers.shutdownNow(); workers.awaitTermination(5, TimeUnit.SECONDS); directory.deleteRecursively()
        }
    }
}

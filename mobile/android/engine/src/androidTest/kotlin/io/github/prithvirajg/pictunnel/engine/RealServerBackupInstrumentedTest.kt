package io.github.prithvirajg.pictunnel.engine

import android.content.Context
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.prithvirajg.pictunnel.engine.bridge.AndroidHostBackend
import io.github.prithvirajg.pictunnel.engine.bridge.BackupStatus
import io.github.prithvirajg.pictunnel.engine.bridge.EngineHost
import io.github.prithvirajg.pictunnel.engine.bridge.EngineServices
import io.github.prithvirajg.pictunnel.engine.bridge.FlutterError
import io.github.prithvirajg.pictunnel.engine.bridge.PairRequest
import io.github.prithvirajg.pictunnel.engine.bridge.PairResult
import io.github.prithvirajg.pictunnel.engine.bridge.ServerConnection
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.suspendCancellableCoroutine
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.coroutines.resume

/**
 * The first real backup end to end (tools/ci/android-e2e.sh): a `pictunnel serve`
 * built from this branch runs on the host, reachable from the emulator at
 * 10.0.2.2. The script creates the admin and a pairing code, pushes a JPEG into
 * MediaStore, then instruments this test with
 *
 *     -e qrUri 'pictunnel://pair?…'  -e sha256 <hex of the pushed file>
 *
 * The test pairs through the real [EngineHost] and [AndroidHostBackend] (the
 * same objects MainActivity registers, with the process set up like
 * PicTunnelApp), starts the engine and asks for "Back up now", then waits until
 * the pushed file is BackedUp. The script then checks on the server that the
 * asset exists and its original has the same SHA-256.
 *
 * Without the arguments (for example in connectedDebugAndroidTest) it is
 * skipped; the e2e script fails on a skip.
 */
@RunWith(AndroidJUnit4::class)
class RealServerBackupInstrumentedTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val args: Bundle get() = InstrumentationRegistry.getArguments()

    @Test fun pairsAndBacksUpAPhotoToARealServer() =
        runBlocking {
            val qr = args.getString("qrUri")
            val sha = args.getString("sha256")
            assumeTrue("needs -e qrUri and -e sha256 (see class doc)", qr != null && sha != null)

            // As PicTunnelApp.onCreate and MainActivity.configureFlutterEngine do.
            EngineServices.installRuntime(context)
            val services = EngineServices.get(context)
            val host =
                EngineHost(
                    AndroidHostBackend(context, services, launcher = { null }),
                    CoroutineScope(SupervisorJob() + Dispatchers.Default),
                    deliver = { it.run() },
                )

            val paired = host.await<PairResult> { cb -> pair(PairRequest(qrUri = qr, deviceName = "CI emulator"), cb) }
            assertEquals("admin", paired.userName)
            assertTrue(paired.serverId.isNotEmpty())
            val conn = host.await<ServerConnection?> { cb -> serverInfo(cb) }
            assertNotNull("serverInfo after pairing", conn)
            assertEquals(43, conn!!.fpFull.length)

            host.await<Unit> { cb -> start(cb) }
            host.await<Unit> { cb -> runNow(cb) }

            val deadline = System.currentTimeMillis() + TIMEOUT_MS
            while (true) {
                val items = services.db.items().bySha(sha!!)
                if (items.any { it.state == ItemState.BackedUp && it.assetId != null }) break
                if (System.currentTimeMillis() > deadline) fail("the pushed photo was not backed up in time\n" + diagnostics(services, sha, host))
                delay(POLL_MS)
            }
            val status = host.await<BackupStatus> { cb -> getStatus(cb) }
            assertTrue("status counts the backup: $status", status.backedUp >= 1)
            assertEquals("nothing needs attention: $status", 0L, status.needsAttention)
        }

    private suspend fun diagnostics(
        services: EngineServices,
        sha: String,
        host: EngineHost,
    ): String {
        val dao = services.db.items()
        val rows = dao.allIds().mapNotNull { dao.get(it) }
        val status = runCatching { host.await<BackupStatus> { cb -> getStatus(cb) } }
        val activity = runCatching { services.db.activity().latest(30) }.getOrDefault(emptyList())
        return buildString {
            appendLine("expected sha256 $sha")
            appendLine("status: ${status.getOrNull() ?: status.exceptionOrNull()}")
            appendLine("items (${rows.size}):")
            rows.forEach { appendLine("  ${it.localId} ${it.filename} ${it.state} sha=${it.sha256} attempts=${it.attempts} err=${it.lastError}") }
            appendLine("activity:")
            activity.forEach { appendLine("  ${it.atMs} ${it.kind} ${it.localId} ${it.message}") }
        }
    }

    private companion object {
        const val TIMEOUT_MS = 5 * 60 * 1000L
        const val POLL_MS = 1_000L

        /** One Pigeon call, as Flutter makes it: the reply arrives through the callback. */
        suspend fun <T> EngineHost.await(call: EngineHost.((Result<T>) -> Unit) -> Unit): T {
            val r = suspendCancellableCoroutine { cont -> call { r -> cont.resume(r) } }
            r.exceptionOrNull()?.let { e ->
                val code = (e as? FlutterError)?.code
                throw AssertionError("engine call failed: code=$code message=${e.message}", e)
            }
            return r.getOrThrow()
        }
    }
}

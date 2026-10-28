package io.github.prithvirajg.pictunnel.engine.sched

import android.content.Context
import android.provider.MediaStore
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.ListenableWorker
import androidx.work.NetworkType
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.TestListenableWorkerBuilder
import androidx.work.testing.WorkManagerTestInitHelper
import io.github.prithvirajg.pictunnel.engine.core.Deleter
import io.github.prithvirajg.pictunnel.engine.core.EngineSettings
import io.github.prithvirajg.pictunnel.engine.core.MediaAccess
import io.github.prithvirajg.pictunnel.engine.core.PauseState
import io.github.prithvirajg.pictunnel.engine.core.StopReason
import io.github.prithvirajg.pictunnel.engine.model.PauseReason
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SchedulingTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val engine = FakeEngine()
    private val now = 1_760_000_000_000L
    private val min = 60_000L

    @Before fun setUp() {
        WorkManagerTestInitHelper.initializeTestWorkManager(
            context,
            Configuration.Builder().setExecutor(SynchronousExecutor()).setMinimumLoggingLevel(android.util.Log.DEBUG).build(),
        )
        EngineRuntime.install { engine }
    }

    @After fun tearDown() {
        EngineRuntime.install(null)
    }

    private fun wm() = WorkManager.getInstance(context)

    private fun syncInfos(): List<WorkInfo> = wm().getWorkInfosForUniqueWork(Scheduling.SYNC).get()

    private fun pending(): List<WorkInfo> = syncInfos().filter { !it.state.isFinished }

    // ---- pure decisions ------------------------------------------------------

    @Test fun constraintsFollowSettings() {
        val any = Scheduling.constraints(EngineSettings())
        assertEquals(NetworkType.CONNECTED, any.requiredNetworkType)
        assertFalse(any.requiresCharging())
        val strict = Scheduling.constraints(EngineSettings(wifiOnly = true, chargingOnly = true))
        assertEquals(NetworkType.UNMETERED, strict.requiredNetworkType)
        assertTrue(strict.requiresCharging())
    }

    @Test fun nextRunFollowsTheReport() {
        fun next(
            stop: StopReason,
            at: Long? = null,
            pause: PauseState? = null,
        ) = Scheduling.nextSyncDelayMs(report(stop, at), pause, now)
        // Out of budget with work left: again soon.
        assertEquals(Scheduling.BUDGET_FOLLOW_UP_MS, next(StopReason.Budget))
        // Backoff pending: one-time work at that time.
        assertEquals(90_000L, next(StopReason.Idle, now + 90_000))
        assertEquals(0L, next(StopReason.Idle, now - 5))
        // R10: never beyond the 15 min cap.
        assertEquals(15 * min, next(StopReason.Idle, now + 600 * min))
        // Idle with nothing waiting: the content trigger and the 6 h job take over.
        assertNull(next(StopReason.Idle))
        assertEquals(Scheduling.OFFLINE_RETRY_MS, next(StopReason.Offline))
        assertEquals(30 * min, next(StopReason.Paused, pause = PauseState(PauseReason.ServerFull, now + 30 * min)))
        assertNull(next(StopReason.Paused, pause = PauseState(PauseReason.User, null)))
        assertEquals(60 * min, next(StopReason.ServerUntrusted, pause = PauseState(PauseReason.Permission, now + 60 * min)))
        assertNull(next(StopReason.NeedsRepair, now + 1000))
    }

    // ---- WorkManager -----------------------------------------------------------

    @Test fun requestSyncIsUniqueWorkWithSettingsConstraints() =
        runBlocking {
            engine.settings = EngineSettings(wifiOnly = true)
            Scheduling.requestSync(context, engine)
            Scheduling.requestSync(context, engine)
            val infos = pending()
            assertEquals(1, infos.size)
            assertEquals(WorkInfo.State.ENQUEUED, infos[0].state)
            assertEquals(NetworkType.UNMETERED, infos[0].constraints.requiredNetworkType)
        }

    @Test fun soonerRequestReplacesALaterOne() =
        runBlocking {
            Scheduling.requestSync(context, engine, delayMs = 10 * min)
            val later = pending().single()
            Scheduling.requestSync(context, engine, delayMs = 20 * min)
            assertEquals("a later request keeps the sooner run", later.id, pending().single().id)
            Scheduling.requestSync(context, engine, delayMs = 0)
            val now = pending().single()
            assertTrue(now.id != later.id)
        }

    @Test fun ensureSchedulesPeriodicScanAndContentTrigger() {
        Scheduling.ensure(context)
        val periodic = wm().getWorkInfosForUniqueWork(Scheduling.SCAN_PERIODIC).get().single()
        assertEquals(6 * 60 * min, periodic.periodicityInfo!!.repeatIntervalMillis)
        val trigger = wm().getWorkInfosForUniqueWork(Scheduling.SCAN_TRIGGER).get().single()
        val uris = trigger.constraints.contentUriTriggers.map { it.uri }
        assertTrue(uris.contains(MediaStore.Images.Media.EXTERNAL_CONTENT_URI))
        assertTrue(uris.contains(MediaStore.Video.Media.EXTERNAL_CONTENT_URI))
        assertTrue(trigger.constraints.contentUriTriggers.all { it.isTriggeredForDescendants })
    }

    @Test fun syncWorkerReschedulesFromTheReport() =
        runBlocking {
            engine.onRun = { report(StopReason.Budget) }
            val result = TestListenableWorkerBuilder<SyncWorker>(context).build().doWork()
            assertEquals(ListenableWorker.Result.success(), result)
            assertEquals(listOf("run", "run-end"), engine.calls)
            assertEquals(1, pending().size)
        }

    @Test fun syncWorkerIdleLeavesItToTheTriggers() =
        runBlocking {
            engine.onRun = { report(StopReason.Idle) }
            TestListenableWorkerBuilder<SyncWorker>(context).build().doWork()
            assertTrue(pending().isEmpty())
        }

    @Test fun syncWorkerDoesNothingWithoutMediaAccess() =
        runBlocking {
            engine.access = MediaAccess.None
            assertEquals(ListenableWorker.Result.success(), TestListenableWorkerBuilder<SyncWorker>(context).build().doWork())
            assertTrue(engine.calls.isEmpty())
        }

    @Test fun scanWorkerRequestsSyncWhenItFindsWork() =
        runBlocking {
            engine.scanResult = 3
            TestListenableWorkerBuilder<ScanWorker>(context).build().doWork()
            assertEquals(listOf("scan"), engine.calls)
            assertEquals(1, pending().size)
        }

    @Test fun scanWorkerWithNothingNewSchedulesNothing() =
        runBlocking {
            engine.scanResult = 0
            TestListenableWorkerBuilder<ScanWorker>(context).build().doWork()
            assertTrue(pending().isEmpty())
        }

    @Test fun freeUpSpaceStopsTheRunningSyncFirstThenReschedules() =
        runBlocking {
            engine.onRun = { awaitCancellation() }
            val run = async(kotlinx.coroutines.Dispatchers.Default) { EngineRuntime.runs.run(engine, io.github.prithvirajg.pictunnel.engine.core.RunBudget()) }
            withTimeout(5_000) { engine.runStarted.await() }
            val result =
                withTimeout(5_000) {
                    EngineRuntime.freeUpSpace(context, listOf("a"), Deleter { ids -> ids.toSet() })
                }
            assertEquals(1, result.freedCount)
            assertNull("a preempted run reports nothing", withTimeout(5_000) { run.await() })
            assertEquals(listOf("run", "run-cancelled", "free-up"), engine.calls)
            assertEquals("the backup is rescheduled after freeing", 1, pending().size)
        }

    @Test fun noRunStartsWhileFreeUpSpaceIsRunning() =
        runBlocking {
            val r =
                EngineRuntime.runs.preempt {
                    EngineRuntime.runs.run(engine, io.github.prithvirajg.pictunnel.engine.core.RunBudget())
                }
            assertNull(r)
            assertTrue(engine.calls.isEmpty())
        }

    @Test fun pauseActionPausesAndStopsTheRun() =
        runBlocking {
            engine.onRun = { awaitCancellation() }
            val run = async(kotlinx.coroutines.Dispatchers.Default) { EngineRuntime.runs.run(engine, io.github.prithvirajg.pictunnel.engine.core.RunBudget()) }
            withTimeout(5_000) { engine.runStarted.await() }
            EngineRuntime.pauseFromNotification(context)
            assertNull(withTimeout(5_000) { run.await() })
            assertTrue(engine.calls.contains("pause:User"))
            assertTrue(engine.calls.contains("run-cancelled"))
        }

    @Test fun networkChangeResetsEndpointsAndRequestsSync() =
        runBlocking {
            EngineRuntime.onNetworkChanged(context)
            assertEquals(listOf("network"), engine.calls)
            assertEquals(1, pending().size)
        }
}

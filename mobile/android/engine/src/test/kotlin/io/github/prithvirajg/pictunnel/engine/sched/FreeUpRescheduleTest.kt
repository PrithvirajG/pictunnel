package io.github.prithvirajg.pictunnel.engine.sched

import android.content.Context
import android.os.Looper
import androidx.test.core.app.ApplicationProvider
import androidx.work.Configuration
import androidx.work.ListenableWorker
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.TestListenableWorkerBuilder
import androidx.work.testing.WorkManagerTestInitHelper
import io.github.prithvirajg.pictunnel.engine.core.Deleter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.util.concurrent.Executors

/** Free-up space preempting a sync must never lose the next backup run (review fix 1). */
@RunWith(RobolectricTestRunner::class)
class FreeUpRescheduleTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val engine = FakeEngine()

    @Before fun setUp() {
        // A real executor: the worker must keep running while the test frees space.
        WorkManagerTestInitHelper.initializeTestWorkManager(
            context,
            Configuration.Builder().setExecutor(Executors.newFixedThreadPool(2)).build(),
        )
        EngineRuntime.runs.followUp.set(false)
        EngineRuntime.install { engine }
    }

    @After fun tearDown() {
        EngineRuntime.install(null)
        EngineRuntime.runs.followUp.set(false)
    }

    private fun infos(): List<WorkInfo> = WorkManager.getInstance(context).getWorkInfosForUniqueWork(Scheduling.SYNC).get()

    @Test fun preemptedWorkerSchedulesTheFollowUpItWasAskedFor() =
        runBlocking {
            engine.onRun = { awaitCancellation() }
            val worker = TestListenableWorkerBuilder<SyncWorker>(context).build()
            val result = async(Dispatchers.Default) { worker.doWork() }
            withTimeout(5_000) { engine.runStarted.await() }
            EngineRuntime.runs.followUp.set(true)
            EngineRuntime.runs.cancelRuns()
            assertEquals(ListenableWorker.Result.success(), withTimeout(5_000) { result.await() })
            assertFalse(EngineRuntime.runs.followUp.get())
            assertEquals(1, infos().count { !it.state.isFinished })
        }

    @Test fun freeUpDuringARunningSyncWorkerReschedulesTheBackup() =
        runBlocking {
            engine.onRun = { awaitCancellation() }
            Scheduling.requestSync(context, engine)
            val first = infos().single()
            WorkManagerTestInitHelper.getTestDriver(context)!!.setAllConstraintsMet(first.id)
            withTimeout(10_000) { engine.runStarted.await() }

            val freed = withTimeout(10_000) { EngineRuntime.freeUpSpace(context, listOf("a"), Deleter { it.toSet() }) }
            assertEquals(1, freed.freedCount)

            // The preempted worker ends; a new sync must be waiting after it.
            withTimeout(10_000) {
                while (true) {
                    shadowOf(Looper.getMainLooper()).idle()
                    val all = infos()
                    val done = all.firstOrNull { it.id == first.id }?.state?.isFinished ?: true
                    if (done && all.any { it.id != first.id && it.state == WorkInfo.State.ENQUEUED }) break
                    Thread.sleep(20)
                }
            }
            assertTrue(engine.calls.containsAll(listOf("run", "run-cancelled", "free-up")))
        }
}

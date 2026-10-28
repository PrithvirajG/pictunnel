package io.github.prithvirajg.pictunnel.engine

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.Configuration
import androidx.work.NetworkType
import androidx.work.WorkInfo
import androidx.work.WorkManager
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.WorkManagerTestInitHelper
import io.github.prithvirajg.pictunnel.engine.core.BackupEngine
import io.github.prithvirajg.pictunnel.engine.core.Deleter
import io.github.prithvirajg.pictunnel.engine.core.EngineSettings
import io.github.prithvirajg.pictunnel.engine.core.FreeUpResult
import io.github.prithvirajg.pictunnel.engine.core.MediaAccess
import io.github.prithvirajg.pictunnel.engine.core.PauseState
import io.github.prithvirajg.pictunnel.engine.core.RemainingWork
import io.github.prithvirajg.pictunnel.engine.core.RunBudget
import io.github.prithvirajg.pictunnel.engine.core.RunReport
import io.github.prithvirajg.pictunnel.engine.core.StopReason
import io.github.prithvirajg.pictunnel.engine.model.PauseReason
import io.github.prithvirajg.pictunnel.engine.sched.EngineRuntime
import io.github.prithvirajg.pictunnel.engine.sched.Scheduling
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.atomic.AtomicInteger

@RunWith(AndroidJUnit4::class)
class WorkManagerInstrumentedTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()

    private class CountingEngine : BackupEngine {
        val runs = AtomicInteger()

        override suspend fun runOnce(budget: RunBudget): RunReport {
            runs.incrementAndGet()
            return RunReport(0, 0, 0, 0, 0, 0, StopReason.Idle, null)
        }

        override suspend fun scanNow(): Int? = 0

        override suspend fun freeUpSpace(
            localIds: List<String>?,
            deleter: Deleter,
        ) = FreeUpResult(0, 0, emptyList())

        override suspend fun pause(reason: PauseReason) = Unit

        override suspend fun pauseState(): PauseState? = null

        override suspend fun remainingWork() = RemainingWork(0, 0)

        override suspend fun onNetworkChanged() = Unit

        override suspend fun getSettings() = EngineSettings(wifiOnly = true)

        override fun mediaAccess() = MediaAccess.Full
    }

    private val engine = CountingEngine()

    @Before fun setUp() {
        WorkManagerTestInitHelper.initializeTestWorkManager(context, Configuration.Builder().setExecutor(SynchronousExecutor()).build())
        EngineRuntime.install { engine }
    }

    @After fun tearDown() = EngineRuntime.install(null)

    @Test fun workManagerRunsSyncWithTestDriver() =
        runBlocking {
            Scheduling.requestSync(context, engine)
            val wm = WorkManager.getInstance(context)
            val info = wm.getWorkInfosForUniqueWork(Scheduling.SYNC).get().single()
            assertEquals(WorkInfo.State.ENQUEUED, info.state)
            assertEquals(NetworkType.UNMETERED, info.constraints.requiredNetworkType)
            assertEquals(0, engine.runs.get())
            // Wi-Fi only: the run waits until the driver reports the constraints met.
            WorkManagerTestInitHelper.getTestDriver(context)!!.setAllConstraintsMet(info.id)
            assertEquals(WorkInfo.State.SUCCEEDED, wm.getWorkInfoById(info.id).get()!!.state)
            assertEquals(1, engine.runs.get())
        }
}

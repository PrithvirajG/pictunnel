package io.github.prithvirajg.pictunnel.engine.sched

import android.content.Context
import io.github.prithvirajg.pictunnel.engine.core.BackupEngine
import io.github.prithvirajg.pictunnel.engine.core.Deleter
import io.github.prithvirajg.pictunnel.engine.core.FreeUpResult
import io.github.prithvirajg.pictunnel.engine.core.RunBudget
import io.github.prithvirajg.pictunnel.engine.core.RunReport
import io.github.prithvirajg.pictunnel.engine.model.PauseReason
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.isActive
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Tracks the pipeline runs of this process (SyncWorker, the foreground
 * service) so they can be stopped cooperatively: free-up-space and the
 * notification's Pause must not wait behind a long backup.
 */
class RunCoordinator {
    private val jobs: MutableSet<Job> = ConcurrentHashMap.newKeySet()
    private val preempting = AtomicInteger(0)

    /** Set when a sync was requested while one was running; the running one schedules a follow-up. */
    val followUp = AtomicBoolean(false)

    /** One engine run; null when it was preempted (or refused because a preemption is in progress). */
    suspend fun run(
        engine: BackupEngine,
        budget: RunBudget,
    ): RunReport? {
        if (preempting.get() > 0) return null
        return coroutineScope {
            val job = async { engine.runOnce(budget) }
            jobs += job
            // A preemption that began while registering must still stop this run.
            if (preempting.get() > 0) job.cancel()
            try {
                job.await()
            } catch (e: CancellationException) {
                // Our caller was cancelled (WorkManager stopped the worker): propagate.
                if (!isActive) throw e
                null
            } finally {
                jobs -= job
            }
        }
    }

    /** Stops every run in progress (each returns null to its caller). */
    fun cancelRuns() {
        jobs.forEach { it.cancel() }
    }

    /** Stops the runs in progress, waits until they have ended, then runs [block] with no run starting meanwhile. */
    suspend fun <T> preempt(block: suspend () -> T): T {
        preempting.incrementAndGet()
        try {
            jobs.toList().forEach { it.cancelAndJoin() }
            return block()
        } finally {
            preempting.decrementAndGet()
        }
    }
}

/**
 * The process-wide link between Android components (workers, the foreground
 * service, receivers, the network monitor) and the engine. The app installs
 * a provider at startup (Task 10 builds the [io.github.prithvirajg.pictunnel.engine.core.EngineController]);
 * it returns null while the app is not paired, and background work then does nothing.
 */
object EngineRuntime {
    @Volatile private var provider: ((Context) -> BackupEngine?)? = null

    val runs = RunCoordinator()

    fun install(provider: ((Context) -> BackupEngine?)?) {
        this.provider = provider
    }

    fun engine(context: Context): BackupEngine? = provider?.invoke(context.applicationContext)

    /** Call once per process after [install]: network callbacks plus the scan schedule. */
    fun start(context: Context) {
        NetworkMonitor.register(context.applicationContext)
        Scheduling.ensure(context.applicationContext)
    }

    /**
     * Free up space (M§4.5) without waiting behind a backup: the running sync
     * is cancelled cooperatively (its rows are resumable, R1), the free-up runs,
     * then the backup is scheduled again.
     */
    suspend fun freeUpSpace(
        context: Context,
        localIds: List<String>?,
        deleter: Deleter,
    ): FreeUpResult {
        val engine = engine(context) ?: throw IllegalStateException("engine not available")
        try {
            return runs.preempt { engine.freeUpSpace(localIds, deleter) }
        } finally {
            // The preempted SyncWorker may still be RUNNING: append after it rather than rely on its follow-up.
            Scheduling.requestSync(context, engine, appendIfRunning = true)
        }
    }

    /** The notification's Pause: pauses the engine and stops the run in progress. */
    suspend fun pauseFromNotification(context: Context) {
        val engine = engine(context) ?: return
        engine.pause(PauseReason.User)
        runs.cancelRuns()
    }

    /** A new default network: LAN-first endpoints again, any certificate pause cleared, and a sync. */
    suspend fun onNetworkChanged(context: Context) {
        val engine = engine(context) ?: return
        engine.onNetworkChanged()
        Scheduling.requestSync(context, engine)
    }

    /** After setSettings: the sync constraints (Wi-Fi only, charging) follow the new settings. */
    suspend fun onSettingsChanged(context: Context) {
        val engine = engine(context) ?: return
        Scheduling.requestSync(context, engine, replace = true)
    }
}

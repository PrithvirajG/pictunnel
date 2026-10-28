package io.github.prithvirajg.pictunnel.engine.sched

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import io.github.prithvirajg.pictunnel.engine.core.MediaAccess
import io.github.prithvirajg.pictunnel.engine.core.RemainingWork
import io.github.prithvirajg.pictunnel.engine.core.RunBudget
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Hash, check and upload (M§5), as unique work with [Scheduling.SYNC]. When
 * there is work it promotes itself to a `dataSync` foreground service with a
 * progress notification; if Android refuses (background start limits), it
 * runs within WorkManager's 10 minute window instead. WorkManager stopping the
 * worker cancels the run cooperatively; every row is resumable (R1).
 */
class SyncWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val engine = EngineRuntime.engine(applicationContext) ?: return Result.success()
        // No media permission: nothing can be read, and failing reads must not burn attempts.
        if (engine.mediaAccess() == MediaAccess.None) return Result.success()

        val remaining = engine.remainingWork()
        val foreground = remaining.count > 0 && promote(remaining)
        val budget = RunBudget(maxDurationMs = if (foreground) FOREGROUND_BUDGET_MS else BACKGROUND_BUDGET_MS)
        val report =
            coroutineScope {
                val ticker =
                    if (foreground) {
                        launch {
                            while (isActive) {
                                delay(NOTIFICATION_REFRESH_MS)
                                promote(engine.remainingWork())
                            }
                        }
                    } else {
                        null
                    }
                try {
                    EngineRuntime.runs.run(engine, budget)
                } finally {
                    ticker?.cancel()
                }
            } ?: return preempted(engine)
        Scheduling.afterRun(applicationContext, engine, report, fromWorker = true)
        return Result.success()
    }

    /**
     * Free-up space or Pause stopped the run. A sync asked for meanwhile (free-up
     * asks for one when it ends) must not be lost: it is appended after this worker.
     */
    private suspend fun preempted(engine: io.github.prithvirajg.pictunnel.engine.core.BackupEngine): Result {
        if (EngineRuntime.runs.followUp.getAndSet(false)) {
            Scheduling.requestSync(applicationContext, engine, fromWorker = true)
        }
        return Result.success()
    }

    private suspend fun promote(remaining: RemainingWork): Boolean =
        try {
            setForeground(UploadNotifications.foregroundInfo(applicationContext, remaining))
            true
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // ForegroundServiceStartNotAllowedException and friends: stay a regular worker.
            false
        }

    override suspend fun getForegroundInfo(): ForegroundInfo {
        val engine = EngineRuntime.engine(applicationContext)
        return UploadNotifications.foregroundInfo(applicationContext, engine?.remainingWork() ?: RemainingWork(0, 0))
    }

    companion object {
        /** Under WorkManager's 10 minute limit for regular workers. */
        const val BACKGROUND_BUDGET_MS = 9 * 60 * 1000L

        /** In the foreground service; the next run continues after this. */
        const val FOREGROUND_BUDGET_MS = 60 * 60 * 1000L

        const val NOTIFICATION_REFRESH_MS = 5_000L
    }
}

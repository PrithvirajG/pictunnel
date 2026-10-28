package io.github.prithvirajg.pictunnel.engine.sched

import android.content.Context
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.WorkerParameters
import io.github.prithvirajg.pictunnel.engine.core.MediaAccess

/**
 * Picks up new and changed media (MediaStore content trigger, 6 h period) and
 * asks for a sync when it found work. A scan that lands while a run holds the
 * engine is handed to that run.
 */
class ScanWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        // A content trigger fires once: re-arm it after this run, whatever happens below.
        if (Scheduling.TAG_TRIGGER in tags) Scheduling.armContentTrigger(applicationContext, ExistingWorkPolicy.APPEND_OR_REPLACE)
        val engine = EngineRuntime.engine(applicationContext) ?: return Result.success()
        if (engine.mediaAccess() == MediaAccess.None) return Result.success()
        val found = engine.scanNow()
        if (found == null) {
            // Handed to the running sync, which rescans before its next pass and follows up.
            EngineRuntime.runs.followUp.set(true)
            return Result.success()
        }
        if (found > 0 || engine.remainingWork().count > 0) Scheduling.requestSync(applicationContext, engine)
        return Result.success()
    }
}

package io.github.prithvirajg.pictunnel.engine.sched

import android.content.Context
import android.content.Intent
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkInfo
import androidx.work.WorkManager
import io.github.prithvirajg.pictunnel.engine.core.BackupEngine
import io.github.prithvirajg.pictunnel.engine.core.EngineSettings
import io.github.prithvirajg.pictunnel.engine.core.PauseState
import io.github.prithvirajg.pictunnel.engine.core.Pipeline
import io.github.prithvirajg.pictunnel.engine.core.RunReport
import io.github.prithvirajg.pictunnel.engine.core.StopReason
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.time.Duration
import java.util.concurrent.TimeUnit

/**
 * Background scheduling (M§5):
 * - [SyncWorker] is unique work: one pipeline at a time. Its constraints follow
 *   the settings (unmetered network when Wi-Fi only, charging when asked).
 * - [ScanWorker] runs on MediaStore content changes (`setTriggerContentUris`)
 *   and every 6 h, and asks for a sync when it found work.
 * - After each run, [afterRun] schedules the next one from the [RunReport].
 */
object Scheduling {
    const val SYNC = "pictunnel.sync"
    const val SCAN_PERIODIC = "pictunnel.scan.periodic"
    const val SCAN_TRIGGER = "pictunnel.scan.trigger"
    const val TAG_TRIGGER = "pictunnel.scan.trigger"

    /** Out of budget with work left: the next run starts soon. */
    const val BUDGET_FOLLOW_UP_MS = 5_000L

    /** No endpoint reachable although Android has a network; a network change also triggers a sync. */
    const val OFFLINE_RETRY_MS = 15 * 60 * 1000L

    const val SCAN_PERIOD_HOURS = 6L

    fun constraints(s: EngineSettings): Constraints =
        Constraints
            .Builder()
            .setRequiredNetworkType(if (s.wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED)
            .setRequiresCharging(s.chargingOnly)
            .build()

    /**
     * When the next sync should start after [report], or null to leave it to
     * the content trigger, the 6 h scan, the network monitor or the user. Every
     * wait is capped (R10): a clock that jumps cannot strand the backup.
     */
    fun nextSyncDelayMs(
        report: RunReport,
        pause: PauseState?,
        nowMs: Long,
    ): Long? =
        when (report.stop) {
            StopReason.Budget -> BUDGET_FOLLOW_UP_MS
            StopReason.Idle -> report.nextAttemptAtMs?.let { (it - nowMs).coerceIn(0, Pipeline.MAX_WAIT_MS) }
            StopReason.Offline -> OFFLINE_RETRY_MS
            StopReason.Paused, StopReason.ServerUntrusted -> pause?.untilMs?.let { (it - nowMs).coerceIn(0, Pipeline.MAX_PAUSE_MS) }
            StopReason.NeedsRepair -> null
        }

    /** Schedules the next sync after a run ([fromWorker]: called by the running SyncWorker itself). */
    suspend fun afterRun(
        context: Context,
        engine: BackupEngine,
        report: RunReport,
        fromWorker: Boolean,
    ) {
        var delay = nextSyncDelayMs(report, engine.pauseState(), System.currentTimeMillis())
        // New media arrived during the run: look again right away (unless the run cannot proceed).
        if (EngineRuntime.runs.followUp.getAndSet(false) && (report.stop == StopReason.Idle || report.stop == StopReason.Budget)) {
            delay = 0
        }
        if (delay != null) requestSync(context, engine, delay, fromWorker = fromWorker)
    }

    /**
     * Asks for a sync in [delayMs]. Only one pipeline runs at a time:
     * - from the running worker itself, the request is appended after it;
     * - while a sync runs, the running one is told to follow up when it ends;
     * - a pending sync that starts no later is kept (unless [replace], used when
     *   the constraints changed); otherwise it is replaced.
     */
    suspend fun requestSync(
        context: Context,
        engine: BackupEngine,
        delayMs: Long = 0,
        fromWorker: Boolean = false,
        replace: Boolean = false,
    ) {
        val wm = WorkManager.getInstance(context)
        val request = syncRequest(engine.getSettings(), delayMs)
        if (fromWorker) {
            wm.enqueueUniqueWork(SYNC, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
            return
        }
        val infos = withContext(Dispatchers.IO) { wm.getWorkInfosForUniqueWork(SYNC).get() }
        if (infos.any { it.state == WorkInfo.State.RUNNING }) {
            EngineRuntime.runs.followUp.set(true)
            return
        }
        val pending = infos.filter { it.state == WorkInfo.State.ENQUEUED || it.state == WorkInfo.State.BLOCKED }
        val due = System.currentTimeMillis() + delayMs
        if (!replace && pending.isNotEmpty() && pending.all { it.nextScheduleTimeMillis <= due }) return
        wm.enqueueUniqueWork(SYNC, ExistingWorkPolicy.REPLACE, request)
    }

    private fun syncRequest(
        s: EngineSettings,
        delayMs: Long,
    ): OneTimeWorkRequest =
        OneTimeWorkRequestBuilder<SyncWorker>()
            .setConstraints(constraints(s))
            .setInitialDelay(delayMs.coerceAtLeast(0), TimeUnit.MILLISECONDS)
            .build()

    /** The 6 h scan and the MediaStore content trigger; existing schedules are kept. */
    fun ensure(context: Context) {
        val wm = WorkManager.getInstance(context)
        wm.enqueueUniquePeriodicWork(
            SCAN_PERIODIC,
            ExistingPeriodicWorkPolicy.KEEP,
            PeriodicWorkRequestBuilder<ScanWorker>(SCAN_PERIOD_HOURS, TimeUnit.HOURS).build(),
        )
        armContentTrigger(context, ExistingWorkPolicy.KEEP)
    }

    /**
     * A content-URI trigger fires once; the triggered [ScanWorker] re-arms it
     * (appended after itself, since it is still running).
     */
    fun armContentTrigger(
        context: Context,
        policy: ExistingWorkPolicy,
    ) {
        val constraints =
            Constraints
                .Builder()
                .addContentUriTrigger(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true)
                .addContentUriTrigger(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true)
                .setTriggerContentUpdateDelay(Duration.ofSeconds(5))
                .setTriggerContentMaxDelay(Duration.ofMinutes(1))
                .build()
        val request =
            OneTimeWorkRequestBuilder<ScanWorker>()
                .setConstraints(constraints)
                .addTag(TAG_TRIGGER)
                .build()
        WorkManager.getInstance(context).enqueueUniqueWork(SCAN_TRIGGER, policy, request)
    }

    /**
     * "Back up now" from the app (in the foreground): uploads run in the
     * foreground service. If Android refuses to start it, a sync is requested.
     */
    suspend fun runNow(
        context: Context,
        engine: BackupEngine,
    ) {
        try {
            ContextCompat.startForegroundService(context, Intent(context, UploadForegroundService::class.java))
        } catch (e: IllegalStateException) {
            // ForegroundServiceStartNotAllowedException (API 31+) is an IllegalStateException.
            requestSync(context, engine)
        }
    }

    /** Unpair: no more background work. */
    fun cancelAll(context: Context) {
        val wm = WorkManager.getInstance(context)
        listOf(SYNC, SCAN_PERIODIC, SCAN_TRIGGER).forEach { wm.cancelUniqueWork(it) }
        EngineRuntime.runs.cancelRuns()
    }
}

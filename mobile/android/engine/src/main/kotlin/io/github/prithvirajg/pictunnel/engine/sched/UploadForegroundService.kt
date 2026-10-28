package io.github.prithvirajg.pictunnel.engine.sched

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.IBinder
import android.text.format.Formatter
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.work.ForegroundInfo
import io.github.prithvirajg.pictunnel.engine.core.RemainingWork
import io.github.prithvirajg.pictunnel.engine.core.RunBudget
import io.github.prithvirajg.pictunnel.engine.core.RunReport
import io.github.prithvirajg.pictunnel.engine.core.StopReason
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The upload notification (M§4.6): remaining count and bytes, with Pause. */
object UploadNotifications {
    const val CHANNEL = "pictunnel.uploads"

    /** The foreground service's notification. */
    const val SERVICE_ID = 4201

    /** SyncWorker's notification (WorkManager's own foreground service). */
    const val WORKER_ID = 4202

    fun ensureChannel(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Backup", NotificationManager.IMPORTANCE_LOW))
        }
    }

    fun build(
        context: Context,
        remaining: RemainingWork,
    ): Notification {
        ensureChannel(context)
        val pause =
            PendingIntent.getBroadcast(
                context,
                0,
                Intent(context, PauseReceiver::class.java),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        val text =
            if (remaining.count > 0) {
                "${remaining.count} left · ${Formatter.formatShortFileSize(context, remaining.bytes)}"
            } else {
                "Checking for new photos"
            }
        return NotificationCompat
            .Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("Backing up")
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .addAction(0, "Pause", pause)
            .build()
    }

    fun foregroundInfo(
        context: Context,
        remaining: RemainingWork,
    ): ForegroundInfo = ForegroundInfo(WORKER_ID, build(context, remaining), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
}

/** The notification's Pause action: pauses the engine and stops the run in progress. */
class PauseReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        val pending = goAsync()
        CoroutineScope(Dispatchers.Default).launch {
            try {
                EngineRuntime.pauseFromNotification(context.applicationContext)
            } finally {
                pending.finish()
            }
        }
    }
}

/**
 * The `dataSync` foreground service for user-started backups ("Back up now",
 * M§4.6): runs the pipeline until the queue is empty or the run stops, keeps
 * the notification current, then schedules the next sync from the last report
 * and stops itself. Runs go through [EngineRuntime.runs], so Pause and free-up
 * space stop them cooperatively.
 */
class UploadForegroundService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var job: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int,
    ): Int {
        ServiceCompat.startForeground(
            this,
            UploadNotifications.SERVICE_ID,
            UploadNotifications.build(this, RemainingWork(0, 0)),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
        )
        if (job?.isActive != true) job = scope.launch { runUntilDone() }
        return START_NOT_STICKY
    }

    private suspend fun runUntilDone() {
        try {
            val engine = EngineRuntime.engine(applicationContext) ?: return
            var last: RunReport? = null
            coroutineScope {
                val ticker =
                    launch {
                        val nm = getSystemService(android.app.NotificationManager::class.java)
                        while (isActive) {
                            nm.notify(UploadNotifications.SERVICE_ID, UploadNotifications.build(this@UploadForegroundService, engine.remainingWork()))
                            delay(SyncWorker.NOTIFICATION_REFRESH_MS)
                        }
                    }
                try {
                    for (i in 0 until MAX_RUNS) {
                        val r = EngineRuntime.runs.run(engine, RunBudget(maxDurationMs = SyncWorker.FOREGROUND_BUDGET_MS)) ?: break
                        last = r
                        if (r.stop != StopReason.Budget) break
                    }
                } finally {
                    ticker.cancel()
                }
            }
            last?.let { Scheduling.afterRun(applicationContext, engine, it, fromWorker = false) }
        } finally {
            withContext(Dispatchers.Main) {
                ServiceCompat.stopForeground(this@UploadForegroundService, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
    }

    /** API 35+: the daily `dataSync` allowance ran out. Stop now and hand the rest to WorkManager. */
    override fun onTimeout(
        startId: Int,
        fgsType: Int,
    ) {
        EngineRuntime.runs.cancelRuns()
        job?.cancel()
        val app = applicationContext
        CoroutineScope(Dispatchers.Default).launch {
            EngineRuntime.engine(app)?.let { runCatching { Scheduling.requestSync(app, it, appendIfRunning = true) } }
        }
        stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private companion object {
        const val MAX_RUNS = 100
    }
}

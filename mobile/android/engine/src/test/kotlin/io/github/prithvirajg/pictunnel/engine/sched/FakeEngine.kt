package io.github.prithvirajg.pictunnel.engine.sched

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
import kotlinx.coroutines.CompletableDeferred
import java.util.Collections

fun report(
    stop: StopReason,
    next: Long? = null,
) = RunReport(0, 0, 0, 0, 0, 0, stop, next)

/** Records calls in order; [onRun] decides what each run does. */
class FakeEngine : BackupEngine {
    val calls: MutableList<String> = Collections.synchronizedList(mutableListOf())
    var onRun: suspend (RunBudget) -> RunReport = { report(StopReason.Idle) }
    var scanResult: Int? = 0
    var remaining = RemainingWork(0, 0)
    var pause: PauseState? = null
    var settings = EngineSettings()
    var access = MediaAccess.Full
    val runStarted = CompletableDeferred<Unit>()

    override suspend fun runOnce(budget: RunBudget): RunReport {
        calls += "run"
        runStarted.complete(Unit)
        try {
            return onRun(budget).also { calls += "run-end" }
        } catch (e: kotlinx.coroutines.CancellationException) {
            calls += "run-cancelled"
            throw e
        }
    }

    override suspend fun scanNow(): Int? {
        calls += "scan"
        return scanResult
    }

    override suspend fun freeUpSpace(
        localIds: List<String>?,
        deleter: Deleter,
    ): FreeUpResult {
        calls += "free-up"
        return FreeUpResult(deleter.delete(localIds ?: emptyList()).size, 0, emptyList())
    }

    override suspend fun pause(reason: PauseReason) {
        calls += "pause:$reason"
        pause = PauseState(reason, null)
    }

    override suspend fun pauseState(): PauseState? = pause

    override suspend fun remainingWork(): RemainingWork = remaining

    override suspend fun onNetworkChanged() {
        calls += "network"
    }

    override suspend fun getSettings(): EngineSettings = settings

    override fun mediaAccess(): MediaAccess = access
}

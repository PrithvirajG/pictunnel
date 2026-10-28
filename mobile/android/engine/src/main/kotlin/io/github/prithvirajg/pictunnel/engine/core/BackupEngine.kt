package io.github.prithvirajg.pictunnel.engine.core

import io.github.prithvirajg.pictunnel.engine.model.PauseReason

/** Items still to back up (primary items) and the bytes of every component left to send. */
data class RemainingWork(
    val count: Int,
    val bytes: Long,
)

/**
 * What the background layer (workers, the foreground service, the network
 * monitor) needs from the engine. [EngineController] implements it; tests fake it.
 */
interface BackupEngine {
    suspend fun runOnce(budget: RunBudget): RunReport

    /**
     * Scans now when no run is in progress and returns how many items became
     * new work. When a run holds the engine, the scan is handed to that run
     * (it rescans before its next pass) and this returns null.
     */
    suspend fun scanNow(): Int?

    suspend fun freeUpSpace(
        localIds: List<String>?,
        deleter: Deleter,
    ): FreeUpResult

    suspend fun pause(reason: PauseReason)

    suspend fun pauseState(): PauseState?

    suspend fun remainingWork(): RemainingWork

    /** Back to the LAN-first endpoint order (R9); a certificate pause is cleared (captive portals). */
    suspend fun onNetworkChanged()

    suspend fun getSettings(): EngineSettings

    /** full | partial | none, for the bridge's `BackupStatus` (Task 10). */
    fun mediaAccess(): MediaAccess
}

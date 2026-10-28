package io.github.prithvirajg.pictunnel.engine.bridge

import androidx.room.withTransaction
import io.github.prithvirajg.pictunnel.engine.core.SettingsRepo
import io.github.prithvirajg.pictunnel.engine.sched.RunCoordinator
import io.github.prithvirajg.pictunnel.engine.store.EngineDb
import kotlinx.coroutines.CancellationException

/**
 * The engine's local state around pairing and unpairing (M§3): which server
 * the index belongs to, and wiping it. Index changes run under
 * [RunCoordinator.preempt], so no backup run works on an index being cleared.
 * Cached hashes are kept: they describe the phone's files, not the server.
 */
class Account(
    private val db: EngineDb,
    private val settings: SettingsRepo,
    private val runs: RunCoordinator,
) {
    /**
     * Credentials for [serverId] were just stored. A different server than
     * last time starts a fresh index (asset ids and states belong to the old
     * one). The server id is recorded before the name lookup, so a run that
     * starts meanwhile already works for the new server. Returns the name.
     */
    suspend fun adoptServer(
        serverId: String,
        fetchName: suspend () -> String?,
    ): String {
        val previous = settings.pairedServerId()
        val cached = settings.serverName()?.takeIf { previous == serverId }
        if (previous != serverId) {
            runs.preempt {
                if (previous != null) clearIndex()
                settings.setServer(serverId, cached ?: DEFAULT_NAME)
            }
        }
        val fetched =
            try {
                fetchName()
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                null
            }
        val name = fetched ?: cached ?: DEFAULT_NAME
        settings.setServer(serverId, name)
        return name
    }

    /** Unpair: the index, scan cursors, activity log, pause and server identity go; cached hashes stay. */
    suspend fun forget() {
        runs.preempt {
            clearIndex()
            settings.clearServer()
        }
    }

    private suspend fun clearIndex() {
        db.withTransaction {
            db.items().clear()
            db.scanState().clear()
            db.activity().clear()
        }
        settings.clearPause()
    }

    companion object {
        const val DEFAULT_NAME = "PicTunnel"
    }
}

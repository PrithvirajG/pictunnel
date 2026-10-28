package io.github.prithvirajg.pictunnel.engine.core

import io.github.prithvirajg.pictunnel.engine.model.PauseReason
import io.github.prithvirajg.pictunnel.engine.store.SettingEntity
import io.github.prithvirajg.pictunnel.engine.store.SettingsDao

/** Mirrors the Pigeon `EngineSettings`, plus the upload concurrency (R6: default 2, at most 4). */
data class EngineSettings(
    val wifiOnly: Boolean = false,
    val chargingOnly: Boolean = false,
    val includeVideos: Boolean = true,
    val keepUneditedOriginals: Boolean = false,
    val allAlbums: Boolean = true,
    val albumIds: List<String> = emptyList(),
    val uploadConcurrency: Int = DEFAULT_CONCURRENCY,
) {
    companion object {
        const val DEFAULT_CONCURRENCY = 2
        const val MAX_CONCURRENCY = 4
    }
}

/**
 * A run-level pause. [untilMs] (wall clock) lets a server-caused pause be
 * retried later; null waits for [SettingsRepo.clearPause].
 */
data class PauseState(
    val reason: PauseReason,
    val untilMs: Long?,
)

/** Engine settings and run state, as string pairs in the `settings` table. */
class SettingsRepo(
    private val dao: SettingsDao,
) {
    suspend fun get(): EngineSettings {
        val m = dao.all().associate { it.key to it.value }
        val d = EngineSettings()
        return EngineSettings(
            wifiOnly = m[WIFI_ONLY]?.toBooleanStrictOrNull() ?: d.wifiOnly,
            chargingOnly = m[CHARGING_ONLY]?.toBooleanStrictOrNull() ?: d.chargingOnly,
            includeVideos = m[INCLUDE_VIDEOS]?.toBooleanStrictOrNull() ?: d.includeVideos,
            keepUneditedOriginals = m[KEEP_UNEDITED]?.toBooleanStrictOrNull() ?: d.keepUneditedOriginals,
            allAlbums = m[ALL_ALBUMS]?.toBooleanStrictOrNull() ?: d.allAlbums,
            albumIds = m[ALBUM_IDS]?.split(SEP)?.filter { it.isNotEmpty() } ?: d.albumIds,
            uploadConcurrency =
                (m[CONCURRENCY]?.toIntOrNull() ?: d.uploadConcurrency).coerceIn(1, EngineSettings.MAX_CONCURRENCY),
        )
    }

    suspend fun set(s: EngineSettings) {
        put(WIFI_ONLY, s.wifiOnly.toString())
        put(CHARGING_ONLY, s.chargingOnly.toString())
        put(INCLUDE_VIDEOS, s.includeVideos.toString())
        put(KEEP_UNEDITED, s.keepUneditedOriginals.toString())
        put(ALL_ALBUMS, s.allAlbums.toString())
        put(ALBUM_IDS, s.albumIds.joinToString(SEP))
        put(CONCURRENCY, s.uploadConcurrency.coerceIn(1, EngineSettings.MAX_CONCURRENCY).toString())
    }

    suspend fun pause(): PauseState? {
        val name = dao.get(PAUSE_REASON) ?: return null
        val reason = PauseReason.entries.firstOrNull { it.name == name } ?: return null
        return PauseState(reason, dao.get(PAUSE_UNTIL)?.toLongOrNull())
    }

    /** Reason and expiry are written in one transaction (an empty expiry means none). */
    suspend fun setPause(p: PauseState) {
        dao.putAll(listOf(SettingEntity(PAUSE_REASON, p.reason.name), SettingEntity(PAUSE_UNTIL, p.untilMs?.toString() ?: "")))
    }

    suspend fun clearPause() {
        dao.removeAll(listOf(PAUSE_REASON, PAUSE_UNTIL))
    }

    suspend fun lastRunAtMs(): Long? = dao.get(LAST_RUN_AT)?.toLongOrNull()

    suspend fun setLastRunAtMs(ms: Long) = put(LAST_RUN_AT, ms.toString())

    /** The server this phone is paired with (cleared on unpair); a different one on pairing starts a fresh index. */
    suspend fun pairedServerId(): String? = dao.get(SERVER_ID)

    /** The paired server's display name, cached so `serverInfo` works offline. */
    suspend fun serverName(): String? = dao.get(SERVER_NAME)

    suspend fun setServer(
        serverId: String,
        name: String,
    ) {
        dao.putAll(listOf(SettingEntity(SERVER_ID, serverId), SettingEntity(SERVER_NAME, name)))
    }

    /** Unpair: forgets the server identity, its name, the pause and the last run. */
    suspend fun clearServer() {
        dao.removeAll(listOf(SERVER_ID, SERVER_NAME, PAUSE_REASON, PAUSE_UNTIL, LAST_RUN_AT))
    }

    private suspend fun put(
        k: String,
        v: String,
    ) = dao.put(SettingEntity(k, v))

    private companion object {
        const val SEP = "\n"
        const val WIFI_ONLY = "wifi_only"
        const val CHARGING_ONLY = "charging_only"
        const val INCLUDE_VIDEOS = "include_videos"
        const val KEEP_UNEDITED = "keep_unedited_originals"
        const val ALL_ALBUMS = "all_albums"
        const val ALBUM_IDS = "album_ids"
        const val CONCURRENCY = "upload_concurrency"
        const val PAUSE_REASON = "pause_reason"
        const val PAUSE_UNTIL = "pause_until_ms"
        const val LAST_RUN_AT = "last_run_at_ms"
        const val SERVER_ID = "server_id"
        const val SERVER_NAME = "server_name"
    }
}

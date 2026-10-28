package io.github.prithvirajg.pictunnel.engine.bridge

import io.github.prithvirajg.pictunnel.engine.model.ItemKind
import io.github.prithvirajg.pictunnel.engine.platform.Album
import io.github.prithvirajg.pictunnel.engine.store.ActivityEntity
import io.github.prithvirajg.pictunnel.engine.store.ItemEntity
import io.github.prithvirajg.pictunnel.engine.core.AttentionItem as CoreAttention
import io.github.prithvirajg.pictunnel.engine.core.BackupStatus as CoreStatus
import io.github.prithvirajg.pictunnel.engine.core.EngineSettings as CoreSettings
import io.github.prithvirajg.pictunnel.engine.core.FreeUpResult as CoreFreeUp
import io.github.prithvirajg.pictunnel.engine.core.MediaAccess as CoreAccess
import io.github.prithvirajg.pictunnel.engine.core.PhoneItemPage as CorePage
import io.github.prithvirajg.pictunnel.engine.core.UploadProgress as CoreUpload
import io.github.prithvirajg.pictunnel.engine.model.ItemState as CoreState
import io.github.prithvirajg.pictunnel.engine.model.PauseReason as CorePause

// Engine types <-> the generated Pigeon types (M§3). Every enum maps explicitly,
// so a new value on either side fails the build instead of the bridge.

internal fun CorePause.toPigeon(): PauseReason =
    when (this) {
        CorePause.User -> PauseReason.USER
        CorePause.WifiRequired -> PauseReason.WIFI_REQUIRED
        CorePause.ChargingRequired -> PauseReason.CHARGING_REQUIRED
        CorePause.ServerFull -> PauseReason.SERVER_FULL
        CorePause.Quota -> PauseReason.QUOTA
        CorePause.ClientTooOld -> PauseReason.CLIENT_TOO_OLD
        CorePause.Permission -> PauseReason.PERMISSION
        CorePause.ServerCertificateChanged -> PauseReason.SERVER_CERTIFICATE_CHANGED
    }

internal fun PauseReason.toCore(): CorePause =
    when (this) {
        PauseReason.USER -> CorePause.User
        PauseReason.WIFI_REQUIRED -> CorePause.WifiRequired
        PauseReason.CHARGING_REQUIRED -> CorePause.ChargingRequired
        PauseReason.SERVER_FULL -> CorePause.ServerFull
        PauseReason.QUOTA -> CorePause.Quota
        PauseReason.CLIENT_TOO_OLD -> CorePause.ClientTooOld
        PauseReason.PERMISSION -> CorePause.Permission
        PauseReason.SERVER_CERTIFICATE_CHANGED -> CorePause.ServerCertificateChanged
    }

internal fun CoreState.toPigeon(): ItemState =
    when (this) {
        CoreState.Discovered -> ItemState.DISCOVERED
        CoreState.Hashed -> ItemState.HASHED
        CoreState.Queued -> ItemState.QUEUED
        CoreState.Uploading -> ItemState.UPLOADING
        CoreState.Verifying -> ItemState.VERIFYING
        CoreState.BackedUp -> ItemState.BACKED_UP
        CoreState.Skipped -> ItemState.SKIPPED
        CoreState.Freed -> ItemState.FREED
        CoreState.NeedsAttention -> ItemState.NEEDS_ATTENTION
        CoreState.Paused -> ItemState.PAUSED
    }

internal fun CoreAccess.toPigeon(): MediaAccess =
    when (this) {
        CoreAccess.Full -> MediaAccess.FULL
        CoreAccess.Partial -> MediaAccess.PARTIAL
        CoreAccess.None -> MediaAccess.NONE
    }

internal fun CoreUpload.toPigeon() = UploadProgress(localId, filename, sentBytes, totalBytes, bytesPerSecond)

internal fun CoreStatus.toPigeon() =
    BackupStatus(
        backedUp = backedUp.toLong(),
        total = total.toLong(),
        queued = queued.toLong(),
        uploading = uploading?.toPigeon(),
        needsAttention = needsAttention.toLong(),
        skipped = skipped.toLong(),
        freeableBytes = freeableBytes,
        paused = paused,
        pauseReason = pauseReason?.toPigeon(),
        lastRunAtMs = lastRunAtMs,
        preparing = preparing.toLong(),
        mediaAccess = mediaAccess.toPigeon(),
    )

internal fun CoreSettings.toPigeon() = EngineSettings(wifiOnly, chargingOnly, includeVideos, keepUneditedOriginals, allAlbums, albumIds)

/** Pigeon settings onto [base], keeping engine-only fields such as the upload concurrency. */
internal fun EngineSettings.toCore(base: CoreSettings) =
    base.copy(
        wifiOnly = wifiOnly,
        chargingOnly = chargingOnly,
        includeVideos = includeVideos,
        keepUneditedOriginals = keepUneditedOriginals,
        allAlbums = allAlbums,
        albumIds = albumIds,
    )

internal fun ItemEntity.toPigeon() =
    PhoneItem(
        localId = localId,
        filename = filename,
        sha256 = sha256,
        takenAtMs = takenAtMs,
        mime = mime,
        size = size,
        width = width?.toLong(),
        height = height?.toLong(),
        durationMs = durationMs,
        state = state.toPigeon(),
        assetId = assetId,
        isLivePhoto = kind == ItemKind.LIVE_PHOTO,
    )

internal fun CorePage.toPigeon() = PhoneItemPage(items.map { it.toPigeon() }, nextKey)

internal fun CoreAttention.toPigeon() = AttentionItem(localId, filename, code, message, attempts.toLong(), sha256)

internal fun ActivityEntity.toPigeon() = ActivityEntry(atMs, kind, message, localId)

internal fun CoreFreeUp.toPigeon() = FreeUpResult(freedCount.toLong(), freedBytes, skipped.map { SkippedFree(it.localId, it.reason) })

internal fun Album.toPigeon() = AlbumInfo(id, name, count.toLong())

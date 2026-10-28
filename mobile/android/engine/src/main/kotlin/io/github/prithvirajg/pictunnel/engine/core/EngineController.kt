package io.github.prithvirajg.pictunnel.engine.core

import io.github.prithvirajg.pictunnel.engine.core.Pipeline.Companion.str
import io.github.prithvirajg.pictunnel.engine.decide.Action
import io.github.prithvirajg.pictunnel.engine.decide.Decide
import io.github.prithvirajg.pictunnel.engine.decide.Flow
import io.github.prithvirajg.pictunnel.engine.decide.Given
import io.github.prithvirajg.pictunnel.engine.decide.LastAction
import io.github.prithvirajg.pictunnel.engine.decide.ServerOutcome
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import io.github.prithvirajg.pictunnel.engine.model.PairRole
import io.github.prithvirajg.pictunnel.engine.model.PauseReason
import io.github.prithvirajg.pictunnel.engine.net.CheckItem
import io.github.prithvirajg.pictunnel.engine.net.Outcome
import io.github.prithvirajg.pictunnel.engine.net.ServerClient
import io.github.prithvirajg.pictunnel.engine.store.ActivityEntity
import io.github.prithvirajg.pictunnel.engine.store.EngineDb
import io.github.prithvirajg.pictunnel.engine.store.ItemEntity
import kotlinx.coroutines.CancellationException
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/**
 * The Android backup engine (M§4): one pipeline run at a time, plus the
 * queries and user actions the bridge exposes (M§3). Platform pieces come in
 * through [scanner], [media] and the [Deleter] passed to [freeUpSpace].
 */
class EngineController(
    private val db: EngineDb,
    private val scanner: Scanner,
    private val media: MediaSource,
    private val client: ServerClient,
    private val settings: SettingsRepo,
    private val clock: Clock,
    private val events: EngineEvents,
    private val config: EngineConfig = EngineConfig(),
) : BackupEngine {
    private val items = db.items()
    private val log = ActivityLog(db.activity(), clock)
    private val reporter = StatusReporter(items, settings, clock, events, scanner::access)
    private val pipeline = Pipeline(db, media, client, settings, clock, events, log, reporter, config)
    private val runLock = Mutex()

    /** A scan asked for while a run held the engine; the run performs it before its next pass. */
    private val rescanRequested = AtomicBoolean(false)

    /**
     * Scan → hash → check → upload until nothing is due, the [budget] runs out,
     * or the run must stop (offline, paused, server untrusted, needs repair).
     * Passes repeat while they make progress, so an item can go from new to
     * backed up in one run and a Live Photo video follows its still (H4).
     */
    override suspend fun runOnce(budget: RunBudget): RunReport =
        runLock.withLock {
            val ctx = RunCtx(budget, clock)
            val pause = settings.pause()
            if (pause != null) {
                val until = pause.untilMs
                val now = clock.nowMs()
                // An expiry beyond the longest pause we set means the clock jumped back: treat it as expired (R10).
                if (until == null || (now < until && until <= now + Pipeline.MAX_PAUSE_MS)) {
                    ctx.stop(StopReason.Paused)
                    return@withLock report(ctx)
                }
                // A server-caused pause has expired: try again.
                settings.clearPause()
            }
            rescanRequested.set(false)
            scanSafely(ctx)
            reporter.publish()
            val concurrency = settings.get().uploadConcurrency
            var settled = false
            for (pass in 0 until config.maxPasses) {
                // New media arrived while this run held the engine (ScanWorker): pick it up now.
                if (rescanRequested.getAndSet(false)) scanSafely(ctx)
                val before = ctx.transitions.get()
                val deferredBefore = ctx.deferred.get()
                pipeline.hashPhase(ctx)
                if (ctx.stopped) break
                pipeline.checkPhase(ctx)
                if (ctx.stopped) break
                pipeline.uploadPhase(ctx, concurrency)
                if (ctx.stopped) break
                if (ctx.transitions.get() == before && ctx.deferred.get() == deferredBefore) {
                    settled = true
                    break
                }
            }
            // Out of passes with work still moving: report it so the scheduler runs again soon.
            if (!settled) ctx.stop(StopReason.Budget)
            settings.setLastRunAtMs(clock.nowMs())
            reporter.publish(force = true)
            report(ctx)
        }

    private suspend fun scanSafely(ctx: RunCtx) {
        try {
            pipeline.scan(ctx, scanner)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Keep going with the index we have; the next scan tries again.
            log.add(ActivityLog.ERROR, "Scanning the library failed: ${e.message}")
        }
    }

    override suspend fun scanNow(): Int? {
        if (!runLock.tryLock()) {
            rescanRequested.set(true)
            return null
        }
        try {
            val ctx = RunCtx(RunBudget(), clock)
            pipeline.scan(ctx, scanner)
            reporter.publish(force = true)
            return ctx.transitions.get()
        } finally {
            runLock.unlock()
        }
    }

    override fun mediaAccess(): MediaAccess = scanner.access()

    override suspend fun pauseState(): PauseState? = settings.pause()

    override suspend fun remainingWork(): RemainingWork = items.remaining(ACTIVE_STATES).let { RemainingWork(it.count, it.bytes) }

    private suspend fun report(ctx: RunCtx) =
        RunReport(
            scanned = ctx.scanned.get(),
            hashed = ctx.hashed.get(),
            checked = ctx.checked.get(),
            backedUp = ctx.backedUp.get(),
            skipped = ctx.skipped.get(),
            needsAttention = ctx.needsAttention.get(),
            stop = ctx.stop ?: StopReason.Idle,
            nextAttemptAtMs = nextAttempt(),
        )

    /** The earliest pending backoff; one beyond the backoff cap means the clock jumped back, so it is due now (R10). */
    private suspend fun nextAttempt(): Long? {
        val now = clock.nowMs()
        val next = items.nextAttemptAfter(ACTIVE_STATES, now) ?: return null
        return if (next > now + Pipeline.MAX_WAIT_MS) now else next
    }

    suspend fun status(): BackupStatus = reporter.snapshot()

    /** Pauses every run until [start]. */
    override suspend fun pause(reason: PauseReason) {
        settings.setPause(PauseState(reason, null))
        log.add(ActivityLog.PAUSED, "Backup paused (${reason.name})")
        reporter.publish(force = true)
    }

    /** Clears any pause, including one the server caused. The caller schedules the next run. */
    suspend fun start() {
        settings.clearPause()
        reporter.publish(force = true)
    }

    /**
     * Call on a network change: go back to the preferred, LAN-first endpoint
     * (R9). A certificate pause (every endpoint refused our pin) is cleared too:
     * it was most likely a captive portal on the old network.
     */
    override suspend fun onNetworkChanged() {
        client.onNetworkChanged()
        val p = settings.pause() ?: return
        if (p.reason == UNTRUSTED_PAUSE_REASON && p.untilMs != null) {
            settings.clearPause()
            log.add(ActivityLog.INFO, "Network changed: trying the server again")
            reporter.publish(force = true)
        }
    }

    override suspend fun getSettings(): EngineSettings = settings.get()

    /**
     * Saves the settings. A change of scope (include videos, album selection)
     * forgets the scan cursors of every volume, so items that already existed
     * and are now in scope are reported by the next scan and backed up.
     */
    suspend fun setSettings(s: EngineSettings) {
        val old = settings.get()
        settings.set(s)
        val scopeChanged =
            old.includeVideos != s.includeVideos || old.allAlbums != s.allAlbums || old.albumIds.toSet() != s.albumIds.toSet()
        if (scopeChanged) db.scanState().clear()
    }

    // ---- phone index, attention, activity -------------------------------------

    /**
     * The phone timeline: newest first by `(takenAtMs, localId)`; [afterKey] is
     * the exclusive `"<takenAtMs>|<localId>"` of the previous page's last item.
     */
    suspend fun listPhoneItems(
        afterKey: String?,
        limit: Int,
    ): PhoneItemPage {
        val n = limit.coerceIn(1, MAX_PAGE)
        var afterTakenAt: Long? = null
        var afterLocalId: String? = null
        if (afterKey != null) {
            val bar = afterKey.indexOf('|')
            require(bar > 0) { "afterKey must be <takenAtMs>|<localId>" }
            afterTakenAt = afterKey.substring(0, bar).toLong()
            afterLocalId = afterKey.substring(bar + 1)
        }
        val page = items.phonePage(afterTakenAt, afterLocalId, n)
        val next = if (page.size == n) page.last().let { "${it.takenAtMs}|${it.localId}" } else null
        return PhoneItemPage(page, next)
    }

    /**
     * Items that need the user: failed ones (Retry) and, for "Back up again"
     * (M§7), primary items skipped because their content was deleted from the
     * server. Only skipped items carry [AttentionItem.sha256].
     */
    suspend fun listAttention(): List<AttentionItem> {
        val failed =
            items.byState(listOf(ItemState.NeedsAttention), MAX_PAGE).map {
                val code = it.lastError ?: "unknown"
                AttentionItem(it.localId, it.filename, code, attentionMessage(code), it.attempts)
            }
        val skipped =
            items
                .byState(listOf(ItemState.Skipped), MAX_PAGE)
                .filter { it.pairRole == PairRole.PRIMARY && it.sha256 != null }
                .map {
                    AttentionItem(
                        localId = it.localId,
                        filename = it.filename,
                        code = TOMBSTONED,
                        message = "Deleted from the server earlier, so it is not backed up.",
                        attempts = it.attempts,
                        sha256 = it.sha256,
                    )
                }
        return failed + skipped
    }

    /** Puts needs-attention items back in the pipeline with a fresh attempt count. */
    suspend fun retry(localIds: List<String>) {
        for (id in localIds) {
            val it = items.get(id) ?: continue
            if (it.state != ItemState.NeedsAttention) continue
            val state =
                when {
                    it.uploadUrl != null -> ItemState.Uploading
                    it.sha256 != null -> ItemState.Hashed
                    else -> ItemState.Discovered
                }
            val next = it.copy(state = state, attempts = 0, nextAttemptAtMs = null, lastError = null)
            items.upsert(next)
            events.itemChanged(next)
        }
        reporter.publish(force = true)
    }

    suspend fun listActivity(limit: Int): List<ActivityEntity> = log.latest(limit)

    /**
     * "Back up again" for tombstoned content (P§7.7): removes the server's
     * tombstone, then sends the matching skipped items back to check. Returns
     * false when the server did not confirm (nothing changes locally).
     */
    suspend fun undoSkip(sha256: String): Boolean {
        val raw = client.deleteTombstone(sha256)
        // 204 removed it; 404 means there was none left to remove.
        if (raw.status != 204 && raw.status != 200 && raw.status != 404) return false
        for (it in items.bySha(sha256)) {
            if (it.state != ItemState.Skipped) continue
            val next = it.copy(state = ItemState.Hashed, attempts = 0, nextAttemptAtMs = null, lastError = null)
            items.upsert(next)
            events.itemChanged(next)
        }
        log.add(ActivityLog.INFO, "Backing up again content deleted from the server earlier")
        reporter.publish(force = true)
        return true
    }

    // ---- free up space (M§4.5, P§7.8) -------------------------------------------

    /**
     * Deletes local originals that are safely on the server. Candidates are
     * backed-up items ([localIds], or all when null). Immediately before the
     * delete request, each is re-checked with `confirm_on_disk` and its local
     * fingerprint compared; a Live Photo is freed only if both components pass.
     * [deleter] shows the OS dialog; only the ids it confirms become `Freed`,
     * cancelled ones stay `BackedUp`.
     */
    override suspend fun freeUpSpace(
        localIds: List<String>?,
        deleter: Deleter,
    ): FreeUpResult =
        runLock.withLock {
            val skipped = ArrayList<SkippedFree>()
            val roots =
                if (localIds == null) {
                    items.byState(listOf(ItemState.BackedUp), Int.MAX_VALUE).filter { it.pairRole == PairRole.PRIMARY }
                } else {
                    localIds.mapNotNull { id -> items.get(id) ?: null.also { skipped += SkippedFree(id, "unknown") } }
                }
            // Each group is a primary plus its paired video, decided together.
            val groups = ArrayList<List<ItemEntity>>()
            val seen = HashSet<String>()
            for (root in roots) {
                if (!seen.add(root.localId)) continue
                val partner = root.pairLocalId?.let { items.get(it) }
                if (partner != null) seen += partner.localId
                val group = listOfNotNull(root, partner)
                val notBackedUp = group.firstOrNull { it.state != ItemState.BackedUp || it.sha256 == null }
                if (notBackedUp != null) {
                    skipped += SkippedFree(root.localId, "not_backed_up")
                    continue
                }
                groups += group
            }

            val allowed = ArrayList<ItemEntity>()
            for (batch in batchGroups(groups)) {
                val flat = batch.flatten()
                val out = client.check(flat.map { CheckItem(it.sha256!!, it.size, it.localId) }, confirmOnDisk = true)
                val raw = out.raw()
                val results = ((raw.body as? JsonObject)?.get("results") as? JsonArray)
                var i = 0
                for (group in batch) {
                    val groupResults =
                        if (out is Outcome.Ok && results != null && results.size == flat.size) results.subList(i, i + group.size) else null
                    i += group.size
                    val changed = group.any { fingerprintChanged(it) }
                    val one =
                        when {
                            groupResults != null ->
                                ServerOutcome(raw.status, raw.headers, JsonObject(mapOf("results" to JsonArray(groupResults))), null)
                            out is Outcome.Fail -> raw
                            // A 200 whose results do not line up: no usable answer, so no delete.
                            else -> raw.copy(status = null)
                        }
                    val root = group.first()
                    val d =
                        Decide.decide(
                            Given(
                                Flow.FREE_UP_SPACE,
                                root.state.name,
                                LastAction.FREE_UP_SPACE_CHECK,
                                mapOf("kind" to root.kind, "fingerprint_changed" to changed),
                            ),
                            one,
                        )
                    if (d.action == Action.DELETE_LOCAL_ALLOWED) {
                        allowed += group
                        continue
                    }
                    val reason = denyReason(changed, groupResults, raw)
                    skipped += SkippedFree(root.localId, reason)
                    val target = d.nextState
                    if (target != null && target != ItemState.BackedUp) {
                        for (it in group) {
                            // Requeued: the server no longer proves this backup, so drop the asset and any session.
                            val cleared =
                                it.copy(
                                    state = target,
                                    assetId = null,
                                    uploadId = null,
                                    uploadUrl = null,
                                    uploadOffset = null,
                                    attempts = 0,
                                    nextAttemptAtMs = null,
                                )
                            val next = if (target == ItemState.Discovered) cleared.copy(sha256 = null) else cleared
                            items.upsert(next)
                            events.itemChanged(next)
                        }
                    }
                }
            }

            var freedCount = 0
            var freedBytes = 0L
            if (allowed.isNotEmpty()) {
                val confirmed = deleter.delete(allowed.map { it.localId })
                for (it in allowed) {
                    if (it.localId in confirmed) {
                        // Freed only after the user confirmed the OS dialog (M§4.5).
                        val next = it.copy(state = ItemState.Freed)
                        items.upsert(next)
                        events.itemChanged(next)
                        freedCount++
                        freedBytes += it.size
                    } else if (it.pairRole == PairRole.PRIMARY) {
                        skipped += SkippedFree(it.localId, "cancelled")
                    }
                }
                if (freedCount > 0) log.add(ActivityLog.FREED, "Freed $freedCount items ($freedBytes bytes) from this phone")
            }
            reporter.publish(force = true)
            FreeUpResult(freedCount, freedBytes, skipped)
        }

    private fun fingerprintChanged(it: ItemEntity): Boolean {
        val fp = media.fingerprint(it.localId) ?: return true
        return fp.size != it.size || fp.modifiedAtMs != it.modifiedAtMs
    }

    private fun denyReason(
        changed: Boolean,
        results: List<kotlinx.serialization.json.JsonElement>?,
        raw: ServerOutcome,
    ): String {
        if (changed) return "fingerprint_changed"
        if (results == null) return Pipeline.errorOf(raw) ?: "check_failed"
        for (r in results.mapNotNull { it as? JsonObject }) {
            val verdict = r.str("verdict")
            if (verdict != "exists") return "server_$verdict"
            if (r.str("asset_state") != "active") return "not_active_on_server"
            if ((r["on_disk"] as? kotlinx.serialization.json.JsonPrimitive)?.content != "true") return "not_on_server_disk"
        }
        return "denied"
    }

    /** Groups packed into check batches of at most [EngineConfig.checkBatchSize] hashes. */
    private fun batchGroups(groups: List<List<ItemEntity>>): List<List<List<ItemEntity>>> {
        val out = ArrayList<List<List<ItemEntity>>>()
        var cur = ArrayList<List<ItemEntity>>()
        var n = 0
        for (g in groups) {
            if (n + g.size > config.checkBatchSize && cur.isNotEmpty()) {
                out += cur
                cur = ArrayList()
                n = 0
            }
            cur += g
            n += g.size
        }
        if (cur.isNotEmpty()) out += cur
        return out
    }

    private fun attentionMessage(code: String): String =
        when (code) {
            "file_too_large" -> "The file is larger than the server accepts."
            "forbidden" -> "The server refused this file."
            "invalid_request" -> "The server rejected the upload request."
            "read_failed" -> "The file could not be read on this phone."
            "checksum_mismatch", "length_mismatch" -> "The file kept changing while it was uploaded."
            else -> "Backing up this item failed repeatedly ($code)."
        }

    companion object {
        /**
         * A persistent pin mismatch pauses with this reason (with an expiry) and
         * an activity entry ("server certificate changed — pair again").
         */
        val UNTRUSTED_PAUSE_REASON = PauseReason.ServerCertificateChanged

        /** The attention code of an item skipped because its content was deleted from the server. */
        const val TOMBSTONED = "tombstoned"

        private const val MAX_PAGE = 1000
        private val ACTIVE_STATES =
            listOf(ItemState.Discovered, ItemState.Hashed, ItemState.Queued, ItemState.Uploading, ItemState.Verifying)
    }
}

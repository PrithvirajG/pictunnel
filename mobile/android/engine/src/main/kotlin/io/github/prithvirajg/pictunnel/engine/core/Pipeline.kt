package io.github.prithvirajg.pictunnel.engine.core

import io.github.prithvirajg.pictunnel.engine.decide.Action
import io.github.prithvirajg.pictunnel.engine.decide.Decide
import io.github.prithvirajg.pictunnel.engine.decide.Decision
import io.github.prithvirajg.pictunnel.engine.decide.Flow
import io.github.prithvirajg.pictunnel.engine.decide.Given
import io.github.prithvirajg.pictunnel.engine.decide.LastAction
import io.github.prithvirajg.pictunnel.engine.decide.ServerOutcome
import io.github.prithvirajg.pictunnel.engine.decide.backoffDelayMs
import io.github.prithvirajg.pictunnel.engine.hash.Sha256
import io.github.prithvirajg.pictunnel.engine.model.ItemKind
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import io.github.prithvirajg.pictunnel.engine.model.MAX_ATTEMPTS
import io.github.prithvirajg.pictunnel.engine.model.PairRole
import io.github.prithvirajg.pictunnel.engine.model.PauseReason
import io.github.prithvirajg.pictunnel.engine.net.CheckItem
import io.github.prithvirajg.pictunnel.engine.net.Outcome
import io.github.prithvirajg.pictunnel.engine.net.ServerClient
import io.github.prithvirajg.pictunnel.engine.net.ServerException
import io.github.prithvirajg.pictunnel.engine.net.TRANSPORT_TLS
import io.github.prithvirajg.pictunnel.engine.net.TusClient
import io.github.prithvirajg.pictunnel.engine.net.UploadBody
import io.github.prithvirajg.pictunnel.engine.net.UploadLimits
import io.github.prithvirajg.pictunnel.engine.net.UploadMeta
import io.github.prithvirajg.pictunnel.engine.net.problem
import io.github.prithvirajg.pictunnel.engine.net.retryAfterMs
import io.github.prithvirajg.pictunnel.engine.store.EngineDb
import io.github.prithvirajg.pictunnel.engine.store.HashCacheEntity
import io.github.prithvirajg.pictunnel.engine.store.ItemEntity
import io.github.prithvirajg.pictunnel.engine.store.ScanStateEntity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import okio.Buffer
import okio.ForwardingSource
import java.time.Instant
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/** State shared by the phases of one run. */
internal class RunCtx(
    private val budget: RunBudget,
    private val clock: Clock,
) {
    private val startMono = clock.monotonicMs()
    private val stopRef = AtomicReference<StopReason?>(null)

    val stop: StopReason? get() = stopRef.get()
    val stopped: Boolean get() = stopRef.get() != null

    /** Records the first reason only; true when this call set it. */
    fun stop(r: StopReason): Boolean = stopRef.compareAndSet(null, r)

    /** R7 and similar: items left alone for the rest of this run. */
    val skipThisRun: MutableSet<String> = ConcurrentHashMap.newKeySet()

    /** Items whose `uploadOffset` came from the server during this run; any other offset is confirmed by HEAD first (R2). */
    val freshOffset: MutableSet<String> = ConcurrentHashMap.newKeySet()

    val transitions = AtomicInteger()
    val scanned = AtomicInteger()
    val hashed = AtomicInteger()
    val checked = AtomicInteger()
    val backedUp = AtomicInteger()
    val skipped = AtomicInteger()
    val needsAttention = AtomicInteger()
    val uploadsStarted = AtomicInteger()

    /** True (and the run stops) once the time budget is spent. */
    fun outOfTime(): Boolean {
        val max = budget.maxDurationMs ?: return false
        if (clock.monotonicMs() - startMono < max) return false
        stop(StopReason.Budget)
        return true
    }

    /** True (and the run stops) when no further upload may start. */
    fun outOfUploads(): Boolean {
        val max = budget.maxUploads ?: return false
        if (uploadsStarted.get() < max) return false
        stop(StopReason.Budget)
        return true
    }
}

/** What the caller of a step does next with the item. */
internal enum class Next { Continue, StopItem, StopRun }

/**
 * The backup pipeline (M§4.2): scan → hash → check → upload. Every item row is
 * written before the network call it governs (R1), and every server response
 * goes through [Decide.decide]; the resulting [Decision] is applied by
 * [apply] and nowhere else. A `tls` transport (every endpoint refused the
 * certificate) is not an item failure: it pauses the run instead.
 */
internal class Pipeline(
    private val db: EngineDb,
    private val media: MediaSource,
    private val client: ServerClient,
    private val settings: SettingsRepo,
    private val clock: Clock,
    private val events: EngineEvents,
    private val log: ActivityLog,
    private val reporter: StatusReporter,
    private val config: EngineConfig,
) {
    private val items = db.items()
    private val hashCache = db.hashCache()
    private val chunkLock = Mutex()

    @Volatile private var chunkBytes: Long? = config.chunkBytes

    // ---- scan ---------------------------------------------------------------

    suspend fun scan(
        ctx: RunCtx,
        scanner: Scanner,
    ) {
        val cursor = db.scanState().all().firstOrNull()?.let { ScanCursor(it.volume, it.generation, it.volumeVersion) }
        val r = scanner.scan(cursor)
        val writes = ArrayList<ItemEntity>()
        for (s in r.changed) {
            val existing = items.get(s.localId)
            val next =
                when {
                    existing == null -> fresh(s)
                    // Edited on the phone: new bytes, new identity. Re-hash; the old asset stays on the server.
                    existing.size != s.size || existing.modifiedAtMs != s.modifiedAtMs -> fresh(s)
                    else ->
                        existing.copy(
                            takenAtMs = s.takenAtMs,
                            mime = s.mime,
                            kind = s.kind,
                            filename = s.filename,
                            pairRole = s.pairRole,
                            pairLocalId = s.pairLocalId,
                            stackKey = s.stackKey,
                            width = s.width ?: existing.width,
                            height = s.height ?: existing.height,
                            durationMs = s.durationMs ?: existing.durationMs,
                        )
                }
            if (next != existing) {
                if (existing?.state != next.state) ctx.transitions.incrementAndGet()
                writes += next
            }
        }
        writes.chunked(BATCH).forEach { items.upsertAll(it) }
        // Deleted on the phone: dropped from the index only, never sent to the server (R8).
        val gone = r.removed.toMutableSet()
        if (r.fullRescan) gone += items.allIds().toSet() - r.changed.mapTo(HashSet()) { it.localId }
        gone.chunked(BATCH).forEach {
            items.delete(it)
            hashCache.delete(it)
        }
        r.cursor?.let { db.scanState().put(ScanStateEntity(it.volume, it.generation, it.volumeVersion)) }
        ctx.scanned.addAndGet(r.changed.size)
    }

    private fun fresh(s: ScannedItem) =
        ItemEntity(
            localId = s.localId,
            sha256 = null,
            size = s.size,
            modifiedAtMs = s.modifiedAtMs,
            takenAtMs = s.takenAtMs,
            mime = s.mime,
            kind = s.kind,
            pairRole = s.pairRole,
            pairLocalId = s.pairLocalId,
            stackKey = s.stackKey,
            state = ItemState.Discovered,
            attempts = 0,
            nextAttemptAtMs = null,
            uploadId = null,
            uploadUrl = null,
            uploadOffset = null,
            assetId = null,
            lastError = null,
            filename = s.filename,
            width = s.width,
            height = s.height,
            durationMs = s.durationMs,
        )

    // ---- hash (R3) ------------------------------------------------------------

    suspend fun hashPhase(ctx: RunCtx) {
        while (!ctx.stopped) {
            val page = due(listOf(ItemState.Discovered), ctx, PAGE)
            if (page.isEmpty()) return
            for (item in page) {
                if (ctx.stopped || ctx.outOfTime()) return
                hashOne(ctx, item)
            }
        }
    }

    private suspend fun hashOne(
        ctx: RunCtx,
        item: ItemEntity,
    ) {
        val id = item.localId
        val (fp, sha) =
            try {
                val fp = media.fingerprint(id) ?: return forget(id)
                // A cache hit means the bytes were already read once: never re-read them (R3).
                val cached = hashCache.lookup(id, fp.modifiedAtMs, fp.size)
                val sha = cached ?: withContext(Dispatchers.IO) { media.open(id).use { Sha256.hex(it) } }
                if (cached == null) hashCache.put(HashCacheEntity(id, fp.modifiedAtMs, fp.size, sha))
                fp to sha
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                localFailure(ctx, item, "read_failed", e)
                return
            }
        save(
            ctx,
            item,
            item.copy(
                sha256 = sha,
                size = fp.size,
                modifiedAtMs = fp.modifiedAtMs,
                state = ItemState.Hashed,
                nextAttemptAtMs = null,
                lastError = null,
            ),
        )
        ctx.hashed.incrementAndGet()
    }

    // ---- check (P§7.2) --------------------------------------------------------

    suspend fun checkPhase(ctx: RunCtx) {
        while (!ctx.stopped && !ctx.outOfTime()) {
            val batch = due(listOf(ItemState.Hashed), ctx, config.checkBatchSize).take(config.checkBatchSize)
            if (batch.isEmpty()) return
            checkItems(ctx, batch)
        }
    }

    /** Checks 1..1000 hashed items and applies each verdict; returns each item's new row and what to do next. */
    private suspend fun checkItems(
        ctx: RunCtx,
        batch: List<ItemEntity>,
    ): List<Pair<ItemEntity, Next>> {
        val out = client.check(batch.map { CheckItem(it.sha256!!, it.size, it.localId) })
        ctx.checked.addAndGet(batch.size)
        val raw = out.raw()
        if (raw.transport == TRANSPORT_TLS) {
            untrusted(ctx)
            return batch.map { it to Next.StopRun }
        }
        val results = ((raw.body as? JsonObject)?.get("results") as? JsonArray)
        if (out is Outcome.Ok && (results == null || results.size != batch.size)) {
            // The answer does not line up with the question: leave the batch for a later run (R7).
            return batch.map { skip(ctx, it, "check answered ${results?.size} of ${batch.size} items") }
        }
        val res = ArrayList<Pair<ItemEntity, Next>>(batch.size)
        for ((i, item) in batch.withIndex()) {
            if (ctx.stopped) {
                res += item to Next.StopRun
                continue
            }
            val one =
                if (out is Outcome.Ok) {
                    ServerOutcome(raw.status, raw.headers, JsonObject(mapOf("results" to JsonArray(listOf(results!![i])))), null)
                } else {
                    raw
                }
            val upload = (out as? Outcome.Ok)?.value?.getOrNull(i)?.upload
            res +=
                outcome(ctx, item, LastAction.CHECK, null, one) {
                    if (upload == null) {
                        it
                    } else {
                        ctx.freshOffset += it.localId
                        it.copy(uploadId = upload.id, uploadUrl = upload.url, uploadOffset = upload.offset)
                    }
                }
        }
        return res
    }

    // ---- upload (P§7.3) -------------------------------------------------------

    suspend fun uploadPhase(
        ctx: RunCtx,
        concurrency: Int,
    ) {
        if (ctx.stopped) return
        val eligible =
            due(listOf(ItemState.Queued, ItemState.Uploading, ItemState.Verifying), ctx, PAGE * 4).filter { pairReady(it) }
        if (eligible.isEmpty()) return
        val chunk = chunkBytes(ctx) ?: return
        coroutineScope {
            val slots = Semaphore(concurrency.coerceIn(1, EngineSettings.MAX_CONCURRENCY))
            for (item in eligible) {
                slots.acquire()
                if (ctx.stopped || ctx.outOfTime() || ctx.outOfUploads()) {
                    slots.release()
                    break
                }
                ctx.uploadsStarted.incrementAndGet()
                launch {
                    try {
                        uploadItem(ctx, item, chunk)
                    } finally {
                        slots.release()
                    }
                }
            }
        }
    }

    /** H4: a Live Photo's video goes up only after its primary still is backed up. */
    private suspend fun pairReady(item: ItemEntity): Boolean {
        if (item.pairRole != PairRole.LIVE_VIDEO) return true
        val primary = item.pairLocalId?.let { items.get(it) } ?: return false
        return (primary.state == ItemState.BackedUp || primary.state == ItemState.Freed) && primary.sha256 != null
    }

    private suspend fun uploadItem(
        ctx: RunCtx,
        start: ItemEntity,
        chunk: Long,
    ) {
        var item = start
        reporter.uploadStarted(item)
        try {
            var resolves = 0
            repeat(MAX_STEPS) {
                if (ctx.stopped) return
                val offset = item.uploadOffset
                val (next, flow) =
                    when {
                        item.state == ItemState.Queued -> create(ctx, item, chunk)
                        item.state == ItemState.Uploading && item.uploadUrl == null -> create(ctx, item, chunk)
                        // An offset not confirmed by the server in this run may be stale (R2): ask first.
                        item.state == ItemState.Uploading && (offset == null || item.localId !in ctx.freshOffset) -> head(ctx, item)
                        // Every byte is there but no asset id yet: finalize may still be running.
                        // Resolve with check instead of PATCHing (P§7.4).
                        item.state == ItemState.Uploading && offset!! >= item.size ->
                            save(ctx, item, item.copy(state = ItemState.Verifying)) to Next.Continue
                        item.state == ItemState.Uploading -> patch(ctx, item, chunk)
                        item.state == ItemState.Verifying || item.state == ItemState.Hashed ->
                            if (resolves++ < MAX_RESOLVES) {
                                checkItems(ctx, listOf(item)).single()
                            } else {
                                // Still finalizing: look again later; not the item's fault, so no attempt.
                                wait(ctx, item, backoffDelayMs(1, config.random)) to Next.StopItem
                            }
                        else -> return
                    }
                item = next
                if (flow != Next.Continue) return
            }
            skip(ctx, item, "upload did not settle in $MAX_STEPS steps")
        } finally {
            reporter.uploadEnded(start.localId)
        }
    }

    private suspend fun create(
        ctx: RunCtx,
        item: ItemEntity,
        chunk: Long,
    ): Pair<ItemEntity, Next> {
        val primarySha =
            if (item.pairRole == PairRole.LIVE_VIDEO) {
                item.pairLocalId?.let { items.get(it) }?.sha256 ?: return skip(ctx, item, "live video without its primary")
            } else {
                null
            }
        // Single-shot creation-with-upload up to the chunk size; a known asset (H4 re-attach) needs no bytes.
        val body =
            if (item.assetId == null && item.size <= chunk) {
                body(ctx, item) ?: return item to Next.StopItem
            } else {
                null
            }
        val meta =
            UploadMeta(
                sha256 = item.sha256!!,
                filename = item.filename,
                mime = item.mime,
                localId = item.localId,
                createdAt = Instant.ofEpochMilli(item.takenAtMs).toString(),
                modifiedAt = Instant.ofEpochMilli(item.modifiedAtMs).toString(),
                pairRole = if (primarySha != null) PairRole.LIVE_VIDEO else null,
                pairSha256 = primarySha,
                stackKey = item.stackKey,
            )
        val out = client.tus.create(meta, item.size, body)
        return outcome(ctx, item, LastAction.CREATE_UPLOAD, false, out.raw()) {
            val v = (out as? Outcome.Ok)?.value ?: return@outcome it
            ctx.freshOffset += it.localId
            it.copy(uploadUrl = v.url, uploadId = v.url.substringAfterLast('/'), uploadOffset = v.offset)
        }
    }

    private suspend fun head(
        ctx: RunCtx,
        item: ItemEntity,
    ): Pair<ItemEntity, Next> {
        val out = client.tus.head(item.uploadUrl!!)
        return outcome(ctx, item, LastAction.HEAD_UPLOAD, true, out.raw()) {
            val v = (out as? Outcome.Ok)?.value ?: return@outcome it
            ctx.freshOffset += it.localId
            it.copy(uploadOffset = v.offset)
        }
    }

    private suspend fun patch(
        ctx: RunCtx,
        item: ItemEntity,
        chunk: Long,
    ): Pair<ItemEntity, Next> {
        val offset = item.uploadOffset!!
        val length = minOf(chunk, item.size - offset)
        val body = body(ctx, item) ?: return item to Next.StopItem
        val out = client.tus.patch(item.uploadUrl!!, offset, length, body)
        return outcome(ctx, item, LastAction.APPEND_UPLOAD, true, out.raw()) {
            val v = (out as? Outcome.Ok)?.value ?: return@outcome it
            ctx.freshOffset += it.localId
            it.copy(uploadOffset = v.offset)
        }
    }

    /** The item's bytes, reporting progress; null (already handled) when the file cannot be opened. */
    private suspend fun body(
        ctx: RunCtx,
        item: ItemEntity,
    ): UploadBody? {
        val source =
            try {
                media.openSeekable(item.localId)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                if (media.fingerprint(item.localId) == null) forget(item.localId) else localFailure(ctx, item, "read_failed", e)
                return null
            }
        return UploadBody { offset, length ->
            object : ForwardingSource(source.open(offset, length)) {
                private var pos = offset

                override fun read(
                    sink: Buffer,
                    byteCount: Long,
                ): Long {
                    val n = super.read(sink, byteCount)
                    if (n > 0) {
                        pos += n
                        reporter.bytesSent(item.localId, pos)
                    }
                    return n
                }
            }
        }
    }

    private suspend fun chunkBytes(ctx: RunCtx): Long? {
        chunkBytes?.let { return it }
        return chunkLock.withLock {
            chunkBytes?.let { return@withLock it }
            val value =
                try {
                    client.serverInfo().upload.recommendedChunkBytes
                } catch (e: ServerException) {
                    if (e.raw.transport == TRANSPORT_TLS) {
                        untrusted(ctx)
                        return@withLock null
                    }
                    // Unknown for now: use the default without caching it.
                    return@withLock UploadLimits.DEFAULT_CHUNK_BYTES
                }
            value.takeIf { it > 0 }?.also { chunkBytes = it } ?: UploadLimits.DEFAULT_CHUNK_BYTES
        }
    }

    // ---- decisions --------------------------------------------------------------

    private suspend fun outcome(
        ctx: RunCtx,
        item: ItemEntity,
        lastAction: String,
        hasUploadId: Boolean?,
        raw: ServerOutcome,
        ok: (ItemEntity) -> ItemEntity,
    ): Pair<ItemEntity, Next> {
        // Every endpoint refused the certificate: a connection-level problem, not this item's.
        if (raw.transport == TRANSPORT_TLS) {
            untrusted(ctx)
            return item to Next.StopRun
        }
        val given =
            Given(
                Flow.BACKUP,
                item.state.name,
                lastAction,
                buildMap {
                    put("kind", if (item.pairRole == PairRole.LIVE_VIDEO) ItemKind.VIDEO else item.kind)
                    put("attempts", item.attempts)
                    if (hasUploadId != null) put("has_upload_id", hasUploadId)
                },
            )
        return apply(ctx, item, raw, Decide.decide(given, raw), ok)
    }

    /** Applies one [Decision] to [item]: the only place a server response changes an item. */
    private suspend fun apply(
        ctx: RunCtx,
        item: ItemEntity,
        raw: ServerOutcome,
        d: Decision,
        ok: (ItemEntity) -> ItemEntity,
    ): Pair<ItemEntity, Next> {
        val id = item.localId
        val attempts = item.attempts + d.attemptsDelta
        val state = d.nextState ?: item.state
        val error = errorOf(raw)
        return when (d.action) {
            Action.MARK_BACKED_UP -> {
                // R4: only with a server asset id (decide() guarantees one is present).
                val assetId = raw.header(TusClient.ASSET_ID)?.takeIf { it.isNotEmpty() } ?: checkResult(raw)?.str("asset_id")
                val next =
                    save(
                        ctx,
                        item,
                        item.cleared().copy(
                            state = ItemState.BackedUp,
                            assetId = assetId,
                            attempts = 0,
                            nextAttemptAtMs = null,
                            lastError = null,
                        ),
                    )
                ctx.backedUp.incrementAndGet()
                log.add(ActivityLog.BACKED_UP, "Backed up ${item.filename}", id)
                next to Next.StopItem
            }
            Action.QUEUE_UPLOAD ->
                save(ctx, item, item.cleared().copy(state = ItemState.Queued, attempts = attempts, nextAttemptAtMs = null)) to
                    Next.Continue
            Action.RESUME_UPLOAD -> {
                val next = ok(item).copy(state = ItemState.Uploading, attempts = attempts, nextAttemptAtMs = null)
                save(ctx, item, next) to Next.Continue
            }
            Action.HEAD_THEN_RESUME -> {
                ctx.freshOffset -= id
                save(ctx, item, item.copy(state = ItemState.Uploading, attempts = attempts, uploadOffset = null, lastError = error)) to
                    Next.Continue
            }
            Action.RESTART_UPLOAD -> {
                ctx.freshOffset -= id
                save(ctx, item, item.cleared().copy(state = ItemState.Queued, attempts = attempts, lastError = error)) to Next.Continue
            }
            Action.CHECK_THEN_RESOLVE -> {
                ctx.freshOffset -= id
                save(ctx, item, item.cleared().copy(state = ItemState.Hashed, attempts = attempts, lastError = error)) to Next.Continue
            }
            Action.MARK_SKIPPED -> {
                val next = save(ctx, item, item.cleared().copy(state = ItemState.Skipped, nextAttemptAtMs = null, lastError = error))
                ctx.skipped.incrementAndGet()
                log.add(ActivityLog.SKIPPED, "Skipped ${item.filename}: deleted from the server earlier", id)
                next to Next.StopItem
            }
            Action.REHASH_AND_REQUEUE -> {
                hashCache.delete(listOf(id))
                save(
                    ctx,
                    item,
                    item.cleared().copy(state = ItemState.Discovered, sha256 = null, attempts = attempts, lastError = error),
                ) to Next.StopItem
            }
            Action.BACKOFF_RETRY -> wait(ctx, item.copy(state = state, attempts = attempts, lastError = error), backoff(attempts)) to Next.StopItem
            Action.WAIT_RETRY_AFTER -> {
                val delay = raw.retryAfterMs(clock.nowMs()) ?: backoff(attempts)
                wait(ctx, item.copy(state = state, attempts = attempts, lastError = error), delay) to Next.StopItem
            }
            Action.WAIT_FOR_NETWORK -> {
                // R5: no network is never an attempt; the row is unchanged.
                ctx.stop(StopReason.Offline)
                item to Next.StopRun
            }
            Action.REQUIRE_REPAIR -> {
                if (ctx.stop(StopReason.NeedsRepair)) {
                    log.add(ActivityLog.ERROR, "This phone is no longer paired with the server — pair again")
                    events.needsRepair()
                }
                item to Next.StopRun
            }
            Action.PAUSE_ALL_UPLOADS -> pauseRun(ctx, item, PauseReason.ServerFull, SERVER_PAUSE_MS, "The server is out of storage")
            Action.NOTIFY_QUOTA -> pauseRun(ctx, item, PauseReason.Quota, SERVER_PAUSE_MS, "Your storage quota on the server is full")
            Action.PROMPT_UPDATE -> pauseRun(ctx, item, PauseReason.ClientTooOld, null, "The server needs a newer version of the app")
            Action.MARK_NEEDS_ATTENTION -> {
                val next =
                    save(
                        ctx,
                        item,
                        item.copy(state = ItemState.NeedsAttention, attempts = attempts, nextAttemptAtMs = null, lastError = error),
                    )
                ctx.needsAttention.incrementAndGet()
                log.add(ActivityLog.NEEDS_ATTENTION, "${item.filename} needs attention ($error)", id)
                next to Next.StopItem
            }
            Action.UPLOAD_PRIMARY_FIRST -> {
                // H4: the server lacks the still; upload it again, then this video.
                item.pairLocalId?.let { items.get(it) }?.let { p ->
                    if (p.state == ItemState.BackedUp || p.state == ItemState.Freed) {
                        save(ctx, p, p.cleared().copy(state = ItemState.Queued, assetId = null))
                    }
                }
                save(ctx, item, item.cleared().copy(state = ItemState.Queued, attempts = attempts, lastError = error)) to Next.StopItem
            }
            Action.UPLOAD_LIVE_VIDEO -> {
                // The still exists but its paired video is missing (crash between the two uploads, H4).
                val assetId = checkResult(raw)?.str("asset_id")
                item.pairLocalId?.let { items.get(it) }?.let { v ->
                    if (v.pairRole == PairRole.LIVE_VIDEO && (v.state == ItemState.BackedUp || v.state == ItemState.Freed)) {
                        save(ctx, v, v.cleared().copy(state = ItemState.Queued))
                    }
                }
                save(ctx, item, item.cleared().copy(state = ItemState.Queued, assetId = assetId, attempts = attempts)) to Next.Continue
            }
            Action.REFRESH_THEN_RETRY -> skip(ctx, item, "still unauthorized after a token refresh")
            Action.SKIP_THIS_RUN -> skip(ctx, item, "unexpected answer (${error ?: "no detail"})")
            else -> skip(ctx, item, "unexpected decision ${d.action}")
        }
    }

    private suspend fun pauseRun(
        ctx: RunCtx,
        item: ItemEntity,
        reason: PauseReason,
        forMs: Long?,
        message: String,
    ): Pair<ItemEntity, Next> {
        // A run-level pause (M§4.3): the row keeps its resumable state, so resuming needs no rewrite.
        settings.setPause(PauseState(reason, forMs?.let { clock.nowMs() + it }))
        if (ctx.stop(StopReason.Paused)) log.add(ActivityLog.PAUSED, "Backup paused: $message")
        return item to Next.StopRun
    }

    private suspend fun untrusted(ctx: RunCtx) {
        settings.setPause(PauseState(EngineController.UNTRUSTED_PAUSE_REASON, clock.nowMs() + UNTRUSTED_PAUSE_MS))
        if (ctx.stop(StopReason.ServerUntrusted)) {
            log.add(ActivityLog.ERROR, "Backup paused: server certificate changed — pair again")
        }
    }

    private suspend fun skip(
        ctx: RunCtx,
        item: ItemEntity,
        why: String,
    ): Pair<ItemEntity, Next> {
        ctx.skipThisRun += item.localId
        log.add(ActivityLog.INFO, "Skipped ${item.filename} for now: $why", item.localId)
        return item to Next.StopItem
    }

    /** A local read failure (not a server response): counted like a retryable failure. */
    private suspend fun localFailure(
        ctx: RunCtx,
        item: ItemEntity,
        code: String,
        e: Exception,
    ) {
        val attempts = item.attempts + 1
        if (attempts >= MAX_ATTEMPTS) {
            save(ctx, item, item.copy(state = ItemState.NeedsAttention, attempts = attempts, nextAttemptAtMs = null, lastError = code))
            ctx.needsAttention.incrementAndGet()
            log.add(ActivityLog.NEEDS_ATTENTION, "${item.filename} could not be read: ${e.message}", item.localId)
        } else {
            wait(ctx, item.copy(attempts = attempts, lastError = code), backoff(attempts))
        }
    }

    private suspend fun forget(localId: String) {
        items.delete(listOf(localId))
        hashCache.delete(listOf(localId))
    }

    private suspend fun wait(
        ctx: RunCtx,
        item: ItemEntity,
        delayMs: Long,
    ): ItemEntity = save(ctx, item, item.copy(nextAttemptAtMs = clock.nowMs() + delayMs))

    private fun backoff(attempts: Int) = backoffDelayMs(attempts.coerceAtLeast(1), config.random)

    private suspend fun save(
        ctx: RunCtx?,
        before: ItemEntity,
        after: ItemEntity,
    ): ItemEntity {
        items.upsert(after)
        if (before.state != after.state) ctx?.transitions?.incrementAndGet()
        events.itemChanged(after)
        reporter.publish()
        return after
    }

    private suspend fun due(
        states: List<ItemState>,
        ctx: RunCtx,
        limit: Int,
    ): List<ItemEntity> =
        items
            .due(states, clock.nowMs(), limit + minOf(ctx.skipThisRun.size, limit))
            .filter { it.localId !in ctx.skipThisRun }

    private fun ItemEntity.cleared() = copy(uploadId = null, uploadUrl = null, uploadOffset = null)

    companion object {
        private const val BATCH = 500
        private const val PAGE = 250
        private const val MAX_STEPS = 64
        private const val MAX_RESOLVES = 2
        private const val SERVER_PAUSE_MS = 30 * 60 * 1000L
        private const val UNTRUSTED_PAUSE_MS = 60 * 60 * 1000L

        internal fun errorOf(raw: ServerOutcome): String? = raw.problem()?.code ?: raw.transport ?: raw.status?.let { "http_$it" }

        internal fun checkResult(raw: ServerOutcome): JsonObject? =
            ((raw.body as? JsonObject)?.get("results") as? JsonArray)?.firstOrNull() as? JsonObject

        internal fun JsonObject.str(k: String): String? = (this[k] as? JsonPrimitive)?.takeIf { it.isString }?.content
    }
}

internal fun <T> Outcome<T>.raw(): ServerOutcome =
    when (this) {
        is Outcome.Ok -> raw
        is Outcome.Fail -> raw
    }

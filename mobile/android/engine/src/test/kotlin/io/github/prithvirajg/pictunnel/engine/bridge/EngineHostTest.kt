package io.github.prithvirajg.pictunnel.engine.bridge

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.github.prithvirajg.pictunnel.engine.decide.ServerOutcome
import io.github.prithvirajg.pictunnel.engine.model.ItemKind
import io.github.prithvirajg.pictunnel.engine.model.PairRole
import io.github.prithvirajg.pictunnel.engine.net.AuthException
import io.github.prithvirajg.pictunnel.engine.net.RefreshOutcome
import io.github.prithvirajg.pictunnel.engine.pairing.PairException
import io.github.prithvirajg.pictunnel.engine.pairing.ServerFingerprint
import io.github.prithvirajg.pictunnel.engine.platform.Album
import io.github.prithvirajg.pictunnel.engine.store.ActivityEntity
import io.github.prithvirajg.pictunnel.engine.store.ItemEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import java.nio.ByteBuffer
import java.time.Duration
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import io.github.prithvirajg.pictunnel.engine.core.AttentionItem as CoreAttention
import io.github.prithvirajg.pictunnel.engine.core.BackupStatus as CoreStatus
import io.github.prithvirajg.pictunnel.engine.core.EngineSettings as CoreSettings
import io.github.prithvirajg.pictunnel.engine.core.FreeUpResult as CoreFreeUp
import io.github.prithvirajg.pictunnel.engine.core.MediaAccess as CoreAccess
import io.github.prithvirajg.pictunnel.engine.core.PhoneItemPage as CorePage
import io.github.prithvirajg.pictunnel.engine.core.SkippedFree as CoreSkipped
import io.github.prithvirajg.pictunnel.engine.core.UploadProgress as CoreUpload
import io.github.prithvirajg.pictunnel.engine.model.ItemState as CoreState
import io.github.prithvirajg.pictunnel.engine.model.PauseReason as CorePause
import io.github.prithvirajg.pictunnel.engine.pairing.PairResult as CorePair

/**
 * A [BinaryMessenger] standing in for the Flutter engine: messages to a
 * registered channel go to its handler (Flutter → host); messages to other
 * channels are host → Flutter events, recorded decoded and acknowledged.
 */
class FakeMessenger : BinaryMessenger {
    private val handlers = HashMap<String, BinaryMessenger.BinaryMessageHandler>()
    val events = ArrayList<Pair<String, List<Any?>>>()

    override fun send(
        channel: String,
        message: ByteBuffer?,
    ) = send(channel, message, null)

    override fun send(
        channel: String,
        message: ByteBuffer?,
        callback: BinaryMessenger.BinaryReply?,
    ) {
        message?.flip()
        val h = handlers[channel]
        if (h != null) {
            h.onMessage(message) { reply -> callback?.reply(reply?.also { it.flip() }) }
            return
        }
        @Suppress("UNCHECKED_CAST")
        synchronized(events) { events += channel.substringAfterLast('.') to (EngineEventsApi.codec.decodeMessage(message) as List<Any?>? ?: emptyList()) }
        callback?.reply(EngineEventsApi.codec.encodeMessage(emptyList<Any?>())?.also { it.flip() })
    }

    override fun setMessageHandler(
        channel: String,
        handler: BinaryMessenger.BinaryMessageHandler?,
    ) {
        if (handler == null) handlers.remove(channel) else handlers[channel] = handler
    }

    fun hasHandler(channel: String) = channel in handlers

    /** Calls a host method the way Pigeon's Dart side does; returns the raw reply list. */
    fun call(
        method: String,
        vararg args: Any?,
    ): List<Any?> {
        val codec = EngineHostApi.codec
        val latch = CountDownLatch(1)
        var out: List<Any?>? = null
        send("$PREFIX$method", if (args.isEmpty()) null else codec.encodeMessage(args.toList())) { r ->
            @Suppress("UNCHECKED_CAST")
            out = codec.decodeMessage(r) as List<Any?>
            latch.countDown()
        }
        assertTrue("no reply to $method", latch.await(5, TimeUnit.SECONDS))
        return out!!
    }

    companion object {
        const val PREFIX = "dev.flutter.pigeon.pictunnel.EngineHostApi."
    }
}

/** Records every call and answers with canned engine values; [failWith] makes the next call throw. */
class FakeBackend : HostBackend {
    val calls = ArrayList<String>()
    var failWith: Throwable? = null
    var settings = CoreSettings(wifiOnly = true, uploadConcurrency = 3)

    private fun hit(name: String) {
        synchronized(calls) { calls += name }
        failWith?.let {
            failWith = null
            throw it
        }
    }

    val item =
        ItemEntity(
            localId = "external_primary:image:7", sha256 = "ab".repeat(32), size = 2048, modifiedAtMs = 1, takenAtMs = 1_700_000_000_000,
            mime = "image/heic", kind = ItemKind.LIVE_PHOTO, pairRole = PairRole.PRIMARY, pairLocalId = null, stackKey = null,
            state = CoreState.BackedUp, attempts = 0, nextAttemptAtMs = null, uploadId = null, uploadUrl = null, uploadOffset = null,
            assetId = "asset-1", lastError = null, filename = "IMG_0007.HEIC", width = 4032, height = 3024, durationMs = null,
        )

    override suspend fun pairQr(
        qrUri: String,
        deviceName: String,
    ) = Paired(CorePair("srv", "me", "dev-$deviceName"), "Home").also { hit("pairQr:$qrUri") }

    override suspend fun pairManual(
        serverUrl: String,
        code: String,
        pin: String,
        deviceName: String,
    ) = Paired(CorePair("srv", "me", "dev"), "Home").also { hit("pairManual:$serverUrl:$code:$pin") }

    override suspend fun trustOnFirstUse(serverUrl: String) =
        ServerFingerprint("srv", "Home", "AB12CD34EF56GH78restOfFingerprint", serverUrl).also { hit("tofu") }

    override suspend fun unpair() = hit("unpair")

    override suspend fun accessToken() = "token".also { hit("accessToken") }

    override suspend fun connection() = Connection("srv", "Home", "https://192.168.1.20:8443", true, "AB12CD34EF56GH78").also { hit("connection") }

    override suspend fun start() = hit("start")

    override suspend fun pause(reason: CorePause) = hit("pause:$reason")

    override suspend fun runNow() = hit("runNow")

    override suspend fun status() =
        CoreStatus(
            backedUp = 5, total = 9, queued = 2, uploading = CoreUpload("a", "IMG_1.JPG", 10, 20, 1.5), needsAttention = 1,
            skipped = 1, freeableBytes = 4096, paused = true, pauseReason = CorePause.ServerCertificateChanged, lastRunAtMs = 99,
            preparing = 1, mediaAccess = CoreAccess.Partial,
        ).also { hit("status") }

    override suspend fun settings() = settings.also { hit("settings") }

    override suspend fun setSettings(s: CoreSettings) {
        hit("setSettings")
        settings = s
    }

    override suspend fun albums() = listOf(Album("12", "Camera", 40)).also { hit("albums") }

    override suspend fun phoneItems(
        afterKey: String?,
        limit: Int,
    ) = CorePage(listOf(item), "1|x").also { hit("phoneItems:$afterKey:$limit") }

    override suspend fun thumbnail(
        localId: String,
        sizePx: Int,
    ) = byteArrayOf(1, 2, 3).also { hit("thumbnail:$localId:$sizePx") }

    override suspend fun attention() =
        listOf(CoreAttention("x", "IMG_9.JPG", "tombstoned", "m", 0, "cd".repeat(32))).also { hit("attention") }

    override suspend fun retry(localIds: List<String>) = hit("retry:$localIds")

    override suspend fun activity(limit: Int) = listOf(ActivityEntity(1, 42, "upload", "x", "Uploaded")).also { hit("activity:$limit") }

    override suspend fun freeUpSpace(localIds: List<String>?) =
        CoreFreeUp(1, 2048, listOf(CoreSkipped("y", "cancelled"))).also { hit("freeUpSpace:$localIds") }

    var undoOk = true

    override suspend fun undoSkip(sha256: String) = undoOk.also { hit("undoSkip") }

    override suspend fun saveToGallery(
        assetId: String,
        filename: String,
        mime: String,
    ) = "external_primary:image:99".also { hit("saveToGallery:$assetId:$filename:$mime") }

    override suspend fun discover(timeoutMs: Long) = listOf("https://192.168.1.20:8443").also { hit("discover:$timeoutMs") }
}

@RunWith(RobolectricTestRunner::class)
class EngineHostTest {
    private lateinit var messenger: FakeMessenger
    private lateinit var backend: FakeBackend

    @Before fun setUp() {
        messenger = FakeMessenger()
        backend = FakeBackend()
        EngineHostApi.setUp(messenger, EngineHost(backend, deliver = { it.run() }))
    }

    private fun ok(
        method: String,
        vararg args: Any?,
    ): Any? {
        val r = messenger.call(method, *args)
        assertEquals("$method failed: $r", 1, r.size)
        return r[0]
    }

    private fun err(
        method: String,
        vararg args: Any?,
    ): String {
        val r = messenger.call(method, *args)
        assertEquals("$method should fail: $r", 3, r.size)
        return r[0] as String
    }

    @Test fun everyHostMethodGoesThroughTheCodec() {
        val pair = ok("pair", PairRequest(qrUri = "pictunnel://pair?x", deviceName = "Pixel")) as PairResult
        assertEquals(PairResult("srv", "Home", "me", "dev-Pixel"), pair)

        ok("pair", PairRequest(serverUrl = "https://h:8443", code = "ABCD-EFGH-JK", deviceName = "P", pinnedFp = "pin"))
        assertTrue("pairManual:https://h:8443:ABCD-EFGH-JK:pin" in backend.calls)

        val id = ok("trustOnFirstUse", "https://h:8443") as ServerIdentity
        assertEquals("AB12CD34EF56GH78", id.fp16)
        assertEquals("AB12CD34EF56GH78restOfFingerprint", id.fpFull)
        assertEquals("https://h:8443", id.url)

        assertNull(ok("unpair"))
        assertEquals("token", ok("getAccessToken"))
        assertEquals(ServerConnection("srv", "Home", "https://192.168.1.20:8443", true, "AB12CD34EF56GH78"), ok("serverInfo"))
        assertNull(ok("start"))
        assertNull(ok("pause", PauseReason.WIFI_REQUIRED))
        assertNull(ok("runNow"))

        val s = ok("getStatus") as BackupStatus
        assertEquals(5L, s.backedUp)
        assertEquals(PauseReason.SERVER_CERTIFICATE_CHANGED, s.pauseReason)
        assertEquals(MediaAccess.PARTIAL, s.mediaAccess)
        assertEquals("IMG_1.JPG", s.uploading!!.filename)

        val settings = ok("getSettings") as EngineSettings
        assertTrue(settings.wifiOnly)
        assertNull(ok("setSettings", settings.copy(includeVideos = false, albumIds = listOf("12"))))
        assertEquals("the engine-only concurrency survives a settings write", 3, backend.settings.uploadConcurrency)
        assertEquals(false, backend.settings.includeVideos)
        assertEquals(listOf("12"), backend.settings.albumIds)

        assertEquals(listOf(AlbumInfo("12", "Camera", 40)), ok("listAlbums"))

        val page = ok("listPhoneItems", PageRequest(afterKey = "5|a", limit = 50)) as PhoneItemPage
        val p = page.items.single()
        assertEquals("IMG_0007.HEIC", p.filename)
        assertEquals(ItemState.BACKED_UP, p.state)
        assertTrue(p.isLivePhoto)
        assertEquals(4032L, p.width)
        assertEquals("1|x", page.nextKey)
        assertTrue("phoneItems:5|a:50" in backend.calls)

        assertTrue((ok("phoneThumbnail", "id", 96L) as ByteArray).contentEquals(byteArrayOf(1, 2, 3)))

        val att = (ok("listAttention") as List<*>).single() as AttentionItem
        assertEquals("cd".repeat(32), att.sha256)

        assertNull(ok("retry", listOf("a", "b")))
        assertEquals(listOf(ActivityEntry(42, "upload", "Uploaded", "x")), ok("listActivity", 200L))

        val free = ok("freeUpSpace", null) as FreeUpResult
        assertEquals(1L, free.freedCount)
        assertEquals(listOf(SkippedFree("y", "cancelled")), free.skipped)

        assertNull(ok("undoSkip", "cd".repeat(32)))
        assertEquals("external_primary:image:99", ok("saveToGallery", "asset-1", "IMG.JPG", "image/jpeg"))
        assertEquals(listOf("https://192.168.1.20:8443"), ok("discoverServers", 3000L))

        assertEquals(
            listOf(
                "pairQr:pictunnel://pair?x", "pairManual:https://h:8443:ABCD-EFGH-JK:pin", "tofu", "unpair", "accessToken",
                "connection", "start", "pause:WifiRequired", "runNow", "status", "settings", "settings", "setSettings", "albums",
                "phoneItems:5|a:50", "thumbnail:id:96", "attention", "retry:[a, b]", "activity:200", "freeUpSpace:null", "undoSkip",
                "saveToGallery:asset-1:IMG.JPG:image/jpeg", "discover:3000",
            ),
            backend.calls,
        )
    }

    @Test fun pairingErrorsUseTheCodesTheAppShows() {
        val req = PairRequest(qrUri = "pictunnel://pair?x", deviceName = "P")
        backend.failWith = PairException("tls")
        assertEquals("pin_mismatch", err("pair", req))
        backend.failWith = PairException("pairing_code_invalid")
        assertEquals("pairing_code_invalid", err("pair", req))
        for (kind in listOf("offline", "timeout", "reset")) {
            backend.failWith = PairException(kind)
            assertEquals("unreachable", err("pair", req))
        }
        backend.failWith = PairException("offline")
        assertEquals("unreachable", err("trustOnFirstUse", "https://h"))
        backend.failWith = PairException("invalid_scheme")
        assertEquals("invalid_scheme", err("pair", req))
        assertEquals("missing_fingerprint", err("pair", PairRequest(serverUrl = "https://h", code = "C", deviceName = "P")))
    }

    @Test fun otherErrorsMapToStableCodes() {
        backend.failWith = HostException(AndroidHostBackend.NOT_PAIRED)
        assertEquals("not_paired", err("getStatus"))
        backend.failWith = AuthException(RefreshOutcome.NeedsRepair(null))
        assertEquals("needs_repair", err("getAccessToken"))
        backend.failWith = AuthException(RefreshOutcome.Transient(ServerOutcome(null, emptyMap(), null, "offline")))
        assertEquals("unreachable", err("getAccessToken"))
        backend.failWith = java.io.IOException("boom")
        assertEquals("unreachable", err("saveToGallery", "a", "b", "image/jpeg"))
        backend.failWith = IllegalStateException("bug")
        assertEquals("internal", err("listAlbums"))
        backend.undoOk = false
        assertEquals("undo_failed", err("undoSkip", "cd".repeat(32)))
    }

    @Test fun unregisteringRemovesTheHandlers() {
        assertTrue(messenger.hasHandler("${FakeMessenger.PREFIX}getStatus"))
        EngineHostApi.setUp(messenger, null)
        assertTrue(!messenger.hasHandler("${FakeMessenger.PREFIX}getStatus"))
    }

    @Test fun eventsRelayCoalescesToFourPerSecond() {
        val relay = EventsRelay(Handler(Looper.getMainLooper()))
        relay.attach(EngineEventsApi(messenger))
        val looper = shadowOf(Looper.getMainLooper())
        val base = runCatchingStatus()
        // 100 updates over one second, every 10 ms.
        repeat(100) { i ->
            relay.status(base.copy(backedUp = i))
            relay.itemChanged(backend.item.copy(state = if (i % 2 == 0) CoreState.Queued else CoreState.Uploading))
            looper.idleFor(Duration.ofMillis(10))
        }
        looper.idleFor(Duration.ofSeconds(1))
        val statuses = messenger.events.filter { it.first == "onStatus" }.map { it.second[0] as BackupStatus }
        val items = messenger.events.filter { it.first == "onItemChanged" }
        // One second of updates plus the trailing flush: at most 4 per second, plus one.
        assertTrue("got ${statuses.size} status events", statuses.size in 2..6)
        assertEquals("the latest status always arrives", 99L, statuses.last().backedUp)
        assertTrue("item changes coalesce per item: ${items.size}", items.size <= 6)
        assertEquals(ItemState.UPLOADING, (items.last().second[0] as PhoneItem).state)

        relay.needsRepair()
        looper.idle()
        assertEquals("onNeedsRepair", messenger.events.last().first)

        relay.detach()
        val before = messenger.events.size
        relay.status(base)
        looper.idleFor(Duration.ofSeconds(1))
        assertEquals("a detached relay drops events", before, messenger.events.size)
    }

    private fun runCatchingStatus() =
        CoreStatus(
            backedUp = 0, total = 100, queued = 0, uploading = null, needsAttention = 0, skipped = 0, freeableBytes = 0,
            paused = false, pauseReason = null, lastRunAtMs = null, preparing = 0,
        )
}

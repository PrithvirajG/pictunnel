package io.github.prithvirajg.pictunnel.engine.platform

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.github.prithvirajg.pictunnel.engine.core.Fingerprint
import okio.Buffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.FileNotFoundException

@RunWith(RobolectricTestRunner::class)
class ContentMediaSourceTest {
    private lateinit var provider: FakeMediaProvider
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private val bytes = ByteArray(1000) { (it * 7).toByte() }

    @Before fun setUp() {
        provider = FakeMediaProvider.install()
    }

    private fun source() = ContentMediaSource(context, requireOriginal = { false })

    @Test fun opensTheOriginalBytes() {
        val id = provider.add(bytes = bytes)
        assertArrayEquals(bytes, source().open("external_primary:image:$id").readBytes())
    }

    @Test fun fingerprintIsSizeAndModifiedTimeOrNullWhenGone() {
        val id = provider.add(bytes = bytes, modifiedSec = 1_700_000_123)
        val local = "external_primary:image:$id"
        assertEquals(Fingerprint(1_700_000_123_000L, 1000), source().fingerprint(local))
        provider.remove(id)
        assertNull(source().fingerprint(local))
    }

    @Test fun seekableBodyServesAnyRange() {
        val id = provider.add(type = "video", bytes = bytes)
        val body = source().openSeekable("external_primary:video:$id")
        val out = Buffer()
        body.open(300, 200).use { src -> while (src.read(out, 8192) != -1L) Unit }
        assertArrayEquals(bytes.copyOfRange(300, 500), out.readByteArray())
        // Reopenable from the start, too.
        val all = Buffer()
        body.open(0, 1000).use { src -> while (src.read(all, 8192) != -1L) Unit }
        assertArrayEquals(bytes, all.readByteArray())
    }

    @Test(expected = FileNotFoundException::class)
    fun missingItemThrows() {
        source().open("external_primary:image:999")
    }

    @Test fun localIdsRoundTripToMediaStoreUris() {
        assertEquals("content://media/external_primary/images/media/42", LocalIds.uri("external_primary:image:42").toString())
        assertEquals("content://media/1234-abcd/video/media/7", LocalIds.uri("1234-abcd:video:7").toString())
        assertEquals("external_primary:video:7", LocalIds.of("external_primary", LocalIds.VIDEO, 7))
    }
}

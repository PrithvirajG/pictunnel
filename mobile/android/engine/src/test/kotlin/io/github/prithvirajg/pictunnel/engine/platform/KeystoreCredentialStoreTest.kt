package io.github.prithvirajg.pictunnel.engine.platform

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.github.prithvirajg.pictunnel.engine.cred.Credentials
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey

/**
 * Robolectric has no AndroidKeyStore provider, so these tests hand the store a
 * software AES key; the instrumented `keystoreRoundTrip` covers the real one.
 */
@RunWith(RobolectricTestRunner::class)
class KeystoreCredentialStoreTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var file: File
    private val key: SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()

    private val creds =
        Credentials(
            serverId = "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f",
            endpoints = listOf("https://192.168.1.20:8443", "https://photos.example.org"),
            pinSpki = "q83vEjRWeJq83vEjRWeJq83vEjRWeJq83vEjRWeJq80",
            refreshToken = "pt_rt_secret_value",
            deviceId = "01928f3f-1111-7000-8000-0000000d0001",
        )

    @Before fun setUp() {
        file = File(context.noBackupFilesDir, "credentials.bin")
        file.delete()
    }

    private fun store(k: SecretKey = key) = KeystoreCredentialStore(file) { k }

    @Test fun roundTripsAndSurvivesANewInstance() {
        assertNull(store().load())
        store().save(creds)
        assertEquals(creds, store().load())
        val rotated = creds.copy(refreshToken = "pt_rt_next")
        store().save(rotated)
        assertEquals(rotated, store().load())
    }

    @Test fun ciphertextOnlyOnDiskInNoBackupDir() {
        store().save(creds)
        assertEquals(context.noBackupFilesDir.canonicalPath, file.parentFile!!.canonicalPath)
        val raw = String(file.readBytes(), Charsets.ISO_8859_1)
        assertFalse(raw.contains("pt_rt_secret_value"))
        assertFalse(raw.contains("192.168.1.20"))
        // No temp file left behind by the atomic write.
        assertEquals(listOf("credentials.bin"), file.parentFile!!.list()!!.filter { it.startsWith("credentials") })
    }

    @Test fun wipeRemovesThem() {
        store().save(creds)
        store().wipe()
        assertNull(store().load())
        assertFalse(file.exists())
    }

    @Test fun tamperedOrForeignCiphertextLoadsAsNothing() {
        store().save(creds)
        val bytes = file.readBytes()
        bytes[bytes.size - 3] = (bytes[bytes.size - 3].toInt() xor 1).toByte()
        file.writeBytes(bytes)
        assertNull(store().load())

        store().save(creds)
        val otherKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        assertNull(store(otherKey).load())

        file.writeBytes(byteArrayOf(9, 9, 9))
        assertNull(store().load())
    }
}

package io.github.prithvirajg.pictunnel.engine.platform

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import io.github.prithvirajg.pictunnel.engine.cred.Credentials
import io.github.prithvirajg.pictunnel.engine.model.ItemKind
import io.github.prithvirajg.pictunnel.engine.model.ItemState
import io.github.prithvirajg.pictunnel.engine.model.PairRole
import io.github.prithvirajg.pictunnel.engine.store.EngineDb
import io.github.prithvirajg.pictunnel.engine.store.HashCacheEntity
import io.github.prithvirajg.pictunnel.engine.store.ItemEntity
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File
import javax.crypto.KeyGenerator

@RunWith(RobolectricTestRunner::class)
class PlatformReviewFixesTest {
    private val context: Context get() = ApplicationProvider.getApplicationContext()
    private lateinit var db: EngineDb

    @Before fun setUp() {
        db = Room.inMemoryDatabaseBuilder(context, EngineDb::class.java).allowMainThreadQueries().build()
    }

    @After fun tearDown() = db.close()

    private fun row(
        id: String,
        state: ItemState,
    ) = ItemEntity(
        localId = id, sha256 = "a".repeat(64), size = 10, modifiedAtMs = 1, takenAtMs = 1, mime = "image/jpeg",
        kind = ItemKind.PHOTO, pairRole = PairRole.PRIMARY, pairLocalId = null, stackKey = null, state = state,
        attempts = 2, nextAttemptAtMs = null, uploadId = "up", uploadUrl = "/api/v1/uploads/up", uploadOffset = 4,
        assetId = null, lastError = null, filename = "$id.jpg",
    )

    // ---- ACCESS_MEDIA_LOCATION (review fix 2) -----------------------------------

    @Test fun mediaLocationIsRequestedOnEveryApiLevel() {
        for (sdk in listOf(29, 32, 33, 34, 36)) {
            assertTrue("API $sdk", MediaPermissions.required(sdk).contains(Manifest.permission.ACCESS_MEDIA_LOCATION))
        }
        assertTrue(MediaPermissions.required(34).contains(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED))
    }

    @Test fun locationGrantChangeRehashesWhatIsNotBackedUp() =
        runBlocking {
            var granted = false
            val guard = OriginalBytesGuard(db) { granted }
            db.items().upsertAll(listOf(row("hashed", ItemState.Hashed), row("uploading", ItemState.Uploading), row("done", ItemState.BackedUp)))
            listOf("hashed", "uploading", "done").forEach { db.hashCache().put(HashCacheEntity(it, 1, 10, "a".repeat(64))) }

            guard.check() // first run only records the state
            assertEquals(ItemState.Hashed, db.items().get("hashed")!!.state)

            granted = true // the user granted location access: the bytes now include EXIF location
            guard.check()
            for (id in listOf("hashed", "uploading")) {
                val it = db.items().get(id)!!
                assertEquals(ItemState.Discovered, it.state)
                assertNull(it.sha256)
                assertNull(it.uploadUrl)
                assertEquals(0, it.attempts)
                assertNull(db.hashCache().lookup(id, 1, 10))
            }
            assertEquals(ItemState.BackedUp, db.items().get("done")!!.state)
            assertEquals("a".repeat(64), db.hashCache().lookup("done", 1, 10))

            // No change, no reset.
            db.items().upsert(row("hashed", ItemState.Hashed))
            guard.check()
            assertEquals(ItemState.Hashed, db.items().get("hashed")!!.state)
        }

    // ---- MediaStoreDeleter (M1) ---------------------------------------------------

    @Test fun declinedDeleteRequestConfirmsNothingEvenIfItemsVanished() =
        runBlocking {
            val provider = FakeMediaProvider.install()
            val a = provider.add(bytes = ByteArray(1))
            val sender = PendingIntent.getActivity(context, 0, Intent("x"), PendingIntent.FLAG_IMMUTABLE).intentSender
            val deleter =
                MediaStoreDeleter(context, launcher = {
                    provider.remove(a) // deleted by something else meanwhile
                    false
                }, sdkInt = 34, requestFactory = { sender })
            assertEquals(emptySet<String>(), deleter.delete(listOf("external_primary:image:$a")))
        }

    // ---- KeystoreCredentialStore (M2) ---------------------------------------------

    @Test fun transientKeystoreFailureIsNotTreatedAsUnpaired() {
        val file = File(context.noBackupFilesDir, "credentials-m2.bin").apply { delete() }
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        KeystoreCredentialStore(file) { key }.save(Credentials("s", listOf("https://h"), "", "rt", "d"))
        val flaky = KeystoreCredentialStore(file) { throw java.security.ProviderException("keystore busy") }
        try {
            flaky.load()
            throw AssertionError("expected the Keystore failure to propagate")
        } catch (e: java.security.ProviderException) {
            assertEquals("keystore busy", e.message)
        }
        // A tampered file still means "pair again".
        file.writeBytes(byteArrayOf(1, 12) + ByteArray(40))
        assertNull(KeystoreCredentialStore(file) { key }.load())
    }
}

package io.github.prithvirajg.pictunnel.engine.platform

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import io.github.prithvirajg.pictunnel.engine.cred.CredentialStore
import io.github.prithvirajg.pictunnel.engine.cred.Credentials
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Credentials (M§4.4) encrypted with AES-256-GCM under a key that never leaves
 * the AndroidKeyStore; only ciphertext is on disk, in a `noBackupFilesDir`
 * file, so it is never part of a cloud or device-transfer backup. Writes are
 * atomic ([AtomicFile]: temp file, fsync, rename), so a crash mid-rotation
 * keeps either the old or the new refresh token, never a torn file.
 *
 * File layout: version (1 byte), IV length (1 byte), IV, ciphertext+tag. The
 * associated data binds the ciphertext to this purpose and version.
 *
 * Anything that cannot be decrypted (key lost after a restore to a new
 * device, a tampered file) loads as no credentials: the app pairs again.
 */
class KeystoreCredentialStore(
    file: File,
    private val key: () -> SecretKey = { keystoreKey(DEFAULT_ALIAS) },
) : CredentialStore {
    private val atomic = AtomicFile(file)

    @Serializable
    private data class Stored(
        val serverId: String,
        val endpoints: List<String>,
        val pinSpki: String,
        val refreshToken: String,
        val deviceId: String,
    )

    @Synchronized override fun load(): Credentials? {
        val bytes =
            try {
                atomic.readFully()
            } catch (_: java.io.FileNotFoundException) {
                return null
            }
        return try {
            val plain = decrypt(bytes)
            val s = json.decodeFromString(Stored.serializer(), String(plain, Charsets.UTF_8))
            Credentials(s.serverId, s.endpoints, s.pinSpki, s.refreshToken, s.deviceId)
        } catch (e: Exception) {
            // Only "these credentials are unrecoverable" means pair again; a transient
            // Keystore failure must not look like being unpaired.
            if (unrecoverable(e)) null else throw e
        }
    }

    @Synchronized override fun save(c: Credentials) {
        val plain =
            json
                .encodeToString(Stored.serializer(), Stored(c.serverId, c.endpoints, c.pinSpki, c.refreshToken, c.deviceId))
                .toByteArray(Charsets.UTF_8)
        val sealed = encrypt(plain)
        val out = atomic.startWrite()
        try {
            out.write(sealed)
            atomic.finishWrite(out)
        } catch (e: Exception) {
            atomic.failWrite(out)
            throw e
        }
    }

    @Synchronized override fun wipe() {
        atomic.delete()
    }

    private fun unrecoverable(e: Exception): Boolean =
        e is javax.crypto.AEADBadTagException || // tampered, or encrypted under another (lost) key
            e is android.security.keystore.KeyPermanentlyInvalidatedException ||
            e is java.security.UnrecoverableKeyException ||
            e is BadFormatException ||
            e is kotlinx.serialization.SerializationException

    private class BadFormatException(
        message: String,
    ) : Exception(message)

    private fun encrypt(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        // The Keystore picks the IV (caller-provided IVs are refused for GCM keys by default).
        cipher.init(Cipher.ENCRYPT_MODE, key())
        cipher.updateAAD(AAD)
        val body = cipher.doFinal(plain)
        val iv = cipher.iv
        return ByteArrayOutputStream().apply {
            write(VERSION.toInt())
            write(iv.size)
            write(iv)
            write(body)
        }.toByteArray()
    }

    private fun decrypt(bytes: ByteArray): ByteArray {
        if (bytes.size <= 2 || bytes[0] != VERSION) throw BadFormatException("unknown credential file format")
        val ivLen = bytes[1].toInt() and 0xff
        if (ivLen !in 12..16 || bytes.size <= 2 + ivLen) throw BadFormatException("corrupt credential file")
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, bytes, 2, ivLen))
        cipher.updateAAD(AAD)
        return cipher.doFinal(bytes, 2 + ivLen, bytes.size - 2 - ivLen)
    }

    companion object {
        const val DEFAULT_ALIAS = "pictunnel.credentials.v1"
        const val FILE_NAME = "credentials.bin"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val TAG_BITS = 128
        private const val VERSION: Byte = 1
        private val AAD = "pictunnel.credentials.v1".toByteArray()
        private val json = Json { ignoreUnknownKeys = true }

        /** The store the app uses: ciphertext in `noBackupFilesDir`, key in the AndroidKeyStore. */
        fun create(context: Context): KeystoreCredentialStore = KeystoreCredentialStore(File(context.noBackupFilesDir, FILE_NAME))

        /** The AES-256-GCM key under [alias], created on first use. No user authentication: workers use it in the background. */
        @Synchronized
        fun keystoreKey(alias: String): SecretKey {
            val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            (ks.getKey(alias, null) as? SecretKey)?.let { return it }
            val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            gen.init(
                KeyGenParameterSpec
                    .Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setRandomizedEncryptionRequired(true)
                    .build(),
            )
            return gen.generateKey()
        }
    }
}

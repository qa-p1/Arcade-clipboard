package dev.arcade.clipboard.mobile

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Native identity provider called by Rust through JNI. No private key is stored in preferences. */
object CoreIdentityStore {
    private val lock = Any()
    private val profilePattern = Regex("identity-v1-[0-9a-f]{64}")

    @JvmStatic external fun nativeInitialize(context: Context): Boolean

    fun install(context: Context) {
        System.loadLibrary("arcade_core")
        check(nativeInitialize(context.applicationContext)) { "Could not initialize Android secure storage." }
    }

    @JvmStatic
    fun load(context: Context, profile: String): ByteArray? = synchronized(lock) {
        val file = identityFile(context, profile)
        if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return@synchronized null
        val envelope = file.openRead().use { input ->
            val value = input.readBytes()
            require(value.size == 1 + 12 + 149 + 16) { "Stored identity is invalid." }
            value
        }
        require(envelope[0].toInt() == 1) { "Unsupported stored identity version." }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(profile, create = false), GCMParameterSpec(128, envelope.copyOfRange(1, 13)))
        cipher.updateAAD(profile.toByteArray(Charsets.UTF_8))
        cipher.doFinal(envelope.copyOfRange(13, envelope.size)).also {
            require(it.size == 149) { "Stored identity is invalid." }
        }
    }

    @JvmStatic
    fun store(context: Context, profile: String, secret: ByteArray) = synchronized(lock) {
        require(secret.size == 149) { "Invalid identity size." }
        val file = identityFile(context, profile)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key(profile, create = true))
        cipher.updateAAD(profile.toByteArray(Charsets.UTF_8))
        val ciphertext = byteArrayOf(1) + cipher.iv + cipher.doFinal(secret)
        val output = file.startWrite()
        try {
            output.write(ciphertext)
            file.finishWrite(output)
        } catch (error: Throwable) {
            file.failWrite(output)
            throw error
        }
    }

    private fun identityFile(context: Context, profile: String): AtomicFile {
        require(profilePattern.matches(profile)) { "Invalid identity profile." }
        val directory = File(context.noBackupFilesDir, "core-identities-v1")
        check(directory.isDirectory || directory.mkdirs()) { "Could not create protected identity storage." }
        return AtomicFile(File(directory, "$profile.enc"))
    }

    private fun key(profile: String, create: Boolean): SecretKey {
        val alias = "dev.arcade.clipboard.core.$profile"
        val keystore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = keystore.getKey(alias, null) as? SecretKey
        if (existing != null) return existing
        check(create) { "The Android Keystore identity key is missing." }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        val spec = KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .setRandomizedEncryptionRequired(true)
            .apply { if (Build.VERSION.SDK_INT >= 28) setUnlockedDeviceRequired(true) }
            .build()
        generator.init(spec)
        return generator.generateKey()
    }
}

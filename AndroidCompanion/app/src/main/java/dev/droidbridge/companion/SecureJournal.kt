package dev.droidbridge.companion

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.FileOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Atomic bounded encrypted journal. A corrupt existing journal fails closed. */
class SecureJournal(context: Context, name: String, private val limit: Int = 1_048_576) {
    private val file = File(context.filesDir, "$name.enc")
    private fun key(): SecretKey = synchronized(keyLock) {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("droidbridge.journals.v1", null) as? SecretKey)?.let { return@synchronized it }
        KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("droidbridge.journals.v1", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    companion object { private val keyLock = Any() }
    @Synchronized fun read(): String? {
        if (!file.exists()) return null
        require(file.length() in 28L..(limit + 28L))
        val data = file.readBytes()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data.copyOfRange(0, 12)))
        return cipher.doFinal(data.copyOfRange(12, data.size)).toString(Charsets.UTF_8)
    }
    @Synchronized fun write(json: String) {
        val data = json.toByteArray(Charsets.UTF_8); require(data.size <= limit)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        val temporary = File(file.parentFile, "${file.name}.tmp")
        FileOutputStream(temporary).use { it.write(cipher.iv + cipher.doFinal(data)); it.fd.sync() }
        check(temporary.renameTo(file))
    }
}

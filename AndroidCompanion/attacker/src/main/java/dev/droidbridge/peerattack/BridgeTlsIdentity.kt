package dev.droidbridge.peerattack

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Principal
import java.security.PrivateKey
import java.security.SecureRandom
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.X509ExtendedKeyManager
import javax.security.auth.x500.X500Principal

/** Installation-stable TLS identity. Existing invalid identities fail closed; never rotate silently. */
object BridgeTlsIdentity {
    private const val ALIAS = "peerattack.server.tls.v1"
    private val identityLock = Any()
    @Volatile private var appFiles: java.io.File? = null
    fun configure(context: android.content.Context) { synchronized(identityLock) { appFiles = context.applicationContext.filesDir } }
    private fun atomic(file: java.io.File, bytes: ByteArray) {
        val temporary = java.io.File(file.parentFile, file.name + ".tmp")
        java.io.FileOutputStream(temporary).use { it.write(bytes); it.fd.sync() }
        check(temporary.renameTo(file))
        val descriptor = android.system.Os.open(file.parentFile!!.absolutePath, android.system.OsConstants.O_RDONLY, 0)
        try { require(android.system.OsConstants.S_ISDIR(android.system.Os.fstat(descriptor).st_mode)); android.system.Os.fsync(descriptor) } finally { android.system.Os.close(descriptor) }
    }
    private data class Material(val privateKey: PrivateKey, val certificate: X509Certificate)
    private fun entry(): Material = synchronized(identityLock) {
        val files = appFiles ?: throw IllegalStateException("TLS context not configured")
        val stateFile = java.io.File(files, "tls-identity-state.json")
        val leafFile = java.io.File(files, "tls-server-leaf.der")
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val state = if (stateFile.exists()) {
            require(stateFile.isFile && stateFile.length() <= 2048)
            org.json.JSONObject(stateFile.readText())
        } else null
        if (state == null) {
            require(!store.containsAlias(ALIAS) && !leafFile.exists()) { "Unexpected TLS identity; explicit reset required" }
            atomic(stateFile, org.json.JSONObject().put("status", "initializing").toString().toByteArray())
        }
        val initializing = state == null || state.getString("status") == "initializing"
        if (!store.containsAlias(ALIAS)) {
            require(initializing) { "TLS private key missing; explicit reset required" }
            val now = System.currentTimeMillis()
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, "AndroidKeyStore").apply {
                initialize(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                    .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                    // Conscrypt signs a precomputed TLS transcript digest via NONEwithECDSA.
                    .setDigests(KeyProperties.DIGEST_NONE, KeyProperties.DIGEST_SHA256)
                    .setCertificateSubject(X500Principal("CN=DroidBridge Initializing Key"))
                    .setCertificateSerialNumber(BigInteger(128, SecureRandom()).setBit(127))
                    .setCertificateNotBefore(Date(now - 86_400_000L))
                    .setCertificateNotAfter(Date(now + 730L * 86_400_000L))
                    .setUserAuthenticationRequired(false).build())
            }.generateKeyPair()
        }
        val keyEntry = store.getEntry(ALIAS, null) as? KeyStore.PrivateKeyEntry ?: throw IllegalStateException("TLS identity unavailable")
        require(keyEntry.privateKey.encoded == null) { "TLS private key must remain non-exportable" }
        val leaf = if (leafFile.exists()) {
            require(leafFile.isFile && leafFile.length() in 1..16384)
            java.security.cert.CertificateFactory.getInstance("X.509").generateCertificate(leafFile.inputStream().use { java.io.ByteArrayInputStream(it.readBytes()) }) as X509Certificate
        } else {
            require(initializing) { "TLS certificate missing; explicit reset required" }
            TlsLeafCertificate.create(keyEntry.certificate.publicKey, keyEntry.privateKey).also { atomic(leafFile, it.encoded) }
        }
        TlsLeafCertificate.validate(leaf, keyEntry.certificate.publicKey)
        val pin = ProtocolRules.hash(leaf.encoded)
        if (initializing) atomic(stateFile, org.json.JSONObject().put("status", "ready").put("server_pin", pin).toString().toByteArray())
        else require(state.getString("status") == "ready" && ProtocolRules.secureEqual(state.getString("server_pin"), pin)) { "TLS identity changed; explicit reset required" }
        Material(keyEntry.privateKey, leaf)
    }
    fun certificate(): X509Certificate = entry().certificate
    fun serverPin(): String = ProtocolRules.hash(certificate().encoded)
    fun serverSocket(): SSLServerSocket {
        val material = entry()
        val chain = arrayOf(material.certificate)
        val manager = object : X509ExtendedKeyManager() {
            override fun getClientAliases(keyType: String?, issuers: Array<out Principal>?) = null
            override fun chooseClientAlias(keyType: Array<out String>?, issuers: Array<out Principal>?, socket: Socket?) = null
            override fun getServerAliases(keyType: String?, issuers: Array<out Principal>?) = if (keyType == "EC") arrayOf(ALIAS) else null
            override fun chooseServerAlias(keyType: String?, issuers: Array<out Principal>?, socket: Socket?) = if (keyType == "EC") ALIAS else null
            override fun chooseEngineServerAlias(keyType: String?, issuers: Array<out Principal>?, engine: SSLEngine?) = if (keyType == "EC") ALIAS else null
            override fun getCertificateChain(alias: String?) = if (alias == ALIAS) chain else null
            override fun getPrivateKey(alias: String?): PrivateKey? = if (alias == ALIAS) material.privateKey else null
        }
        val context = SSLContext.getInstance("TLS").apply { init(arrayOf(manager), null, SecureRandom()) }
        return (context.serverSocketFactory.createServerSocket() as SSLServerSocket).apply {
            enabledProtocols = supportedProtocols.filter { it in setOf("TLSv1.2", "TLSv1.3") }.toTypedArray()
            require(enabledProtocols.isNotEmpty())
            val permitted = setOf("TLS_AES_128_GCM_SHA256", "TLS_AES_256_GCM_SHA384", "TLS_CHACHA20_POLY1305_SHA256",
                "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256", "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384", "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256")
            enabledCipherSuites = supportedCipherSuites.filter { it in permitted }.toTypedArray()
            require(enabledCipherSuites.isNotEmpty()); needClientAuth = false
            bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 37841), 8)
        }
    }
}

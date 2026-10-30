package dev.droidbridge.companion

import java.net.URL
import java.security.SecureRandom
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/** Test-only exact pin client; no permissive trust manager or HTTP fallback. */
object PinnedTestClient {
    fun context(pin: String = BridgeTlsIdentity.serverPin()): SSLContext {
        require(pin.matches(Regex("[a-f0-9]{64}")))
        val manager = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = throw java.security.cert.CertificateException("Client trust unsupported")
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                val leaf = chain?.singleOrNull() ?: throw java.security.cert.CertificateException("Invalid chain")
                if (!ProtocolRules.secureEqual(ProtocolRules.hash(leaf.encoded), pin)) throw java.security.cert.CertificateException("Pin mismatch")
                leaf.checkValidity(); leaf.verify(leaf.publicKey)
            }
        }
        return SSLContext.getInstance("TLS").apply { init(null, arrayOf(manager), SecureRandom()) }
    }
    fun open(path: String, pin: String = BridgeTlsIdentity.serverPin()): HttpsURLConnection = (URL("https://127.0.0.1:37841$path").openConnection() as HttpsURLConnection).apply {
        sslSocketFactory = context(pin).socketFactory
        hostnameVerifier = javax.net.ssl.HostnameVerifier { host, _ -> host == "127.0.0.1" }
    }
    fun socket(protocol: String? = null): SSLSocket = (context().socketFactory.createSocket("127.0.0.1", 37841) as SSLSocket).apply { if (protocol != null) enabledProtocols = arrayOf(protocol); soTimeout = 5000; startHandshake() }
}

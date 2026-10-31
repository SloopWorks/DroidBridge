package dev.droidbridge.companion

import java.io.ByteArrayInputStream
import java.math.BigInteger
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Signature
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import javax.security.auth.x500.X500Principal

/** Fixed X.509v3 server profile, not a general ASN.1 encoder. All extension/OID bytes are constants. */
internal object TlsLeafCertificate {
    private fun node(tag: Int, bytes: ByteArray): ByteArray {
        require(bytes.size <= 16384)
        val length = when { bytes.size < 128 -> byteArrayOf(bytes.size.toByte()); bytes.size < 256 -> byteArrayOf(0x81.toByte(), bytes.size.toByte()); else -> byteArrayOf(0x82.toByte(), (bytes.size shr 8).toByte(), bytes.size.toByte()) }
        return byteArrayOf(tag.toByte()) + length + bytes
    }
    private fun sequence(vararg parts: ByteArray) = node(0x30, parts.fold(byteArrayOf()) { a, b -> a + b })
    private fun oid(vararg bytes: Int) = node(0x06, bytes.map { it.toByte() }.toByteArray())
    private val algorithm = sequence(oid(0x2a,0x86,0x48,0xce,0x3d,0x04,0x03,0x02)) // ecdsa-with-SHA256
    private fun utc(date: Date) = node(0x17, SimpleDateFormat("yyMMddHHmmss'Z'", Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.format(date).toByteArray(Charsets.US_ASCII))
    private fun extension(oid: ByteArray, content: ByteArray, critical: Boolean = false) = if (critical) sequence(oid, byteArrayOf(0x01,0x01,0xff.toByte()), node(0x04, content)) else sequence(oid, node(0x04, content))
    fun create(publicKey: PublicKey, privateKey: PrivateKey, now: Long = System.currentTimeMillis()): X509Certificate {
        require(publicKey.algorithm == "EC" && publicKey.encoded.size <= 1024)
        val name = X500Principal("CN=DroidBridge Companion Installation").encoded
        val serial = BigInteger(128, SecureRandom()).setBit(127)
        val extensions = sequence(
            extension(oid(0x55,0x1d,0x0f), byteArrayOf(0x03,0x02,0x07,0x80.toByte()), true), // digitalSignature
            extension(oid(0x55,0x1d,0x13), sequence(), true), // CA=false
            extension(oid(0x55,0x1d,0x25), sequence(oid(0x2b,0x06,0x01,0x05,0x05,0x07,0x03,0x01))), // serverAuth
            extension(oid(0x55,0x1d,0x11), sequence(node(0x87, byteArrayOf(127,0,0,1)))) // iPAddress SAN
        )
        val tbs = sequence(node(0xa0, byteArrayOf(0x02,0x01,0x02)), node(0x02, serial.toByteArray()), algorithm, name,
            sequence(utc(Date(now - 86_400_000L)), utc(Date(now + 730L * 86_400_000L))), name, publicKey.encoded, node(0xa3, extensions))
        val signature = Signature.getInstance("SHA256withECDSA").apply { initSign(privateKey); update(tbs) }.sign()
        val der = sequence(tbs, algorithm, node(0x03, byteArrayOf(0) + signature))
        val leaf = CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(der)) as X509Certificate
        validate(leaf, publicKey)
        return leaf
    }
    fun validate(leaf: X509Certificate, expectedPublic: PublicKey) {
        require(leaf.encoded.size <= 16384 && java.security.MessageDigest.isEqual(leaf.publicKey.encoded, expectedPublic.encoded))
        leaf.checkValidity(); leaf.verify(expectedPublic)
        require(leaf.version == 3 && leaf.subjectX500Principal == leaf.issuerX500Principal)
        require(leaf.basicConstraints == -1 && leaf.keyUsage?.get(0) == true)
        require(leaf.extendedKeyUsage == listOf("1.3.6.1.5.5.7.3.1"))
        require(leaf.subjectAlternativeNames?.any { it[0] == 7 && it[1] == "127.0.0.1" } == true)
        require(leaf.sigAlgName.equals("SHA256withECDSA", true))
        require(leaf.publicKey.algorithm == "EC" && (leaf.publicKey as java.security.interfaces.ECPublicKey).params.curve.field.fieldSize == 256)
    }
}

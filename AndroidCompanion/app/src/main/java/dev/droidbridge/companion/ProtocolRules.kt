package dev.droidbridge.companion

import java.security.MessageDigest
import java.security.SecureRandom

object ProtocolRules {
    const val MAX_JSON = 262_144
    const val MAX_HEADERS = 16_384
    const val MAX_FILE = 50L * 1024 * 1024
    const val MAX_CHUNK = 65_536
    fun token(): String = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(32).also { SecureRandom().nextBytes(it) })
    fun secureEqual(a: String, b: String): Boolean = MessageDigest.isEqual(a.toByteArray(Charsets.UTF_8), b.toByteArray(Charsets.UTF_8))
    fun hash(data: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }
    fun identifier(value: String) = value.matches(Regex("[A-Za-z0-9._-]{1,128}"))
    fun packageName(value: String) = value.matches(Regex("[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+")) && value.length <= 255
    const val MAX_CATALOG_LABEL_SCALARS = 256
    const val MAX_CATALOG_ACTIVITY_UTF8 = 512

    /** Wire labels count Unicode scalars, not UTF-16 units, graphemes or bytes. */
    fun catalogLabel(value: String): String {
        val result = StringBuilder(minOf(value.length, MAX_CATALOG_LABEL_SCALARS * 2))
        var index = 0
        var scalars = 0
        while (index < value.length && scalars < MAX_CATALOG_LABEL_SCALARS) {
            val first = value[index++]
            when {
                Character.isHighSurrogate(first) -> {
                    if (index < value.length && Character.isLowSurrogate(value[index])) {
                        result.append(first).append(value[index++])
                    } else result.append('\uFFFD')
                }
                Character.isLowSurrogate(first) -> result.append('\uFFFD')
                else -> result.append(first)
            }
            scalars++
        }
        return result.toString()
    }

    /** Optional wire metadata: never truncate an Android component identity. */
    fun catalogActivityName(value: String): String? {
        if (value.length > MAX_CATALOG_ACTIVITY_UTF8) return null
        var index = 0
        while (index < value.length) {
            val first = value[index++]
            if (Character.isHighSurrogate(first)) {
                if (index == value.length || !Character.isLowSurrogate(value[index++])) return null
            } else if (Character.isLowSurrogate(first)) return null
        }
        return value.takeIf { it.toByteArray(Charsets.UTF_8).size <= MAX_CATALOG_ACTIVITY_UTF8 }
    }
    fun safeName(value: String): String = value.substringAfterLast('/').substringAfterLast('\\').replace(Regex("[\\p{Cntrl}]"), "").take(120).ifBlank { "Shared file" }
    fun validateJSON(value: String) {
        var nodes = 0
        val reader = android.util.JsonReader(java.io.StringReader(value)).apply { isLenient = false }
        fun walk(depth: Int) {
            require(depth <= 16 && ++nodes <= 8192) { "JSON complexity exceeds limit" }
            when (reader.peek()) {
                android.util.JsonToken.BEGIN_OBJECT -> {
                    reader.beginObject(); val keys = HashSet<String>()
                    while (reader.hasNext()) { val key = reader.nextName(); require(keys.add(key)); walk(depth + 1) }
                    reader.endObject()
                }
                android.util.JsonToken.BEGIN_ARRAY -> { reader.beginArray(); while (reader.hasNext()) walk(depth + 1); reader.endArray() }
                android.util.JsonToken.STRING, android.util.JsonToken.NUMBER -> reader.nextString()
                android.util.JsonToken.BOOLEAN -> reader.nextBoolean()
                android.util.JsonToken.NULL -> reader.nextNull()
                else -> throw IllegalArgumentException("Invalid JSON token")
            }
        }
        reader.use { walk(0); require(it.peek() == android.util.JsonToken.END_DOCUMENT) }
    }
    fun contentLength(headers: Map<String, String>): Int {
        require(headers["transfer-encoding"] == null) { "Transfer encoding unsupported" }
        val raw = headers["content-length"] ?: return 0
        require(raw.matches(Regex("[0-9]{1,8}"))) { "Invalid content length" }
        return raw.toInt().also { if (it !in 0..MAX_JSON) throw BridgeFailure(413, "payload_too_large") }
    }
}

class BridgeFailure(val status: Int, val code: String) : IllegalArgumentException(code)

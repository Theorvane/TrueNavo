package com.truedash.truedash.tlstrust

/// Shared, deliberately strict validation for the two TLS-trust bridges.
/// Every accepted request is an exact key set: an unexpected key, a missing
/// key, or a wrong protocol version is rejected rather than coerced.
internal object BridgeProtocol {
    const val PROTOCOL_VERSION = 1
    const val MAXIMUM_DER_BYTES = 64 * 1024
    // A real TrueNAS `core.get_methods` reply is several megabytes. This stays a
    // hard bound; an oversized frame closes the session rather than buffering.
    const val MAXIMUM_FRAME_BYTES = 16 * 1024 * 1024
    const val ABSENT_ID = "00000000000000000000000000000000"

    private val ID_PATTERN = Regex("^[0-9a-f]{32}$")
    private val UPPER_HEX_DIGEST = Regex("^[0-9A-F]{64}$")
    private val LABEL = Regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")

    fun validId(value: Any?): Boolean = value is String && ID_PATTERN.matches(value)

    fun arguments(raw: Any?, expectedKeys: Set<String>): Map<String, Any?>? {
        if (raw !is Map<*, *>) return null
        val values = mutableMapOf<String, Any?>()
        for ((key, value) in raw) {
            if (key !is String || values.containsKey(key)) return null
            values[key] = value
        }
        if (values.keys != expectedKeys) return null
        if (values["protocolVersion"] != PROTOCOL_VERSION) return null
        return values
    }

    /// Reads the single-identifier request shape shared by both cancel methods.
    fun identifier(raw: Any?, key: String): String? {
        val values = arguments(raw, setOf("protocolVersion", key)) ?: return null
        val id = values[key]
        return if (validId(id)) id as String else null
    }

    fun port(value: Any?): Int? = (value as? Int)?.takeIf { it in 1..65535 }

    fun digest(value: Any?): ByteArray? {
        if (value !is String || !UPPER_HEX_DIGEST.matches(value)) return null
        return ByteArray(32) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    /// Accepts only the bracketless canonical authority forms Dart produces:
    /// a lowercase DNS name, a dotted IPv4 literal, or an IPv6 literal whose
    /// canonical text round-trips unchanged.
    fun host(value: Any?): String? {
        if (value !is String || value.isEmpty() || value.length > 253) return null
        if (value != value.lowercase()) return null
        if (value.any { it.code <= 0x20 || it.code >= 0x7f }) return null
        if (value.any { it == '/' || it == '@' || it == '%' || it == '[' || it == ']' }) return null
        if (value.contains(':')) return if (InetAddresses.canonicalIpv6(value) == value) value else null
        if (value.all { it.isDigit() || it == '.' }) {
            val parts = value.split(".")
            if (parts.size != 4) return null
            return if (parts.all { part -> part.toIntOrNull()?.let { it in 0..255 && it.toString() == part } == true }) {
                value
            } else {
                null
            }
        }
        val labels = value.split(".")
        return if (labels.all { LABEL.matches(it) }) value else null
    }

    fun path(value: Any?): String? {
        if (value !is String || value.isEmpty() || value.first() != '/') return null
        if (value.any { it.code <= 0x20 || it.code >= 0x7f }) return null
        if (value.any { it == '?' || it == '#' || it == '@' || it == '\\' || it == '%' }) return null
        val segments = value.split("/")
        return if (segments.none { it == "." || it == ".." }) value else null
    }

    fun failure(code: String, operationId: String?): Map<String, Any> = mapOf(
        "protocolVersion" to PROTOCOL_VERSION,
        "operationId" to (operationId ?: ABSENT_ID),
        "failureCode" to code,
    )

    fun sessionAck(sessionId: String): Map<String, Any> = mapOf(
        "protocolVersion" to PROTOCOL_VERSION,
        "sessionId" to sessionId,
    )

    fun sessionClosed(sessionId: String?): Map<String, Any> = mapOf(
        "protocolVersion" to PROTOCOL_VERSION,
        "sessionId" to (sessionId ?: ABSENT_ID),
        "closed" to true,
    )

    /// Digest comparison must not leak position information through timing.
    fun constantTimeEquals(left: ByteArray, right: ByteArray): Boolean {
        if (left.size != right.size) return false
        var difference = 0
        for (index in left.indices) difference = difference or (left[index].toInt() xor right[index].toInt())
        return difference == 0
    }
}

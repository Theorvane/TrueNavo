package com.truenavo.truenavo.tlstrust

/// A dependency-free IPv6 literal canonicalizer that mirrors the Dart
/// authority normalizer. The bridge accepts a literal only when its canonical
/// text equals the input, so an expanded or otherwise noncanonical spelling can
/// never become a different pin authority during URL construction.
internal object InetAddresses {
    private val GROUP = Regex("^[0-9a-fA-F]{1,4}$")

    fun canonicalIpv6(value: String): String? {
        val compression = value.indexOf("::")
        if (compression != value.lastIndexOf("::")) return null
        val compressed = compression >= 0
        val before = if (compressed && compression > 0) {
            value.substring(0, compression).split(":")
        } else {
            emptyList()
        }
        val after = if (compressed && compression + 2 < value.length) {
            value.substring(compression + 2).split(":")
        } else {
            emptyList()
        }
        val parts = if (compressed) before + after else value.split(":")
        val groups = mutableListOf<Int>()
        for ((index, part) in parts.withIndex()) {
            if (part.isEmpty()) return null
            if (part.contains('.')) {
                if (index != parts.size - 1) return null
                val octets = part.split(".")
                if (octets.size != 4) return null
                val values = octets.map { octet ->
                    octet.toIntOrNull()?.takeIf { it in 0..255 && it.toString() == octet } ?: return null
                }
                groups.add((values[0] shl 8) or values[1])
                groups.add((values[2] shl 8) or values[3])
            } else {
                if (!GROUP.matches(part)) return null
                groups.add(part.toInt(16))
            }
        }
        if (compressed) {
            if (groups.size >= 8) return null
            repeat(8 - groups.size) { groups.add(before.size, 0) }
        } else if (groups.size != 8) {
            return null
        }
        return format(groups)
    }

    private fun format(groups: List<Int>): String {
        var runStart = -1
        var runLength = 0
        var index = 0
        while (index < groups.size) {
            if (groups[index] != 0) {
                index++
                continue
            }
            val start = index
            while (index < groups.size && groups[index] == 0) index++
            val length = index - start
            if (length > runLength && length >= 2) {
                runStart = start
                runLength = length
            }
        }
        val text = groups.map { Integer.toHexString(it) }
        if (runStart < 0) return text.joinToString(":")
        val head = text.take(runStart).joinToString(":")
        val tail = text.drop(runStart + runLength).joinToString(":")
        return when {
            head.isEmpty() -> "::$tail"
            tail.isEmpty() -> "$head::"
            else -> "$head::$tail"
        }
    }
}

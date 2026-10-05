package com.truenavo.truenavo.tlstrust

/// A tiny standard-alphabet Base64 encoder. The bridge encodes DER bytes only,
/// and the Dart boundary re-encodes what it decodes to reject any noncanonical
/// spelling, so this deliberately emits exactly one padded canonical form.
internal object Base64Codec {
    private const val ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    fun encode(bytes: ByteArray): String {
        val out = StringBuilder((bytes.size + 2) / 3 * 4)
        var index = 0
        while (index + 2 < bytes.size) {
            val chunk = (bytes[index].toInt() and 0xff shl 16) or
                (bytes[index + 1].toInt() and 0xff shl 8) or
                (bytes[index + 2].toInt() and 0xff)
            out.append(ALPHABET[chunk ushr 18 and 0x3f])
            out.append(ALPHABET[chunk ushr 12 and 0x3f])
            out.append(ALPHABET[chunk ushr 6 and 0x3f])
            out.append(ALPHABET[chunk and 0x3f])
            index += 3
        }
        when (bytes.size - index) {
            1 -> {
                val chunk = bytes[index].toInt() and 0xff shl 16
                out.append(ALPHABET[chunk ushr 18 and 0x3f])
                out.append(ALPHABET[chunk ushr 12 and 0x3f])
                out.append("==")
            }
            2 -> {
                val chunk = (bytes[index].toInt() and 0xff shl 16) or
                    (bytes[index + 1].toInt() and 0xff shl 8)
                out.append(ALPHABET[chunk ushr 18 and 0x3f])
                out.append(ALPHABET[chunk ushr 12 and 0x3f])
                out.append(ALPHABET[chunk ushr 6 and 0x3f])
                out.append('=')
            }
        }
        return out.toString()
    }
}

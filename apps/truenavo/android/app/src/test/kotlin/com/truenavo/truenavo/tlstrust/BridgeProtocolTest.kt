package com.truenavo.truenavo.tlstrust

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BridgeProtocolTest {
    @Test
    fun `arguments require the exact key set and protocol version`() {
        val expected = setOf("protocolVersion", "operationId")
        assertNull(BridgeProtocol.arguments(null, expected))
        assertNull(BridgeProtocol.arguments("not a map", expected))
        assertNull(BridgeProtocol.arguments(mapOf("protocolVersion" to 1), expected))
        assertNull(
            BridgeProtocol.arguments(
                mapOf("protocolVersion" to 2, "operationId" to "a".repeat(32)),
                expected,
            ),
        )
        assertNull(
            BridgeProtocol.arguments(
                mapOf("protocolVersion" to 1, "operationId" to "a".repeat(32), "extra" to 1),
                expected,
            ),
        )
        assertNull(
            BridgeProtocol.arguments(
                mapOf(1 to "keyed by a non-string", "protocolVersion" to 1),
                expected,
            ),
        )
        val values = BridgeProtocol.arguments(
            mapOf("protocolVersion" to 1, "operationId" to "0".repeat(32)),
            expected,
        )
        assertEquals("0".repeat(32), values?.get("operationId"))
    }

    @Test
    fun `operation identifiers are lowercase 32 hex characters`() {
        assertTrue(BridgeProtocol.validId("0123456789abcdef0123456789abcdef"))
        assertFalse(BridgeProtocol.validId("0123456789ABCDEF0123456789ABCDEF"))
        assertFalse(BridgeProtocol.validId("0123456789abcdef0123456789abcde"))
        assertFalse(BridgeProtocol.validId(42))
        assertFalse(BridgeProtocol.validId(null))
    }

    @Test
    fun `digests are exactly uppercase 64 hex characters`() {
        assertNull(BridgeProtocol.digest("a".repeat(64)))
        assertNull(BridgeProtocol.digest("A".repeat(63)))
        assertNull(BridgeProtocol.digest(null))
        val digest = BridgeProtocol.digest("FF" + "00".repeat(31))
        assertEquals(32, digest?.size)
        assertEquals(-1, digest?.get(0)?.toInt())
        assertEquals(0, digest?.get(1)?.toInt())
    }

    @Test
    fun `hosts accept only canonical bracketless authority forms`() {
        assertEquals("nas.example.test", BridgeProtocol.host("nas.example.test"))
        assertEquals("192.168.0.123", BridgeProtocol.host("192.168.0.123"))
        assertEquals("2001:db8::1", BridgeProtocol.host("2001:db8::1"))
        assertNull(BridgeProtocol.host("NAS.example.test"))
        assertNull(BridgeProtocol.host("nas.example.test/path"))
        assertNull(BridgeProtocol.host("user@nas.example.test"))
        assertNull(BridgeProtocol.host("[2001:db8::1]"))
        assertNull(BridgeProtocol.host("2001:0db8:0000:0000:0000:0000:0000:0001"))
        assertNull(BridgeProtocol.host("192.168.0.256"))
        assertNull(BridgeProtocol.host("192.168.00.1"))
        assertNull(BridgeProtocol.host("-nas.example.test"))
        assertNull(BridgeProtocol.host(""))
    }

    @Test
    fun `paths reject traversal, queries, and escapes`() {
        assertEquals("/api/current", BridgeProtocol.path("/api/current"))
        assertEquals("/", BridgeProtocol.path("/"))
        assertNull(BridgeProtocol.path("api/current"))
        assertNull(BridgeProtocol.path("/api/../admin"))
        assertNull(BridgeProtocol.path("/api?query=1"))
        assertNull(BridgeProtocol.path("/api#fragment"))
        assertNull(BridgeProtocol.path("/api%2f"))
        assertNull(BridgeProtocol.path("/api current"))
    }

    @Test
    fun `ports must be inside the valid range`() {
        assertEquals(443, BridgeProtocol.port(443))
        assertNull(BridgeProtocol.port(0))
        assertNull(BridgeProtocol.port(65536))
        assertNull(BridgeProtocol.port("443"))
    }

    @Test
    fun `constant time comparison still distinguishes content and length`() {
        assertTrue(BridgeProtocol.constantTimeEquals(byteArrayOf(1, 2, 3), byteArrayOf(1, 2, 3)))
        assertFalse(BridgeProtocol.constantTimeEquals(byteArrayOf(1, 2, 3), byteArrayOf(1, 2, 4)))
        assertFalse(BridgeProtocol.constantTimeEquals(byteArrayOf(1, 2), byteArrayOf(1, 2, 3)))
    }

    @Test
    fun `base64 matches the canonical padded encoding`() {
        assertEquals("", Base64Codec.encode(byteArrayOf()))
        assertEquals("AA==", Base64Codec.encode(byteArrayOf(0)))
        assertEquals("//8=", Base64Codec.encode(byteArrayOf(-1, -1)))
        assertEquals("AAEC", Base64Codec.encode(byteArrayOf(0, 1, 2)))
        assertEquals("TWFu", Base64Codec.encode("Man".toByteArray()))
    }
}

package com.sloki9637.truenavo.tlstrust

import java.util.Date
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PinnedRpcCoreTest {
    private val operationId = "0123456789abcdef0123456789abcdef"
    private val sessionId = "fedcba9876543210fedcba9876543210"
    private val digest = "AB".repeat(32)

    private fun connectRequest(
        id: String = operationId,
        host: Any? = "nas.example.test",
        port: Any? = 443,
        path: Any? = "/api/current",
        pin: Any? = digest,
    ) = mapOf(
        "protocolVersion" to 1,
        "operationId" to id,
        "host" to host,
        "port" to port,
        "rpcPath" to path,
        "leafDerSha256" to pin,
    )

    @Test
    fun `an opened socket yields exactly one session identifier`() {
        val transport = FakeTransport()
        val core = core(transport)
        val responses = mutableListOf<Map<String, Any>>()
        core.connect(connectRequest()) { responses.add(it) }
        assertTrue(responses.isEmpty())
        transport.events!!.onOpen()
        assertEquals(
            mapOf(
                "protocolVersion" to 1,
                "operationId" to operationId,
                "sessionId" to sessionId,
            ),
            responses.single(),
        )
        transport.events!!.onOpen()
        assertEquals(1, responses.size)
    }

    @Test
    fun `an open delivered before the handle is returned still opens a session`() {
        // OkHttp dispatches callbacks on its own threads, so `onOpen` can land
        // while `newWebSocket` has not returned yet. Dropping that open left the
        // caller waiting for its timeout instead of connecting.
        val transport = RacingTransport()
        val core = core(transport)
        val responses = mutableListOf<Map<String, Any>>()
        core.connect(connectRequest()) { responses.add(it) }
        transport.opened.await(2, java.util.concurrent.TimeUnit.SECONDS)
        for (attempt in 0 until 200) {
            if (responses.isNotEmpty()) break
            Thread.sleep(10)
        }
        assertEquals(
            mapOf(
                "protocolVersion" to 1,
                "operationId" to operationId,
                "sessionId" to sessionId,
            ),
            responses.single(),
        )

        // The session must be usable, which proves it holds the real handle.
        val sent = mutableListOf<Map<String, Any>>()
        core.send(
            mapOf("protocolVersion" to 1, "sessionId" to sessionId, "frame" to "{}"),
        ) { sent.add(it) }
        assertEquals(mapOf("protocolVersion" to 1, "sessionId" to sessionId), sent.single())
        assertEquals(listOf("{}"), transport.socket.sent)
    }

    @Test
    fun `no frame is sent before the socket opens`() {
        val transport = FakeTransport()
        val core = core(transport)
        core.connect(connectRequest()) {}
        val sent = mutableListOf<Map<String, Any>>()
        core.send(
            mapOf("protocolVersion" to 1, "sessionId" to sessionId, "frame" to "{}"),
        ) { sent.add(it) }
        assertEquals(true, sent.single()["closed"])
        assertTrue(transport.socket.sent.isEmpty())
    }

    @Test
    fun `malformed connect requests never reach the transport`() {
        val transport = FakeTransport()
        val core = core(transport)
        for (raw in listOf<Any?>(
            null,
            connectRequest(id = "nope"),
            connectRequest(host = "NAS.example.test"),
            connectRequest(port = 70000),
            connectRequest(path = "/api/../admin"),
            connectRequest(pin = digest.lowercase()),
            connectRequest() + ("extra" to 1),
        )) {
            val responses = mutableListOf<Map<String, Any>>()
            core.connect(raw) { responses.add(it) }
            assertEquals("malformedCertificate", responses.single()["failureCode"])
        }
        assertNull(transport.events)
    }

    @Test
    fun `a boundary failure code is reported instead of a transport error`() {
        for (code in listOf(
            "pinMismatch",
            "hostnameMismatch",
            "expiredCertificate",
            "notYetValidCertificate",
            "malformedCertificate",
            "pinnedReconnectFailed",
        )) {
            val transport = FakeTransport()
            val core = core(transport)
            val responses = mutableListOf<Map<String, Any>>()
            core.connect(connectRequest()) { responses.add(it) }
            transport.events!!.onFailure(code)
            assertEquals(code, responses.single()["failureCode"])
            assertEquals(operationId, responses.single()["operationId"])
        }
    }

    @Test
    fun `frames are queued and delivered to a single pending receive`() {
        val transport = FakeTransport()
        val core = core(transport)
        core.connect(connectRequest()) {}
        transport.events!!.onOpen()
        transport.events!!.onFrame("first")
        val received = mutableListOf<Map<String, Any>>()
        core.receive(mapOf("protocolVersion" to 1, "sessionId" to sessionId)) { received.add(it) }
        assertEquals("first", received.single()["frame"])

        val pending = mutableListOf<Map<String, Any>>()
        core.receive(mapOf("protocolVersion" to 1, "sessionId" to sessionId)) { pending.add(it) }
        assertTrue(pending.isEmpty())
        val concurrent = mutableListOf<Map<String, Any>>()
        core.receive(mapOf("protocolVersion" to 1, "sessionId" to sessionId)) { concurrent.add(it) }
        assertEquals(true, concurrent.single()["closed"])
        transport.events!!.onFrame("second")
        assertEquals("second", pending.single()["frame"])
    }

    @Test
    fun `send acknowledges only while the session is live`() {
        val transport = FakeTransport()
        val core = core(transport)
        core.connect(connectRequest()) {}
        transport.events!!.onOpen()
        val sent = mutableListOf<Map<String, Any>>()
        core.send(
            mapOf("protocolVersion" to 1, "sessionId" to sessionId, "frame" to "{}"),
        ) { sent.add(it) }
        assertEquals(mapOf("protocolVersion" to 1, "sessionId" to sessionId), sent.single())
        assertEquals(listOf("{}"), transport.socket.sent)

        core.close(mapOf("protocolVersion" to 1, "sessionId" to sessionId)) {}
        val afterClose = mutableListOf<Map<String, Any>>()
        core.send(
            mapOf("protocolVersion" to 1, "sessionId" to sessionId, "frame" to "{}"),
        ) { afterClose.add(it) }
        assertEquals(true, afterClose.single()["closed"])
        assertTrue(transport.socket.closed)
    }

    @Test
    fun `an oversized frame is refused without reaching the socket`() {
        val transport = FakeTransport()
        val core = core(transport)
        core.connect(connectRequest()) {}
        transport.events!!.onOpen()
        val sent = mutableListOf<Map<String, Any>>()
        core.send(
            mapOf(
                "protocolVersion" to 1,
                "sessionId" to sessionId,
                "frame" to "a".repeat(BridgeProtocol.MAXIMUM_FRAME_BYTES + 1),
            ),
        ) { sent.add(it) }
        assertEquals(true, sent.single()["closed"])
        assertTrue(transport.socket.sent.isEmpty())
    }

    @Test
    fun `a closed socket settles a pending receive`() {
        val transport = FakeTransport()
        val core = core(transport)
        core.connect(connectRequest()) {}
        transport.events!!.onOpen()
        val pending = mutableListOf<Map<String, Any>>()
        core.receive(mapOf("protocolVersion" to 1, "sessionId" to sessionId)) { pending.add(it) }
        transport.events!!.onClosed()
        assertEquals(true, pending.single()["closed"])
        assertEquals(sessionId, pending.single()["sessionId"])
    }

    @Test
    fun `cancel closes the socket and settles the connect exactly once`() {
        val transport = FakeTransport()
        val core = core(transport)
        val responses = mutableListOf<Map<String, Any>>()
        core.connect(connectRequest()) { responses.add(it) }
        val acknowledgements = mutableListOf<Map<String, Any>>()
        core.cancel(
            mapOf("protocolVersion" to 1, "operationId" to operationId),
        ) { acknowledgements.add(it) }
        assertEquals("cancelled", responses.single()["failureCode"])
        assertEquals("cancelled", acknowledgements.single()["failureCode"])
        assertTrue(transport.socket.closed)
        transport.events!!.onOpen()
        assertEquals(1, responses.size)
    }

    @Test
    fun `a duplicate operation identifier never replaces a live connect`() {
        val transport = FakeTransport()
        val core = core(transport)
        core.connect(connectRequest()) {}
        val second = mutableListOf<Map<String, Any>>()
        core.connect(connectRequest()) { second.add(it) }
        assertEquals("pinnedReconnectFailed", second.single()["failureCode"])
    }

    private fun core(transport: PinnedTransportFactory) = PinnedRpcCore(
        transports = transport,
        now = { Date(0) },
        newSessionId = { sessionId },
    )

    private class FakeTransport : PinnedTransportFactory {
        val socket = FakeSocket()
        var events: PinnedWebSocketEvents? = null

        override fun connect(
            request: PinnedRpcRequest,
            verifyDate: Date,
            events: PinnedWebSocketEvents,
        ): PinnedWebSocket {
            this.events = events
            return socket
        }
    }

    /// Raises `onOpen` from another thread before `connect` returns its handle.
    private class RacingTransport : PinnedTransportFactory {
        val socket = FakeSocket()
        val opened = java.util.concurrent.CountDownLatch(1)

        override fun connect(
            request: PinnedRpcRequest,
            verifyDate: Date,
            events: PinnedWebSocketEvents,
        ): PinnedWebSocket {
            Thread {
                events.onOpen()
                opened.countDown()
            }.start()
            Thread.sleep(50)
            return socket
        }
    }

    private class FakeSocket : PinnedWebSocket {
        val sent = mutableListOf<String>()
        var closed = false
        override fun send(frame: String): Boolean {
            if (closed) return false
            sent.add(frame)
            return true
        }

        override fun close() { closed = true }
    }
}

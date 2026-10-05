package com.truenavo.truenavo.tlstrust

import java.io.Closeable
import java.util.concurrent.Executor
import java.util.concurrent.ExecutorService
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PresentedLeafProbeCoreTest {
    private val operationId = "0123456789abcdef0123456789abcdef"

    private fun request(
        id: String = operationId,
        host: Any? = "nas.example.test",
        port: Any? = 443,
    ) = mapOf(
        "protocolVersion" to 1,
        "operationId" to id,
        "host" to host,
        "port" to port,
    )

    @Test
    fun `a captured leaf is returned with its measured platform trust`() {
        val core = core(PresentedLeafHandshake { _, _, register ->
            register(Closeable {})
            LeafCapture.Captured(byteArrayOf(1, 2, 3), platformTrustPassed = true)
        })
        val response = capture(core, request())
        assertEquals(
            mapOf(
                "protocolVersion" to 1,
                "operationId" to operationId,
                "leafDerBase64" to "AQID",
                "platformTrust" to "passed",
            ),
            response,
        )
    }

    @Test
    fun `an unmeasured platform trust is reported as a failed evaluation`() {
        val core = core(PresentedLeafHandshake { _, _, _ ->
            LeafCapture.Captured(byteArrayOf(9), platformTrustPassed = false)
        })
        assertEquals("didNotPass", capture(core, request())["platformTrust"])
    }

    @Test
    fun `the probe receives only the authority and exposes no transport`() {
        var observedHost: String? = null
        var observedPort: Int? = null
        val core = core(PresentedLeafHandshake { host, port, _ ->
            observedHost = host
            observedPort = port
            LeafCapture.Failed
        })
        capture(core, request(host = "nas.example.test", port = 8443))
        assertEquals("nas.example.test", observedHost)
        assertEquals(8443, observedPort)
    }

    @Test
    fun `malformed requests fail closed without starting a handshake`() {
        var started = false
        val core = core(PresentedLeafHandshake { _, _, _ ->
            started = true
            LeafCapture.Failed
        })
        for (raw in listOf<Any?>(
            null,
            request(id = "not-an-id"),
            request(host = "NAS.example.test"),
            request(host = 42),
            request(port = 0),
            request() + ("extra" to 1),
        )) {
            assertEquals("captureFailed", capture(core, raw)["failureCode"])
        }
        assertTrue(!started)
    }

    @Test
    fun `an oversized or empty leaf is refused`() {
        for (der in listOf(ByteArray(0), ByteArray(BridgeProtocol.MAXIMUM_DER_BYTES + 1))) {
            val core = core(PresentedLeafHandshake { _, _, _ ->
                LeafCapture.Captured(der, platformTrustPassed = false)
            })
            assertEquals("captureFailed", capture(core, request())["failureCode"])
        }
    }

    @Test
    fun `a handshake failure is reported as a capture failure`() {
        val core = core(PresentedLeafHandshake { _, _, _ -> throw IllegalStateException("boom") })
        assertEquals("captureFailed", capture(core, request())["failureCode"])
    }

    @Test
    fun `cancel closes the socket and settles the capture exactly once`() {
        var closed = false
        var registerResult: Boolean? = null
        val gate = java.util.concurrent.CountDownLatch(1)
        val core = core(PresentedLeafHandshake { _, _, register ->
            register(Closeable { closed = true })
            gate.await(2, TimeUnit.SECONDS)
            registerResult = register(Closeable {})
            LeafCapture.Captured(byteArrayOf(1), platformTrustPassed = true)
        }, direct = false)
        val responses = mutableListOf<Map<String, Any>>()
        core.capture(request()) { responses.add(it) }
        Thread.sleep(50)
        val acknowledgements = mutableListOf<Map<String, Any>>()
        core.cancel(
            mapOf("protocolVersion" to 1, "operationId" to operationId),
        ) { acknowledgements.add(it) }
        gate.countDown()
        Thread.sleep(200)
        assertTrue(closed)
        assertEquals(false, registerResult)
        assertEquals(1, responses.size)
        assertEquals("cancelled", responses.single()["failureCode"])
        assertEquals("cancelled", acknowledgements.single()["failureCode"])
    }

    @Test
    fun `cancel acknowledges an unknown operation without inventing state`() {
        val core = core(PresentedLeafHandshake { _, _, _ -> LeafCapture.Failed })
        val response = mutableListOf<Map<String, Any>>()
        core.cancel(mapOf("protocolVersion" to 1, "operationId" to operationId)) { response.add(it) }
        assertEquals("cancelled", response.single()["failureCode"])
        assertEquals(operationId, response.single()["operationId"])
    }

    @Test
    fun `a malformed cancel is rejected`() {
        val core = core(PresentedLeafHandshake { _, _, _ -> LeafCapture.Failed })
        val response = mutableListOf<Map<String, Any>>()
        core.cancel(mapOf("protocolVersion" to 1, "operationId" to "short")) { response.add(it) }
        assertEquals("captureFailed", response.single()["failureCode"])
        assertEquals(BridgeProtocol.ABSENT_ID, response.single()["operationId"])
    }

    @Test
    fun `a duplicate operation identifier never replaces a live capture`() {
        val gate = java.util.concurrent.CountDownLatch(1)
        val core = core(PresentedLeafHandshake { _, _, _ ->
            gate.await(2, TimeUnit.SECONDS)
            LeafCapture.Captured(byteArrayOf(1), platformTrustPassed = false)
        }, direct = false)
        val first = mutableListOf<Map<String, Any>>()
        core.capture(request()) { first.add(it) }
        Thread.sleep(50)
        val second = mutableListOf<Map<String, Any>>()
        core.capture(request()) { second.add(it) }
        assertEquals("captureFailed", second.single()["failureCode"])
        gate.countDown()
        Thread.sleep(200)
        assertNull(first.single()["failureCode"])
    }

    private fun capture(core: PresentedLeafProbeCore, raw: Any?): Map<String, Any> {
        val responses = mutableListOf<Map<String, Any>>()
        core.capture(raw) { responses.add(it) }
        assertEquals(1, responses.size)
        return responses.single()
    }

    private fun core(handshake: PresentedLeafHandshake, direct: Boolean = true) =
        PresentedLeafProbeCore(
            handshake = handshake,
            executor = if (direct) DirectExecutorService() else newExecutor(),
        )

    private fun newExecutor(): ExecutorService =
        java.util.concurrent.Executors.newCachedThreadPool()
}

/// Runs work inline so a completion is observable without waiting.
private class DirectExecutorService :
    java.util.concurrent.AbstractExecutorService(),
    Executor {
    private var stopped = false
    override fun execute(command: Runnable) = command.run()
    override fun shutdown() { stopped = true }
    override fun shutdownNow(): MutableList<Runnable> { stopped = true; return mutableListOf() }
    override fun isShutdown(): Boolean = stopped
    override fun isTerminated(): Boolean = stopped
    override fun awaitTermination(timeout: Long, unit: TimeUnit): Boolean = true
}

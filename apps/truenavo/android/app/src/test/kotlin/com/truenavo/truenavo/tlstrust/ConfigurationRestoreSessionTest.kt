package com.truenavo.truenavo.tlstrust

import java.util.Date
import org.junit.Assert.*
import org.junit.Test

class ConfigurationRestoreSessionTest {
    private val session = "b".repeat(32)
    private fun args(bytes: ByteArray) = mapOf("protocolVersion" to 1, "sessionId" to session, "token" to "S".repeat(64), "bytes" to bytes)
    private class Socket : PinnedWebSocket, ConfigurationRestorePinnedSocket {
        var callback: ((Long?) -> Unit)? = null
        var bytes: ByteArray? = null
        var uploads = 0; var cancelled = false
        override fun send(frame: String) = true
        override fun close() { cancelled = true }
        override fun upload(token: String, bytes: ByteArray, completion: (Long?) -> Unit): PinnedDownloadHandle {
            uploads++; this.bytes = bytes; callback = completion
            return PinnedDownloadHandle { cancelled = true }
        }
        fun finish(job: Long?) { bytes?.fill(0); callback!!(job) }
    }
    private fun ready(socket: Socket): PinnedRpcCore {
        var events: PinnedWebSocketEvents? = null
        val core = PinnedRpcCore(PinnedTransportFactory { _, _, handler -> events = handler; socket }, { Date() }, { session })
        core.connect(mapOf("protocolVersion" to 1, "operationId" to "a".repeat(32), "host" to "nas.example.test",
            "port" to 443, "rpcPath" to "/api/current", "leafDerSha256" to "AB".repeat(32))) {}
        events!!.onOpen(); return core
    }
    @Test fun `unknown session and extra authority method fields never upload and clear input`() {
        val socket = Socket(); val core = ready(socket)
        for (extra in listOf(mapOf("sessionId" to "c".repeat(32)), mapOf("host" to "evil.invalid"),
            mapOf("method" to "other.method"), mapOf("token" to "bad\n"))) {
            val bytes = byteArrayOf(1)
            core.uploadConfigurationRestore(args(bytes) + extra) { assertEquals(true, it["closed"]) }
            assertEquals(0.toByte(), bytes.single())
        }
        assertEquals(0, socket.uploads)
    }
    @Test fun `one session transfer admits a single integer job only`() {
        val socket = Socket(); val core = ready(socket); val result = mutableListOf<Map<String, Any>>()
        val bytes = byteArrayOf(1)
        core.uploadConfigurationRestore(args(bytes)) { result.add(it) }
        val duplicate = byteArrayOf(2)
        core.uploadConfigurationRestore(args(duplicate)) { assertEquals(true, it["closed"]) }
        assertEquals(0.toByte(), duplicate.single()); assertEquals(1.toByte(), bytes.single())
        assertEquals(1, socket.uploads); socket.finish(71)
        assertEquals(mapOf("protocolVersion" to 1, "sessionId" to session, "jobId" to 71L), result.single())
        assertEquals(0.toByte(), bytes.single())
    }
    @Test fun `close cancels pending upload but writer owns buffer until its last use`() {
        val socket = Socket(); val core = ready(socket); val result = mutableListOf<Map<String, Any>>()
        val bytes = byteArrayOf(1)
        core.uploadConfigurationRestore(args(bytes)) { result.add(it) }
        core.close(mapOf("protocolVersion" to 1, "sessionId" to session)) {}
        assertTrue(socket.cancelled); assertEquals(true, result.single()["closed"])
        assertEquals(1.toByte(), bytes.single()) // no unsafe concurrent wipe of writer memory
        socket.finish(71)
        assertEquals(0.toByte(), bytes.single()); assertEquals(1, result.size)
    }
    @Test fun `malformed native receipt never becomes acceptance`() {
        for (job in listOf(null, 0L, -1L, 9007199254740992L)) {
            val socket = Socket(); val core = ready(socket)
            core.uploadConfigurationRestore(args(byteArrayOf(1))) { assertEquals(true, it["closed"]) }
            socket.finish(job)
        }
    }
}

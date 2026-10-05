package com.sloki9637.truenavo.tlstrust

import java.util.Date
import org.junit.Assert.*
import org.junit.Test

class ConfigurationBackupSessionTest {
    private val session = "b".repeat(32)
    private val args = mapOf("protocolVersion" to 1, "sessionId" to session, "jobId" to 71,
        "relativeUrl" to "/_download/71?auth_token=${"S".repeat(64)}")
    private class Socket : PinnedWebSocket, ConfigurationBackupPinnedSocket {
        var callback: ((ByteArray?) -> Unit)? = null
        var downloads = 0; var cancelled = false
        override fun send(frame: String) = true
        override fun close() { cancelled = true }
        override fun download(request: ConfigurationBackupDownloadRequest, completion: (ByteArray?) -> Unit): PinnedDownloadHandle {
            downloads++; callback = completion
            return PinnedDownloadHandle { cancelled = true }
        }
    }
    private fun ready(socket: Socket): PinnedRpcCore {
        var events: PinnedWebSocketEvents? = null
        val core = PinnedRpcCore(PinnedTransportFactory { _, _, handler -> events = handler; socket }, { Date() }, { session })
        core.connect(mapOf("protocolVersion" to 1, "operationId" to "a".repeat(32), "host" to "nas.example.test",
            "port" to 443, "rpcPath" to "/api/current", "leafDerSha256" to "AB".repeat(32))) {}
        events!!.onOpen()
        return core
    }
    @Test fun `only existing session same job strict allowlist reaches downloader`() {
        val socket = Socket(); val core = ready(socket)
        for (invalid in listOf(args + ("sessionId" to "c".repeat(32)), args + ("host" to "evil.invalid"),
            args + ("jobId" to 72), args + ("relativeUrl" to "https://evil.invalid/token"))) {
            core.downloadConfigurationBackup(invalid) { assertEquals(true, it["closed"]) }
        }
        assertEquals(0, socket.downloads)
        val output = mutableListOf<Map<String, Any>>()
        core.downloadConfigurationBackup(args) { output.add(it) }
        core.downloadConfigurationBackup(args) { assertEquals(true, it["closed"]) }
        assertEquals(1, socket.downloads)
        socket.callback!!(byteArrayOf(1, 2))
        assertEquals(session, output.single()["sessionId"]); assertEquals(71L, output.single()["jobId"])
        assertArrayEquals(byteArrayOf(1, 2), output.single()["bytes"] as ByteArray)
    }
    @Test fun `closing original session cancels download and zeroes late bytes exactly once`() {
        val socket = Socket(); val core = ready(socket); val output = mutableListOf<Map<String, Any>>()
        core.downloadConfigurationBackup(args) { output.add(it) }
        core.close(mapOf("protocolVersion" to 1, "sessionId" to session)) {}
        assertTrue(socket.cancelled); assertEquals(true, output.single()["closed"])
        val late = byteArrayOf(9, 8)
        socket.callback!!(late)
        assertArrayEquals(ByteArray(2), late); assertEquals(1, output.size)
        core.downloadConfigurationBackup(args) { assertEquals(true, it["closed"]) }
        assertEquals(1, socket.downloads)
    }
    @Test fun `runner detach closes session download and rejects empty or oversized payloads`() {
        for (bytes in listOf(ByteArray(0), ByteArray(MAXIMUM_CONFIGURATION_BACKUP_BYTES + 1) { 1 })) {
            val socket = Socket(); val core = ready(socket)
            core.downloadConfigurationBackup(args) { assertEquals(true, it["closed"]) }
            socket.callback!!(bytes); assertTrue(bytes.all { it == 0.toByte() })
            core.closeAll(); assertTrue(socket.cancelled)
        }
    }
}

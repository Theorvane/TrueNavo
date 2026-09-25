package com.trueraid.trueraid.configurationrestore

import java.io.ByteArrayInputStream
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class ConfigurationRestoreFileCoreTest {
    private val args = mapOf("protocolVersion" to 1, "operationId" to "12345678-1")
    private val uri = "content://synthetic.provider/PRIVATE-FILENAME"
    private class Target(val bytes: ByteArray = byteArrayOf(1, 2, 3)) : ConfigurationRestoreReadTarget {
        var opens = 0; var closed = false; var cancelled = false
        override fun open(): InputStream { opens++; return object : ByteArrayInputStream(bytes) { override fun close() { closed = true; super.close() } } }
        override fun cancel() { cancelled = true }
    }
    @Test fun `picker has no file read until second phase and no URI leaves native`() {
        var picker: ((String?) -> Unit)? = null
        val target = Target(); val chosen = mutableListOf<Map<String, Any>>()
        val core = ConfigurationRestoreFileCore({ picker = it }, { target }, { it() })
        core.chooseDocument(args) { chosen.add(it) }; assertEquals(0, target.opens)
        picker!!(uri); assertEquals("selected", chosen.single()["status"]); assertFalse(chosen.toString().contains("PRIVATE"))
        val result = mutableListOf<Map<String, Any>>()
        core.readSelectedDocument(args) { result.add(it) }
        assertEquals("read", result.single()["status"]); assertEquals(4, result.single().size)
        assertArrayEquals(byteArrayOf(1, 2, 3), result.single()["bytes"] as ByteArray); assertTrue(target.closed)
        core.readSelectedDocument(args) { assertEquals("failed", it["status"]) }; assertEquals(1, target.opens)
    }
    @Test fun `arbitrary URI fields and noncontent selections never open reader`() {
        val target = Target()
        val core = ConfigurationRestoreFileCore({ it(uri) }, { target }, { it() })
        core.chooseDocument(args + ("uri" to uri)) { assertEquals("failed", it["status"]) }
        core.readSelectedDocument(args + ("uri" to uri)) { assertEquals("failed", it["status"]) }
        assertEquals(0, target.opens)
        for (value in listOf("file:///tmp/private", "https://evil.invalid/file", "content:/missing")) {
            ConfigurationRestoreFileCore({ it(value) }, { target }, { it() }).chooseDocument(args) { assertEquals("failed", it["status"]) }
        }
    }
    @Test fun `cancel while picker open rejects late result without reading`() {
        var picker: ((String?) -> Unit)? = null
        val target = Target(); val result = mutableListOf<Map<String, Any>>()
        val core = ConfigurationRestoreFileCore({ picker = it }, { target }, { it() })
        core.chooseDocument(args) { result.add(it) }; core.cancelDocument(args); picker!!(uri)
        assertEquals("cancelled", result.single()["status"]); assertEquals(0, target.opens)
        core.readSelectedDocument(args) { assertEquals("failed", it["status"]) }
    }
    @Test fun `empty and oversized files produce no bytes`() {
        for (bytes in listOf(ByteArray(0), ByteArray(ConfigurationRestoreFileCore.MAX_BYTES + 1) { 1 })) {
            val target = Target(bytes); val core = ConfigurationRestoreFileCore({ it(uri) }, { target }, { it() })
            core.chooseDocument(args) {}; core.readSelectedDocument(args) { assertEquals("failed", it["status"]); assertFalse(it.containsKey("bytes")) }
            assertTrue(target.closed)
        }
    }
    @Test fun `maximum file is bounded and read successfully`() {
        val target = Target(ByteArray(ConfigurationRestoreFileCore.MAX_BYTES) { 1 })
        val core = ConfigurationRestoreFileCore({ it(uri) }, { target }, { it() })
        core.chooseDocument(args) {}; core.readSelectedDocument(args) { assertEquals(ConfigurationRestoreFileCore.MAX_BYTES, (it["bytes"] as ByteArray).size) }
    }
    @Test fun `provider errors remain sanitized`() {
        val core = ConfigurationRestoreFileCore({ it(uri) }, { object : ConfigurationRestoreReadTarget {
            override fun open(): InputStream = throw IllegalStateException("PRIVATE-FILENAME")
            override fun cancel() {}
        } }, { it() })
        core.chooseDocument(args) {}; core.readSelectedDocument(args) { assertEquals("failed", it["status"]); assertFalse(it.toString().contains("PRIVATE")) }
    }
    @Test fun `cancel blocked read settles once and prevents unbounded workers`() {
        val started = CountDownLatch(1); val release = CountDownLatch(1); val ended = CountDownLatch(1)
        val core = ConfigurationRestoreFileCore({ it(uri) }, { object : ConfigurationRestoreReadTarget {
            override fun open(): InputStream { started.countDown(); release.await(3, TimeUnit.SECONDS); return ByteArrayInputStream(byteArrayOf(1)) }
            override fun cancel() {}
        } }, { task -> Thread { try { task() } finally { ended.countDown() } }.start() })
        val result = mutableListOf<Map<String, Any>>()
        core.chooseDocument(args) {}; core.readSelectedDocument(args) { result.add(it) }
        assertTrue(started.await(2, TimeUnit.SECONDS)); core.cancelDocument(args)
        assertEquals("cancelled", result.single()["status"])
        core.chooseDocument(args) { assertEquals("failed", it["status"]) }
        release.countDown(); assertTrue(ended.await(2, TimeUnit.SECONDS)); assertEquals(1, result.size)
    }
}

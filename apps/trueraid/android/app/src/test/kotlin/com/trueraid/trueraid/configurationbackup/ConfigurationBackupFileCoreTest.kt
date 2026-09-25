package com.trueraid.trueraid.configurationbackup

import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class ConfigurationBackupFileCoreTest {
    private val id = "12345678-1"
    private val base = mapOf("protocolVersion" to 1, "operationId" to id)
    private val uri = "content://synthetic.provider/documents/one"
    private class Target : ConfigurationBackupWriteTarget {
        val buffer = ByteArrayOutputStream()
        var opens = 0; var cancelled = false
        override fun open(): OutputStream { opens++; return buffer }
        override fun cancel() { cancelled = true }
    }

    @Test fun `picker receives filename only then one use selection writes and clears bytes`() {
        var picker: ((String?) -> Unit)? = null
        val target = Target()
        val core = ConfigurationBackupFileCore({ name, callback -> assertEquals("truenas-configuration.db", name); picker = callback },
            { selected -> assertEquals(uri, selected); target }, { it() })
        val chosen = mutableListOf<Map<String, Any>>()
        core.chooseDocument(base + ("filename" to "truenas-configuration.db")) { chosen.add(it) }
        assertEquals(0, target.opens); assertTrue(chosen.isEmpty())
        picker!!(uri)
        assertEquals(setOf("protocolVersion", "operationId", "status"), chosen.single().keys)
        assertEquals("selected", chosen.single()["status"])
        val bytes = byteArrayOf(1, 2, 3)
        val written = mutableListOf<Map<String, Any>>()
        core.writeSelectedDocument(base + ("bytes" to bytes)) { written.add(it) }
        assertEquals("saved", written.single()["status"])
        assertArrayEquals(byteArrayOf(1, 2, 3), target.buffer.toByteArray())
        assertArrayEquals(ByteArray(3), bytes)
        core.writeSelectedDocument(base + ("bytes" to byteArrayOf(4))) { assertEquals("failed", it["status"]) }
        assertEquals(1, target.opens)
    }

    @Test fun `invalid filename cannot launch picker and arbitrary URI cannot be written`() {
        var launched = 0
        val target = Target()
        val core = ConfigurationBackupFileCore({ _, _ -> launched++ }, { target }, { it() })
        for (filename in listOf("../config.db", "private.db", "truenas-configuration.db\n")) {
            core.chooseDocument(base + ("filename" to filename)) { assertEquals("failed", it["status"]) }
        }
        assertEquals(0, launched)
        val bytes = byteArrayOf(1)
        core.writeSelectedDocument(base + mapOf("bytes" to bytes, "uri" to uri)) { assertEquals("failed", it["status"]) }
        assertEquals(0, target.opens); assertEquals(0.toByte(), bytes.single())
    }

    @Test fun `cancel during picker clears lease and late selection never writes`() {
        var picker: ((String?) -> Unit)? = null
        val core = ConfigurationBackupFileCore({ _, callback -> picker = callback }, { throw AssertionError() }, { it() })
        val chosen = mutableListOf<Map<String, Any>>()
        core.chooseDocument(base + ("filename" to "truenas-configuration.tar")) { chosen.add(it) }
        core.cancelDocument(base)
        assertEquals("cancelled", chosen.single()["status"])
        picker!!(uri)
        assertEquals(1, chosen.size)
        val bytes = byteArrayOf(1)
        core.writeSelectedDocument(base + ("bytes" to bytes)) { assertEquals("failed", it["status"]) }
        assertEquals(0.toByte(), bytes.single())
    }

    @Test fun `cancelled and noncontent provider selections never open a writer`() {
        for (selected in listOf(null, "file:///tmp/private", "https://remote.invalid/file", "content:/missing-authority")) {
            val core = ConfigurationBackupFileCore({ _, callback -> callback(selected) }, { throw AssertionError() }, { it() })
            core.chooseDocument(base + ("filename" to "truenas-configuration.db")) {
                assertEquals(if (selected == null) "cancelled" else "failed", it["status"])
            }
        }
    }

    @Test fun `oversized empty and wrong selection writes fail and clear incoming bytes`() {
        val target = Target()
        val core = ConfigurationBackupFileCore({ _, callback -> callback(uri) }, { target }, { it() })
        core.chooseDocument(base + ("filename" to "truenas-configuration.db")) {}
        for (bytes in listOf(ByteArray(0), ByteArray(ConfigurationBackupFileCore.MAX_BYTES + 1) { 1 })) {
            core.writeSelectedDocument(base + ("bytes" to bytes)) { assertEquals("failed", it["status"]) }
            assertTrue(bytes.all { it == 0.toByte() })
        }
        val bytes = byteArrayOf(9)
        core.writeSelectedDocument(base + mapOf("operationId" to "1-2", "bytes" to bytes)) { assertEquals("failed", it["status"]) }
        assertEquals(0, target.opens); assertEquals(0.toByte(), bytes.single())
    }

    @Test fun `provider failure is sanitized and destroys its buffer`() {
        val core = ConfigurationBackupFileCore({ _, callback -> callback(uri) }, { object : ConfigurationBackupWriteTarget {
            override fun open(): OutputStream = throw IllegalStateException("SYNTHETIC-SECRET-ERROR")
            override fun cancel() {}
        } }, { it() })
        core.chooseDocument(base + ("filename" to "truenas-configuration.db")) {}
        val bytes = byteArrayOf(1)
        core.writeSelectedDocument(base + ("bytes" to bytes)) { assertEquals("failed", it["status"]); assertFalse(it.toString().contains("SECRET")) }
        assertEquals(0.toByte(), bytes.single())
    }

    @Test fun `cancelled blocked write settles once and prevents worker accumulation`() {
        val entered = CountDownLatch(1); val unblock = CountDownLatch(1); val ended = CountDownLatch(1)
        val core = ConfigurationBackupFileCore({ _, callback -> callback(uri) }, { object : ConfigurationBackupWriteTarget {
            override fun open(): OutputStream { entered.countDown(); unblock.await(3, TimeUnit.SECONDS); return ByteArrayOutputStream() }
            override fun cancel() {}
        } }, { task -> Thread { try { task() } finally { ended.countDown() } }.start() })
        core.chooseDocument(base + ("filename" to "truenas-configuration.db")) {}
        val bytes = ByteArray(16384) { 1 }; val results = mutableListOf<Map<String, Any>>()
        core.writeSelectedDocument(base + ("bytes" to bytes)) { results.add(it) }
        assertTrue(entered.await(2, TimeUnit.SECONDS)); core.cancelDocument(base)
        assertEquals("cancelled", results.single()["status"]); assertTrue(bytes.all { it == 0.toByte() })
        core.chooseDocument(base + ("filename" to "truenas-configuration.db")) { assertEquals("failed", it["status"]) }
        unblock.countDown(); assertTrue(ended.await(2, TimeUnit.SECONDS)); assertEquals(1, results.size)
    }
}

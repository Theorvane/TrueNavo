package com.truenavo.truenavo.tlstrust

import java.net.InetAddress
import java.security.MessageDigest
import java.util.Date
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okhttp3.Protocol
import org.junit.Assert.*
import org.junit.Test

class ConfigurationBackupDownloaderTest {
    private val token = "S".repeat(64)
    private val download = ConfigurationBackupDownloadRequest.parse(71, "/_download/71?auth_token=$token")!!

    @Test fun `strict relative download grammar never accepts a new authority or job`() {
        for (url in listOf("https://evil.test/_download/71?auth_token=$token", "//evil.test/_download/71?auth_token=$token",
            "/_download/72?auth_token=$token", "/_download/071?auth_token=$token", "/_download/71?auth_token=$token&x=1",
            "/_download/71?auth_token=$token#x", "/_download/71?auth_token=$token\n", "/_download/71?auth_token=%41$token",
            "/_download/71?auth_token=short", "/_download/71?auth_token=${"x".repeat(513)}")) {
            assertNull(ConfigurationBackupDownloadRequest.parse(71, url))
        }
        for (id in listOf<Any>(0, -1, true, 71.0, "71", 9007199254740992L)) {
            assertNull(ConfigurationBackupDownloadRequest.parse(id, "/_download/71?auth_token=$token"))
        }
    }

    @Test fun `verified fresh TLS downloads official chunked response with no cookies`() = server { fixture ->
        fixture.server.enqueue(MockResponse().setChunkedBody("SQLite synthetic", 3).setHeader("Content-Type", "application/octet-stream"))
        val result = fixture.run()
        assertArrayEquals("SQLite synthetic".toByteArray(), result)
        val request = fixture.server.takeRequest(2, TimeUnit.SECONDS)!!
        assertEquals("/_download/71?auth_token=$token", request.path)
        assertEquals("identity", request.getHeader("Accept-Encoding"))
        assertEquals("no-store", request.getHeader("Cache-Control"))
        assertNull(request.getHeader("Authorization")); assertNull(request.getHeader("Cookie"))
        assertEquals(1, fixture.server.requestCount)
    }

    @Test fun `wrong pin sends no HTTP token request`() = server { fixture ->
        assertNull(fixture.run(pin = "AA".repeat(32)))
        assertEquals(0, fixture.server.requestCount)
    }

    @Test fun `HTTP2 body is read without attempting HTTP1 chunk decoding`() {
        val fixture = Fixture(http2 = true)
        try {
            fixture.server.enqueue(MockResponse().setBody("SQLite synthetic"))
            assertArrayEquals("SQLite synthetic".toByteArray(), fixture.run())
        } finally { fixture.server.shutdown() }
    }

    @Test fun `fresh HTTP certificate clock rejects expired leaf before token`() = server { fixture ->
        assertNull(fixture.run(clock = Date(fixture.certificate.certificate.notAfter.time + 1)))
        assertEquals(0, fixture.server.requestCount)
    }

    @Test fun `TLS trust callback refreshes time after request preparation`() = server { fixture ->
        var reads = 0
        assertNull(fixture.run(now = {
            reads++
            if (reads == 1) Date() else Date(fixture.certificate.certificate.notAfter.time + 1)
        }))
        assertTrue(reads >= 2)
        assertEquals(0, fixture.server.requestCount)
    }

    @Test fun `explicit cancellation terminates in flight HTTP without returning bytes`() = server { fixture ->
        fixture.server.enqueue(MockResponse().setBody("sensitive synthetic bytes").setBodyDelay(3, TimeUnit.SECONDS))
        val downloader = OkHttpConfigurationBackupDownloader(fixture.authority())
        val done = CountDownLatch(1); var result: ByteArray? = byteArrayOf(1)
        downloader.start(download) { result = it; done.countDown() }
        assertNotNull(fixture.server.takeRequest(2, TimeUnit.SECONDS))
        downloader.cancel()
        assertTrue(done.await(2, TimeUnit.SECONDS)); assertNull(result)
        assertEquals(1, fixture.server.requestCount)
    }

    @Test fun `redirect is not followed or retried`() = server { fixture ->
        fixture.server.enqueue(MockResponse().setResponseCode(302).setHeader("Location", "https://evil.invalid/steal"))
        assertNull(fixture.run()); assertEquals(1, fixture.server.requestCount)
    }

    @Test fun `nonidentity encoding HTTP errors empty and oversized bodies are rejected`() {
        for (response in listOf(MockResponse().setBody("x").setHeader("Content-Encoding", "gzip"),
            MockResponse().setResponseCode(403).setBody("private detail"), MockResponse().setBody(""),
            MockResponse().setHeader("Content-Length", MAXIMUM_CONFIGURATION_BACKUP_BYTES + 1))) {
            server { fixture -> fixture.server.enqueue(response); assertNull(fixture.run()); assertEquals(1, fixture.server.requestCount) }
        }
    }

    @Test fun `oversized chunked body fails at hard bound`() = server { fixture ->
        fixture.server.enqueue(MockResponse().setChunkedBody("x".repeat(MAXIMUM_CONFIGURATION_BACKUP_BYTES + 1), 8192))
        assertNull(fixture.run())
    }

    @Test fun `bounded call timeout never retries`() = server { fixture ->
        fixture.server.enqueue(MockResponse().setBody("x").setBodyDelay(4, TimeUnit.SECONDS))
        assertNull(fixture.run(timeout = 1)); assertEquals(1, fixture.server.requestCount)
    }

    private fun server(body: (Fixture) -> Unit) {
        val fixture = Fixture()
        try { body(fixture) } finally { fixture.server.shutdown() }
    }
    private inner class Fixture(http2: Boolean = false) {
        val certificate = HeldCertificate.Builder().commonName("synthetic-local-test")
            .validityInterval(System.currentTimeMillis() - 60_000, System.currentTimeMillis() + 60_000).build()
        val server = MockWebServer().apply {
            protocols = if (http2) listOf(Protocol.HTTP_2, Protocol.HTTP_1_1) else listOf(Protocol.HTTP_1_1)
            useHttps(HandshakeCertificates.Builder().heldCertificate(certificate).build().sslSocketFactory(), false)
            start(InetAddress.getByName("127.0.0.1"), 0)
        }
        fun authority(pin: String = MessageDigest.getInstance("SHA-256").digest(certificate.certificate.encoded).joinToString("") { "%02X".format(it) }) = PinnedRpcRequest.parse(mapOf("protocolVersion" to 1, "operationId" to "a".repeat(32),
            "host" to "127.0.0.1", "port" to server.port, "rpcPath" to "/api/current", "leafDerSha256" to pin))!!
        fun run(pin: String = MessageDigest.getInstance("SHA-256").digest(certificate.certificate.encoded).joinToString("") { "%02X".format(it) }, clock: Date = Date(), timeout: Long = 5, now: (() -> Date)? = null): ByteArray? {
            val ready = CountDownLatch(1)
            var result: ByteArray? = null
            OkHttpConfigurationBackupDownloader(authority(pin), now ?: { clock }, timeout).start(download) { result = it; ready.countDown() }
            assertTrue(ready.await(10, TimeUnit.SECONDS))
            return result
        }
    }
}

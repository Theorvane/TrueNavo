package com.truenavo.truenavo.tlstrust

import java.net.InetAddress
import java.security.MessageDigest
import java.util.Date
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.Protocol
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import okio.Buffer
import org.junit.Assert.*
import org.junit.Test

class ConfigurationRestoreUploaderTest {
    private val token = "S".repeat(64)
    private val sample get() = "synthetic-configuration".toByteArray()

    @Test fun `upload sends exact Token auth fixed method and data then one file`() = server { f ->
        f.server.enqueue(MockResponse().setBody("{\"job_id\":71}"))
        val bytes = sample
        assertEquals(71L, f.run(bytes)); assertTrue(bytes.all { it == 0.toByte() })
        val request = f.server.takeRequest(2, TimeUnit.SECONDS)!!
        assertEquals("POST", request.method); assertEquals("/_upload", request.path)
        assertEquals("Token $token", request.getHeader("Authorization"))
        assertEquals("identity", request.getHeader("Accept-Encoding")); assertEquals("no-store", request.getHeader("Cache-Control"))
        assertNull(request.getHeader("Cookie"))
        val body = request.body.readUtf8()
        assertTrue(body.indexOf("name=\"data\"") < body.indexOf("name=\"file\""))
        assertTrue(body.contains("{\"method\":\"config.upload\",\"params\":[]}"))
        assertTrue(body.contains("filename=\"truenas-configuration.db\""))
        assertEquals(1, Regex("name=\"file\"").findAll(body).count())
        assertTrue(body.contains("synthetic-configuration")); assertFalse(body.contains(token))
        assertEquals(1, f.server.requestCount)
    }

    @Test fun `wrong pin sends neither auth header nor configuration body`() = server { f ->
        val bytes = sample
        assertNull(f.run(bytes, pin = "AA".repeat(32))); assertTrue(bytes.all { it == 0.toByte() })
        assertEquals(0, f.server.requestCount)
    }

    @Test fun `TLS checks fresh time at handshake before credential header`() = server { f ->
        var calls = 0
        assertNull(f.run(sample, clock = { if (++calls == 1) Date() else Date(f.cert.certificate.notAfter.time + 1) }))
        assertTrue(calls >= 2); assertEquals(0, f.server.requestCount)
    }

    @Test fun `401 403 500 503 and redirects never retry or imply rollback`() {
        for (code in listOf(401, 403, 421, 500, 503, 307)) server { f ->
            f.server.enqueue(MockResponse().setResponseCode(code).setHeader("Retry-After", "0")
                .setHeader("Location", "https://evil.invalid/replay").setBody("synthetic-server-error"))
            val bytes = sample
            assertNull(f.run(bytes)); assertTrue(bytes.all { it == 0.toByte() }); assertEquals(1, f.server.requestCount)
        }
    }

    @Test fun `outer multipart is one shot and refuses second writeTo`() {
        val body = restoreMultipartBody(sample, AtomicBoolean(false))
        assertTrue(body.isOneShot()); assertTrue(body.contentLength() > sample.size)
        body.writeTo(Buffer())
        try { body.writeTo(Buffer()); fail("Replayed body") } catch (_: java.io.IOException) {}
    }

    @Test fun `receipt admits only a single exact bounded positive integer job field`() {
        assertEquals(9007199254740991L, parseRestoreUploadReceipt(" { \"job_id\" : 9007199254740991 }\n".toByteArray()))
        for (bad in listOf("{}", "{\"job_id\":0}", "{\"job_id\":-1}", "{\"job_id\":1.0}", "{\"job_id\":true}",
            "{\"job_id\":\"71\"}", "{\"job_id\":71,\"other\":1}", "{\"job_id\":71,\"job_id\":72}",
            "{\"job_id\":9007199254740992}", "{\"job_id\":71}garbage", " ".repeat(4097))) {
            assertNull(parseRestoreUploadReceipt(bad.toByteArray()))
        }
    }

    @Test fun `malformed encoded and oversized JSON responses return no job`() {
        for (response in listOf(MockResponse().setBody("{\"job_id\":71,\"other\":1}"),
            MockResponse().setBody("{\"job_id\":71}").setHeader("Content-Encoding", "gzip"),
            MockResponse().setChunkedBody(" ".repeat(4097), 128))) server { f ->
            f.server.enqueue(response); assertNull(f.run(sample)); assertEquals(1, f.server.requestCount)
        }
    }

    @Test fun `invalid token or zero oversized input never connects and clears bytes`() {
        server { f ->
            for (bytes in listOf(ByteArray(0), ByteArray(MAXIMUM_CONFIGURATION_RESTORE_BYTES + 1) { 1 })) {
                assertNull(f.run(bytes)); assertTrue(bytes.all { it == 0.toByte() })
            }
            val bytes = sample
            assertNull(f.run(bytes, auth = "$token\n")); assertTrue(bytes.all { it == 0.toByte() })
            assertEquals(0, f.server.requestCount)
        }
    }

    @Test fun `maximum file bound remains accepted`() = server { f ->
        f.server.enqueue(MockResponse().setBody("{\"job_id\":71}"))
        val bytes = ByteArray(MAXIMUM_CONFIGURATION_RESTORE_BYTES) { 1 }
        assertEquals(71L, f.run(bytes)); assertTrue(bytes.all { it == 0.toByte() })
    }

    @Test fun `timeout and disconnect after body never retry`() {
        for (response in listOf(MockResponse().setBody("{\"job_id\":71}").setBodyDelay(3, TimeUnit.SECONDS),
            MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))) server { f ->
            f.server.enqueue(response); val bytes = sample
            assertNull(f.run(bytes, timeout = 1)); assertTrue(bytes.all { it == 0.toByte() }); assertEquals(1, f.server.requestCount)
        }
    }

    @Test fun `cancelled upload clears owned bytes after callback settles`() = server { f ->
        f.server.enqueue(MockResponse().setBody("{\"job_id\":71}").setBodyDelay(3, TimeUnit.SECONDS))
        val bytes = sample; val done = CountDownLatch(1); var job: Long? = 1
        val upload = OkHttpConfigurationRestoreUploader(f.authority())
        upload.start(token, bytes) { job = it; done.countDown() }
        assertNotNull(f.server.takeRequest(2, TimeUnit.SECONDS)); upload.cancel()
        assertTrue(done.await(2, TimeUnit.SECONDS)); assertNull(job); assertTrue(bytes.all { it == 0.toByte() })
        assertEquals(1, f.server.requestCount)
    }

    private fun server(body: (Fixture) -> Unit) { val f = Fixture(); try { body(f) } finally { f.server.shutdown() } }
    private inner class Fixture {
        val cert = HeldCertificate.Builder().commonName("synthetic-restore-test")
            .validityInterval(System.currentTimeMillis() - 60_000, System.currentTimeMillis() + 60_000).build()
        val server = MockWebServer().apply {
            protocols = listOf(Protocol.HTTP_1_1)
            useHttps(HandshakeCertificates.Builder().heldCertificate(cert).build().sslSocketFactory(), false)
            start(InetAddress.getByName("127.0.0.1"), 0)
        }
        private val pin get() = MessageDigest.getInstance("SHA-256").digest(cert.certificate.encoded).joinToString("") { "%02X".format(it) }
        fun authority(digest: String = pin) = PinnedRpcRequest.parse(mapOf("protocolVersion" to 1, "operationId" to "a".repeat(32),
            "host" to "127.0.0.1", "port" to server.port, "rpcPath" to "/api/current", "leafDerSha256" to digest))!!
        fun run(bytes: ByteArray, pin: String = this.pin, auth: String = token, clock: () -> Date = { Date() }, timeout: Long = 5): Long? {
            val done = CountDownLatch(1); var result: Long? = null
            OkHttpConfigurationRestoreUploader(authority(pin), clock, timeout).start(auth, bytes) { result = it; done.countDown() }
            assertTrue(done.await(12, TimeUnit.SECONDS)); return result
        }
    }
}

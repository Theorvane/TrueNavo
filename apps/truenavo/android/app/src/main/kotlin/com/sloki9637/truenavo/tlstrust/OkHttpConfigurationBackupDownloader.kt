package com.sloki9637.truenavo.tlstrust

import java.io.IOException
import java.net.Proxy
import java.util.Date
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import okhttp3.Call
import okhttp3.Callback
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/** One fresh HTTPS request bound to an already-verified WebSocket authority. */
internal class OkHttpConfigurationBackupDownloader(
    private val authority: PinnedRpcRequest,
    private val now: () -> Date = { Date() },
    private val timeoutSeconds: Long = 45,
) : PinnedDownloadHandle {
    private val cancelled = AtomicBoolean(false)
    @Volatile private var activeCall: Call? = null

    fun start(download: ConfigurationBackupDownloadRequest, completion: (ByteArray?) -> Unit) {
        if (cancelled.get()) { completion(null); return }
        val failure = RecordedFailure()
        // Re-evaluate validity when the new HTTP TLS handshake actually runs.
        val trust = PinnedTrustManager(authority, now(), failure, now)
        val ssl = SSLContext.getInstance("TLS")
        ssl.init(null, arrayOf<javax.net.ssl.TrustManager>(trust), null)
        val url = HttpUrl.Builder().scheme("https").host(authority.host).port(authority.port)
            .encodedPath("/_download/${download.jobId}").addQueryParameter("auth_token", download.token).build()
        require(url.host == authority.host && url.port == authority.port)
        val client = OkHttpClient.Builder()
            .sslSocketFactory(ssl.socketFactory, trust)
            .hostnameVerifier(PinnedAuthorityHostnameVerifier(authority, failure))
            .proxy(Proxy.NO_PROXY)
            .connectTimeout(15, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS)
            .callTimeout(timeoutSeconds, TimeUnit.SECONDS)
            .followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
            .cookieJar(CookieJar.NO_COOKIES).cache(null).build()
        val request = Request.Builder().url(url)
            .header("Accept", "application/octet-stream")
            .header("Accept-Encoding", "identity")
            .header("Cache-Control", "no-store").build()
        val pending = client.newCall(request)
        activeCall = pending
        if (cancelled.get()) pending.cancel()
        pending.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) { finish(null) }
            override fun onResponse(call: Call, response: Response) {
                var bytes: ByteArray? = null
                try {
                    response.use {
                        val encoding = it.headers.values("Content-Encoding")
                        val body = it.body ?: throw IOException("Unavailable.")
                        val length = body.contentLength()
                        if (it.code != 200 || encoding.size > 1 ||
                            encoding.singleOrNull()?.equals("identity", true) == false ||
                            length == 0L || length > MAXIMUM_CONFIGURATION_BACKUP_BYTES) {
                            throw IOException("Unavailable.")
                        }
                        bytes = readBounded(body.byteStream(), length)
                    }
                } catch (_: Throwable) { bytes?.fill(0); bytes = null }
                finish(bytes)
            }
            private fun finish(bytes: ByteArray?) {
                activeCall = null
                client.connectionPool.evictAll()
                client.dispatcher.executorService.shutdown()
                if (cancelled.get()) { bytes?.fill(0); completion(null) }
                else completion(bytes)
            }
        })
    }

    private fun readBounded(input: java.io.InputStream, length: Long): ByteArray {
        // Unknown length/chunked is the official download API. The extra byte
        // detects overflow without ever accumulating an unbounded response.
        val storage = ByteArray(MAXIMUM_CONFIGURATION_BACKUP_BYTES + 1)
        try {
            var used = 0
            while (!cancelled.get()) {
                val count = input.read(storage, used, storage.size - used)
                if (count == -1) break
                used += count
                if (used > MAXIMUM_CONFIGURATION_BACKUP_BYTES) throw IOException("Unavailable.")
            }
            if (cancelled.get() || used == 0 || length >= 0 && length != used.toLong()) throw IOException("Unavailable.")
            return storage.copyOf(used)
        } finally { storage.fill(0) }
    }

    override fun cancel() { cancelled.set(true); activeCall?.cancel() }
}

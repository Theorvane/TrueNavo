package com.sloki9637.truenavo.tlstrust

import java.io.IOException
import java.net.Proxy
import java.util.Date
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import okhttp3.Authenticator
import okhttp3.Call
import okhttp3.Callback
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okio.BufferedSink

/** A single fixed-method upload on the exact authority of a verified session.
 * The Token header and multipart body cannot be emitted before the pin check. */
internal class OkHttpConfigurationRestoreUploader(
    private val authority: PinnedRpcRequest,
    private val now: () -> Date = { Date() },
    private val timeoutSeconds: Long = 45,
) : PinnedDownloadHandle {
    private val cancelled = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    @Volatile private var activeCall: Call? = null

    fun start(token: String, bytes: ByteArray, completion: (Long?) -> Unit) {
        if (!started.compareAndSet(false, true) || cancelled.get() || !validRestoreToken(token) ||
            bytes.isEmpty() || bytes.size > MAXIMUM_CONFIGURATION_RESTORE_BYTES) {
            bytes.fill(0); completion(null); return
        }
        try {
            val failure = RecordedFailure()
            val trust = PinnedTrustManager(authority, now(), failure, now)
            val ssl = SSLContext.getInstance("TLS")
            ssl.init(null, arrayOf<javax.net.ssl.TrustManager>(trust), null)
            val url = HttpUrl.Builder().scheme("https").host(authority.host).port(authority.port).encodedPath("/_upload").build()
            require(url.host == authority.host && url.port == authority.port && url.encodedPath == "/_upload")
            val client = OkHttpClient.Builder().sslSocketFactory(ssl.socketFactory, trust)
                .hostnameVerifier(PinnedAuthorityHostnameVerifier(authority, failure)).proxy(Proxy.NO_PROXY)
                .connectTimeout(15, TimeUnit.SECONDS).readTimeout(15, TimeUnit.SECONDS).writeTimeout(15, TimeUnit.SECONDS)
                .callTimeout(timeoutSeconds, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false)
                .retryOnConnectionFailure(false).authenticator(Authenticator.NONE).proxyAuthenticator(Authenticator.NONE)
                .cookieJar(CookieJar.NO_COOKIES).cache(null).build()
            val body = restoreMultipartBody(bytes, cancelled)
            val request = Request.Builder().url(url).post(body)
                .header("Authorization", "Token $token").header("Accept", "application/json")
                .header("Accept-Encoding", "identity").header("Cache-Control", "no-store").build()
            val call = client.newCall(request)
            activeCall = call
            if (cancelled.get()) call.cancel()
            call.enqueue(object : Callback {
                override fun onFailure(call: Call, error: IOException) = finish(null)
                override fun onResponse(call: Call, response: Response) {
                    var job: Long? = null
                    try {
                        response.use {
                            val encoding = it.headers.values("Content-Encoding")
                            val responseBody = it.body ?: throw IOException("Unavailable.")
                            val length = responseBody.contentLength()
                            if (it.code != 200 || encoding.size > 1 ||
                                encoding.singleOrNull()?.equals("identity", true) == false || length == 0L || length > 4096) {
                                throw IOException("Unavailable.")
                            }
                            val storage = ByteArray(4097)
                            try {
                                var used = 0
                                val input = responseBody.byteStream()
                                while (!cancelled.get()) {
                                    val count = input.read(storage, used, storage.size - used)
                                    if (count < 0) break
                                    used += count
                                    if (used > 4096) throw IOException("Unavailable.")
                                }
                                if (cancelled.get() || used == 0 || length >= 0 && length != used.toLong()) throw IOException("Unavailable.")
                                job = parseRestoreUploadReceipt(storage, used)
                            } finally { storage.fill(0) }
                        }
                    } catch (_: Throwable) { job = null }
                    finish(job)
                }
                private fun finish(job: Long?) {
                    // OkHttp has returned from writeTo before either callback;
                    // never zero a buffer while the request writer uses it.
                    bytes.fill(0)
                    activeCall = null
                    client.connectionPool.evictAll(); client.dispatcher.executorService.shutdown()
                    completion(if (cancelled.get()) null else job)
                }
            })
        } catch (_: Throwable) { bytes.fill(0); completion(null) }
    }
    override fun cancel() { cancelled.set(true); activeCall?.cancel() }
}

internal fun restoreMultipartBody(bytes: ByteArray, cancelled: AtomicBoolean): RequestBody {
    val file = object : RequestBody() {
        override fun contentType() = "application/octet-stream".toMediaType()
        override fun contentLength() = bytes.size.toLong()
        override fun writeTo(sink: BufferedSink) {
            var offset = 0
            while (offset < bytes.size) {
                if (cancelled.get()) throw IOException("Upload cancelled.")
                val count = minOf(8192, bytes.size - offset)
                sink.write(bytes, offset, count); offset += count
            }
        }
    }
    val multipart = MultipartBody.Builder().setType(MultipartBody.FORM)
        .addFormDataPart("data", "{\"method\":\"config.upload\",\"params\":[]}")
        .addFormDataPart("file", "truenas-configuration.db", file).build()
    val written = AtomicBoolean(false)
    return object : RequestBody() {
        override fun contentType() = multipart.contentType()
        override fun contentLength() = multipart.contentLength()
        // Required even with retryOnConnectionFailure=false: follow-up handling
        // can otherwise replay a multipart request after e.g.503 Retry-After:0.
        override fun isOneShot() = true
        override fun writeTo(sink: BufferedSink) {
            if (!written.compareAndSet(false, true) || cancelled.get()) throw IOException("Upload unavailable.")
            multipart.writeTo(sink)
        }
    }
}

internal fun parseRestoreUploadReceipt(bytes: ByteArray, length: Int = bytes.size): Long? {
    if (length !in 1..4096 || length > bytes.size || (0 until length).any { bytes[it].toInt() !in 0..127 }) return null
    val raw = String(bytes, 0, length, Charsets.US_ASCII)
    val match = Regex("[ \\t\\r\\n]*\\{[ \\t\\r\\n]*\"job_id\"[ \\t\\r\\n]*:[ \\t\\r\\n]*([1-9][0-9]{0,15})[ \\t\\r\\n]*}[ \\t\\r\\n]*").matchEntire(raw) ?: return null
    return match.groupValues[1].toLongOrNull()?.takeIf { it in 1..9007199254740991L }
}

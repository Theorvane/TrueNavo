package com.sloki9637.truenavo.tlstrust

import java.net.Socket
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Date
import java.util.concurrent.TimeUnit
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSession
import javax.net.ssl.X509ExtendedTrustManager
import okhttp3.CookieJar
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString

/// Establishes one fresh TLS+WebSocket connection per approved reconnect. The
/// exact leaf is compared before the HTTP upgrade, and no application frame is
/// written by this factory.
internal class OkHttpPinnedTransportFactory(
    private val connectTimeoutSeconds: Long = 15,
    private val pingIntervalSeconds: Long = 30,
) : PinnedTransportFactory {

    override fun connect(
        request: PinnedRpcRequest,
        verifyDate: Date,
        events: PinnedWebSocketEvents,
    ): PinnedWebSocket {
        val failure = RecordedFailure()
        val trustManager = PinnedTrustManager(request, verifyDate, failure)
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf<javax.net.ssl.TrustManager>(trustManager), null)
        val url = HttpUrl.Builder()
            .scheme("https")
            .host(request.host)
            .port(request.port)
            .encodedPath(request.rpcPath)
            .build()
        // A normalized URL that no longer names the pinned authority must never
        // be dialled: the pin key and the connection target have to agree.
        if (url.host != request.host || url.port != request.port) {
            throw IllegalStateException("The connection URL does not match the pinned authority.")
        }
        val client = OkHttpClient.Builder()
            .sslSocketFactory(context.socketFactory, trustManager)
            .hostnameVerifier(PinnedAuthorityHostnameVerifier(request, failure))
            .connectTimeout(connectTimeoutSeconds, TimeUnit.SECONDS)
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .pingInterval(pingIntervalSeconds, TimeUnit.SECONDS)
            .followRedirects(false)
            .followSslRedirects(false)
            .cookieJar(CookieJar.NO_COOKIES)
            .cache(null)
            .retryOnConnectionFailure(false)
            .build()
        val socket = client.newWebSocket(
            Request.Builder().url(url).build(),
            object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = events.onOpen()

                override fun onMessage(webSocket: WebSocket, text: String) = events.onFrame(text)

                override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                    // The RPC transport is text-only; a binary frame ends it.
                    webSocket.cancel()
                    events.onClosed()
                }

                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
                    webSocket.close(1000, null)
                }

                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) =
                    events.onClosed()

                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) =
                    events.onFailure(failure.code ?: "pinnedReconnectFailed")
            },
        )
        return OkHttpPinnedWebSocket(socket, client, request)
    }
}

private class OkHttpPinnedWebSocket(
    private val socket: WebSocket,
    private val client: OkHttpClient,
    private val request: PinnedRpcRequest,
) : PinnedWebSocket, ConfigurationBackupPinnedSocket, ConfigurationRestorePinnedSocket {
    private val downloadLock = Any()
    private var closed = false
    private var downloadHandle: PinnedDownloadHandle? = null
    private var uploadHandle: PinnedDownloadHandle? = null

    override fun download(request: ConfigurationBackupDownloadRequest, completion: (ByteArray?) -> Unit): PinnedDownloadHandle {
        synchronized(downloadLock) {
            if (closed || downloadHandle != null || uploadHandle != null) throw IllegalStateException("Download unavailable.")
            val downloader = OkHttpConfigurationBackupDownloader(this.request)
            downloadHandle = downloader
            downloader.start(request) { bytes ->
                synchronized(downloadLock) {
                    if (closed) { bytes?.fill(0); completion(null) }
                    else completion(bytes)
                    if (downloadHandle === downloader) downloadHandle = null
                }
            }
            return downloader
        }
    }

    override fun upload(token: String, bytes: ByteArray, completion: (Long?) -> Unit): PinnedDownloadHandle {
        synchronized(downloadLock) {
            if (closed || downloadHandle != null || uploadHandle != null) { bytes.fill(0); throw IllegalStateException("Upload unavailable.") }
            val uploader = OkHttpConfigurationRestoreUploader(request)
            uploadHandle = uploader
            uploader.start(token, bytes) { job ->
                synchronized(downloadLock) {
                    completion(if (closed) null else job)
                    if (uploadHandle === uploader) uploadHandle = null
                }
            }
            return uploader
        }
    }
    override fun send(frame: String): Boolean = socket.send(frame)

    override fun close() {
        synchronized(downloadLock) {
            closed = true
            downloadHandle?.cancel()
            downloadHandle = null
            uploadHandle?.cancel()
            uploadHandle = null
        }
        try {
            if (!socket.close(1000, null)) socket.cancel()
        } catch (error: Throwable) {
            socket.cancel()
        }
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }
}

/// Records the first boundary failure code observed during a handshake so the
/// generic transport error can be reported as its actual cause.
internal class RecordedFailure {
    @Volatile
    var code: String? = null
        private set

    fun record(value: String) {
        if (code == null) code = value
    }
}

/// Applies [PinnedLeafTrustPolicy] before the TLS stack may complete, and
/// rejects every chain the policy does not accept.
internal class PinnedTrustManager(
    private val request: PinnedRpcRequest,
    private val verifyDate: Date,
    private val failure: RecordedFailure,
    private val now: () -> Date = { verifyDate },
) : X509ExtendedTrustManager() {

    private fun check(chain: Array<out X509Certificate>?, presentedHost: String) {
        val code = PinnedLeafTrustPolicy.evaluate(
            expectedHost = request.host,
            presentedHost = presentedHost,
            expectedDigest = request.digest,
            leaf = chain?.firstOrNull(),
            verifyDate = now(),
        )
        if (code != null) {
            failure.record(code)
            throw CertificateException("The presented leaf is not the pinned certificate.")
        }
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) =
        check(chain, request.host)

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) =
        check(chain, request.host)

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) =
        check(chain, request.host)

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) =
        throw CertificateException("Client authentication is not supported.")

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) =
        throw CertificateException("Client authentication is not supported.")

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) =
        throw CertificateException("Client authentication is not supported.")

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

/// A pinned connection's identity is the exact leaf the user approved for this
/// authority, the way an SSH known-hosts entry works, so a certificate that does
/// not name the address is not by itself a reason to refuse. The approval screen
/// says so explicitly before any pin is written. This verifier therefore only
/// asserts that the connection is still the pinned authority; the digest check
/// in [PinnedTrustManager] has already run and rejected everything else.
internal class PinnedAuthorityHostnameVerifier(
    private val request: PinnedRpcRequest,
    private val failure: RecordedFailure,
) : HostnameVerifier {
    override fun verify(hostname: String?, session: SSLSession?): Boolean {
        val verified = hostname != null &&
            session != null &&
            hostname.removeSurrounding("[", "]").lowercase() == request.host
        if (!verified) failure.record("hostnameMismatch")
        return verified
    }
}

package com.truedash.truedash.tlstrust

import java.net.Socket
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.Date
import java.util.concurrent.TimeUnit
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.HttpsURLConnection
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
            .hostnameVerifier(RecordingHostnameVerifier(failure))
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
        return OkHttpPinnedWebSocket(socket, client)
    }
}

private class OkHttpPinnedWebSocket(
    private val socket: WebSocket,
    private val client: OkHttpClient,
) : PinnedWebSocket {
    override fun send(frame: String): Boolean = socket.send(frame)

    override fun close() {
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
) : X509ExtendedTrustManager() {

    private fun check(chain: Array<out X509Certificate>?, presentedHost: String) {
        val code = PinnedLeafTrustPolicy.evaluate(
            expectedHost = request.host,
            presentedHost = presentedHost,
            expectedDigest = request.digest,
            leaf = chain?.firstOrNull(),
            verifyDate = verifyDate,
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

/// Keeps the platform's certificate hostname policy and reports its refusal as
/// the typed hostname failure instead of a generic transport error.
internal class RecordingHostnameVerifier(
    private val failure: RecordedFailure,
    private val delegate: HostnameVerifier = HttpsURLConnection.getDefaultHostnameVerifier(),
) : HostnameVerifier {
    override fun verify(hostname: String?, session: SSLSession?): Boolean {
        val verified = hostname != null && session != null && delegate.verify(hostname, session)
        if (!verified) failure.record("hostnameMismatch")
        return verified
    }
}

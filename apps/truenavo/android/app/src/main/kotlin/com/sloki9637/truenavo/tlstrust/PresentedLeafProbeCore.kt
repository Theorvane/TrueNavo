package com.sloki9637.truenavo.tlstrust

import java.io.Closeable
import java.net.InetSocketAddress
import java.net.Socket
import java.security.KeyStore
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLEngine
import javax.net.ssl.SSLSocket
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509ExtendedTrustManager

/// The outcome of one bounded, capture-only TLS handshake.
internal sealed interface LeafCapture {
    data class Captured(val der: ByteArray, val platformTrustPassed: Boolean) : LeafCapture
    object Failed : LeafCapture
}

/// Capture-only transport abstraction: deliberately no send/receive capability.
internal fun interface PresentedLeafHandshake {
    /// [register] hands the live socket to the core so a cancel can close it,
    /// and returns false once the operation is no longer owned by the core.
    fun capture(host: String, port: Int, register: (Closeable) -> Boolean): LeafCapture
}

/// Per-process core for capture-only TLS handshakes. It is deliberately
/// independent of [PinnedRpcCore]: a probe is never a transport, exposes no
/// send/receive method, and its rejection of the handshake is not reusable.
internal class PresentedLeafProbeCore(
    private val handshake: PresentedLeafHandshake = SystemPresentedLeafHandshake(),
    private val executor: ExecutorService = Executors.newCachedThreadPool(),
) {
    private val lock = Any()
    private val operations = mutableMapOf<String, Operation>()

    fun capture(arguments: Any?, completion: (Map<String, Any>) -> Unit) {
        val request = Request.parse(arguments)
        if (request == null) {
            completion(BridgeProtocol.failure("captureFailed", null))
            return
        }
        val operation = Operation(request.operationId, completion)
        synchronized(lock) {
            if (operations.containsKey(request.operationId)) {
                completion(BridgeProtocol.failure("captureFailed", request.operationId))
                return
            }
            operations[request.operationId] = operation
        }
        executor.execute {
            val capture = try {
                handshake.capture(request.host, request.port) { closeable ->
                    synchronized(lock) {
                        val live = operations[request.operationId] === operation
                        if (live) operation.socket = closeable
                        live
                    }
                }
            } catch (error: Throwable) {
                LeafCapture.Failed
            }
            finish(operation, response(request.operationId, capture))
        }
    }

    fun cancel(arguments: Any?, completion: (Map<String, Any>) -> Unit) {
        val id = BridgeProtocol.identifier(arguments, "operationId")
        if (id == null) {
            completion(BridgeProtocol.failure("captureFailed", null))
            return
        }
        val operation = synchronized(lock) { operations.remove(id) }
        operation?.closeSocket()
        operation?.finish(BridgeProtocol.failure("cancelled", id))
        completion(BridgeProtocol.failure("cancelled", id))
    }

    private fun response(operationId: String, capture: LeafCapture): Map<String, Any> =
        when (capture) {
            is LeafCapture.Failed -> BridgeProtocol.failure("captureFailed", operationId)
            is LeafCapture.Captured ->
                if (capture.der.isEmpty() || capture.der.size > BridgeProtocol.MAXIMUM_DER_BYTES) {
                    BridgeProtocol.failure("captureFailed", operationId)
                } else {
                    mapOf(
                        "protocolVersion" to BridgeProtocol.PROTOCOL_VERSION,
                        "operationId" to operationId,
                        "leafDerBase64" to Base64Codec.encode(capture.der),
                        "platformTrust" to if (capture.platformTrustPassed) "passed" else "didNotPass",
                    )
                }
        }

    private fun finish(operation: Operation, response: Map<String, Any>) {
        val owned = synchronized(lock) {
            if (operations[operation.operationId] === operation) {
                operations.remove(operation.operationId)
                true
            } else {
                false
            }
        }
        if (owned) operation.finish(response)
    }

    private class Operation(
        val operationId: String,
        private val completion: (Map<String, Any>) -> Unit,
    ) {
        @Volatile
        var socket: Closeable? = null
        private var completed = false

        fun closeSocket() {
            try {
                socket?.close()
            } catch (error: Throwable) {
                // A cancel must never surface a socket teardown error.
            }
        }

        fun finish(response: Map<String, Any>) {
            synchronized(this) {
                if (completed) return
                completed = true
            }
            completion(response)
        }
    }

    private class Request(val operationId: String, val host: String, val port: Int) {
        companion object {
            fun parse(raw: Any?): Request? {
                val values = BridgeProtocol.arguments(
                    raw,
                    setOf("protocolVersion", "operationId", "host", "port"),
                ) ?: return null
                val id = values["operationId"]
                if (!BridgeProtocol.validId(id)) return null
                val host = BridgeProtocol.host(values["host"]) ?: return null
                val port = BridgeProtocol.port(values["port"]) ?: return null
                return Request(id as String, host, port)
            }
        }
    }
}

/// The real handshake. It installs a trust manager that captures the presented
/// leaf, measures platform trust for display only, and then always rejects, so
/// this connection can never be authenticated or reused as a transport.
internal class SystemPresentedLeafHandshake(
    private val connectTimeoutMillis: Int = 10_000,
    private val handshakeTimeoutMillis: Int = 10_000,
) : PresentedLeafHandshake {

    override fun capture(host: String, port: Int, register: (Closeable) -> Boolean): LeafCapture {
        val trustManager = CapturingTrustManager(systemTrustManager())
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf<javax.net.ssl.TrustManager>(trustManager), null)
        var socket: Socket? = null
        try {
            val plain = Socket()
            socket = plain
            if (!register(plain)) return LeafCapture.Failed
            plain.connect(InetSocketAddress(host, port), connectTimeoutMillis)
            plain.soTimeout = handshakeTimeoutMillis
            val tls = context.socketFactory.createSocket(plain, host, port, true) as SSLSocket
            socket = tls
            if (!register(tls)) return LeafCapture.Failed
            val parameters = tls.sslParameters
            parameters.endpointIdentificationAlgorithm = "HTTPS"
            if (!isIpLiteral(host)) parameters.serverNames = listOf(SNIHostName(host))
            tls.sslParameters = parameters
            try {
                tls.startHandshake()
            } catch (error: Throwable) {
                // Expected: the capturing trust manager always rejects.
            }
        } catch (error: Throwable) {
            return LeafCapture.Failed
        } finally {
            try {
                socket?.close()
            } catch (error: Throwable) {
                // The capture connection is discarded either way.
            }
        }
        val der = trustManager.capturedLeaf ?: return LeafCapture.Failed
        return LeafCapture.Captured(der, trustManager.platformTrustPassed)
    }

    private fun isIpLiteral(host: String): Boolean =
        host.contains(':') || host.all { it.isDigit() || it == '.' }

    private fun systemTrustManager(): X509ExtendedTrustManager? {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(null as KeyStore?)
        return factory.trustManagers.filterIsInstance<X509ExtendedTrustManager>().firstOrNull()
    }
}

/// Copies the presented leaf, records an informational platform-trust result,
/// and then rejects every server chain unconditionally.
internal class CapturingTrustManager(
    private val delegate: X509ExtendedTrustManager?,
) : X509ExtendedTrustManager() {

    @Volatile
    var capturedLeaf: ByteArray? = null
        private set

    @Volatile
    var platformTrustPassed: Boolean = false
        private set

    private fun capture(chain: Array<out X509Certificate>?, measure: () -> Unit) {
        val leaf = chain?.firstOrNull()
        if (leaf != null && capturedLeaf == null) {
            capturedLeaf = try {
                leaf.encoded
            } catch (error: Throwable) {
                null
            }
        }
        // Informational only. The handshake is rejected below regardless.
        platformTrustPassed = try {
            if (delegate == null) false else { measure(); true }
        } catch (error: Throwable) {
            false
        }
        throw CertificateException("Capture-only probe never authenticates a server.")
    }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) =
        capture(chain) { delegate?.checkServerTrusted(chain, authType) }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) =
        capture(chain) { delegate?.checkServerTrusted(chain, authType, socket) }

    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) =
        capture(chain) { delegate?.checkServerTrusted(chain, authType, engine) }

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) =
        throw CertificateException("Client authentication is not supported.")

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) =
        throw CertificateException("Client authentication is not supported.")

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) =
        throw CertificateException("Client authentication is not supported.")

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

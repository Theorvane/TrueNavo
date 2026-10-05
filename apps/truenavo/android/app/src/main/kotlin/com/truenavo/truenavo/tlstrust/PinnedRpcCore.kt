package com.truenavo.truenavo.tlstrust

import java.util.ArrayDeque
import java.util.Date
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/// The parsed, fully validated connect request. Construction is the only place
/// an authority, path, or digest can enter the pinned transport.
internal class PinnedRpcRequest private constructor(
    val operationId: String,
    val host: String,
    val port: Int,
    val rpcPath: String,
    val digest: ByteArray,
) {
    companion object {
        fun parse(raw: Any?): PinnedRpcRequest? {
            val values = BridgeProtocol.arguments(
                raw,
                setOf("protocolVersion", "operationId", "host", "port", "rpcPath", "leafDerSha256"),
            ) ?: return null
            val id = values["operationId"]
            if (!BridgeProtocol.validId(id)) return null
            val host = BridgeProtocol.host(values["host"]) ?: return null
            val port = BridgeProtocol.port(values["port"]) ?: return null
            val path = BridgeProtocol.path(values["rpcPath"]) ?: return null
            val digest = BridgeProtocol.digest(values["leafDerSha256"]) ?: return null
            return PinnedRpcRequest(id as String, host, port, path, digest)
        }
    }
}

/// The bounded transport handle the core owns for one verified session.
internal interface PinnedWebSocket {
    fun send(frame: String): Boolean
    fun close()
}

/// Callbacks a transport raises. `onFailure` carries the boundary failure code
/// the Dart side understands; it is never a platform message.
internal interface PinnedWebSocketEvents {
    fun onOpen()
    fun onFrame(frame: String)
    fun onClosed()
    fun onFailure(code: String)
}

internal fun interface PinnedTransportFactory {
    fun connect(
        request: PinnedRpcRequest,
        verifyDate: Date,
        events: PinnedWebSocketEvents,
    ): PinnedWebSocket
}

/// Per-process core for exact leaf-pin WebSocket sessions. It is deliberately
/// independent of [PresentedLeafProbeCore]: a probe is never a transport and a
/// transport is created fresh for each connect request.
private const val SOCKET_HANDOFF_TIMEOUT_MILLIS = 5_000L

internal class PinnedRpcCore(
    private val transports: PinnedTransportFactory = OkHttpPinnedTransportFactory(),
    private val now: () -> Date = { Date() },
    private val newSessionId: () -> String = {
        UUID.randomUUID().toString().replace("-", "").lowercase()
    },
) {
    private val lock = Any()
    private val operations = mutableMapOf<String, Operation>()
    private val sessions = mutableMapOf<String, Session>()

    fun connect(raw: Any?, completion: (Map<String, Any>) -> Unit) {
        val request = PinnedRpcRequest.parse(raw)
        if (request == null) {
            completion(BridgeProtocol.failure("malformedCertificate", null))
            return
        }
        val operation = Operation(request, completion)
        synchronized(lock) {
            if (operations.containsKey(request.operationId)) {
                completion(BridgeProtocol.failure("pinnedReconnectFailed", request.operationId))
                return
            }
            operations[request.operationId] = operation
        }
        val socket = try {
            transports.connect(request, now(), Events(operation))
        } catch (error: Throwable) {
            fail(operation, "pinnedReconnectFailed")
            return
        }
        val abandoned = synchronized(lock) {
            val live = operations[request.operationId] === operation
            operation.attach(socket)
            !live
        }
        if (abandoned) socket.close()
    }

    fun cancel(raw: Any?, completion: (Map<String, Any>) -> Unit) {
        val id = BridgeProtocol.identifier(raw, "operationId")
        if (id == null) {
            completion(BridgeProtocol.failure("cancelled", null))
            return
        }
        val operation = synchronized(lock) { operations.remove(id) }
        if (operation == null) {
            completion(BridgeProtocol.failure("cancelled", id))
            return
        }
        val sessionId = operation.sessionId
        if (sessionId != null) {
            closeSession(sessionId, removeOperation = false)
        } else {
            operation.socket?.close()
        }
        operation.finish(BridgeProtocol.failure("cancelled", id))
        completion(BridgeProtocol.failure("cancelled", id))
    }

    fun send(raw: Any?, completion: (Map<String, Any>) -> Unit) {
        val values = BridgeProtocol.arguments(
            raw,
            setOf("protocolVersion", "sessionId", "frame"),
        )
        val id = values?.get("sessionId")
        val frame = values?.get("frame")
        if (id == null || !BridgeProtocol.validId(id) || frame !is String ||
            frame.toByteArray(Charsets.UTF_8).size > BridgeProtocol.MAXIMUM_FRAME_BYTES
        ) {
            completion(BridgeProtocol.sessionClosed(id as? String))
            return
        }
        val sessionId = id as String
        val session = synchronized(lock) { sessions[sessionId] }
        if (session == null || !session.socket.send(frame)) {
            completion(BridgeProtocol.sessionClosed(sessionId))
            return
        }
        completion(BridgeProtocol.sessionAck(sessionId))
    }

    fun receive(raw: Any?, completion: (Map<String, Any>) -> Unit) {
        val id = BridgeProtocol.identifier(raw, "sessionId")
        if (id == null) {
            completion(BridgeProtocol.sessionClosed(null))
            return
        }
        val delivered: String?
        synchronized(lock) {
            val session = sessions[id]
            if (session == null || session.pendingReceive != null) {
                completion(BridgeProtocol.sessionClosed(id))
                return
            }
            delivered = session.frames.poll()
            if (delivered == null) session.pendingReceive = completion
        }
        if (delivered != null) {
            completion(
                mapOf(
                    "protocolVersion" to BridgeProtocol.PROTOCOL_VERSION,
                    "sessionId" to id,
                    "frame" to delivered,
                ),
            )
        }
    }

    fun close(raw: Any?, completion: (Map<String, Any>) -> Unit) {
        val id = BridgeProtocol.identifier(raw, "sessionId")
        if (id == null) {
            completion(BridgeProtocol.sessionClosed(null))
            return
        }
        closeSession(id)
        completion(BridgeProtocol.sessionAck(id))
    }

    fun downloadConfigurationBackup(raw: Any?, completion: (Map<String, Any>) -> Unit) {
        val values = BridgeProtocol.arguments(raw, setOf("protocolVersion", "sessionId", "jobId", "relativeUrl"))
        val id = values?.get("sessionId")
        val request = ConfigurationBackupDownloadRequest.parse(values?.get("jobId"), values?.get("relativeUrl"))
        if (!BridgeProtocol.validId(id) || request == null) {
            completion(BridgeProtocol.sessionClosed(id as? String)); return
        }
        val sessionId = id as String
        val pending = Download(request.jobId, completion)
        val session: Session
        synchronized(lock) {
            session = sessions[sessionId] ?: run { completion(BridgeProtocol.sessionClosed(sessionId)); return }
            if (session.download != null || session.upload != null || session.socket !is ConfigurationBackupPinnedSocket) {
                completion(BridgeProtocol.sessionClosed(sessionId)); return
            }
            session.download = pending
        }
        val handle = try {
            (session.socket as ConfigurationBackupPinnedSocket).download(request) { bytes ->
                synchronized(lock) {
                    if (sessions[sessionId] !== session || session.download !== pending) {
                        bytes?.fill(0); return@download
                    }
                    session.download = null
                    if (bytes == null || bytes.isEmpty() || bytes.size > MAXIMUM_CONFIGURATION_BACKUP_BYTES) {
                        bytes?.fill(0)
                        completion(BridgeProtocol.sessionClosed(sessionId))
                    } else {
                        completion(mapOf("protocolVersion" to 1, "sessionId" to sessionId, "jobId" to request.jobId, "bytes" to bytes))
                    }
                }
            }
        } catch (_: Throwable) {
            synchronized(lock) {
                if (session.download === pending) {
                    session.download = null
                    completion(BridgeProtocol.sessionClosed(sessionId))
                }
            }
            return
        }
        synchronized(lock) {
            pending.handle = handle
            if (sessions[sessionId] !== session || session.download !== pending) handle.cancel()
        }
    }

    fun closeAll() {
        val ids = synchronized(lock) { sessions.keys.toList() }
        ids.forEach { closeSession(it) }
        val pending = synchronized(lock) { operations.values.toList().also { operations.clear() } }
        pending.forEach { it.socket?.close(); it.finish(BridgeProtocol.failure("cancelled", it.request.operationId)) }
    }

    fun uploadConfigurationRestore(raw: Any?, completion: (Map<String, Any>) -> Unit) {
        val values = BridgeProtocol.arguments(raw, setOf("protocolVersion", "sessionId", "token", "bytes"))
        val bytes = (raw as? Map<*, *>)?.get("bytes") as? ByteArray
        val id = values?.get("sessionId")
        val token = values?.get("token")
        if (!BridgeProtocol.validId(id) || !validRestoreToken(token) || bytes == null ||
            bytes.isEmpty() || bytes.size > MAXIMUM_CONFIGURATION_RESTORE_BYTES) {
            bytes?.fill(0); completion(BridgeProtocol.sessionClosed(id as? String)); return
        }
        val sessionId = id as String
        val pending = Upload(completion)
        val session: Session
        synchronized(lock) {
            session = sessions[sessionId] ?: run { bytes.fill(0); completion(BridgeProtocol.sessionClosed(sessionId)); return }
            if (session.upload != null || session.download != null || session.socket !is ConfigurationRestorePinnedSocket) {
                bytes.fill(0); completion(BridgeProtocol.sessionClosed(sessionId)); return
            }
            session.upload = pending
        }
        val handle = try {
            (session.socket as ConfigurationRestorePinnedSocket).upload(token as String, bytes) { job ->
                synchronized(lock) {
                    if (sessions[sessionId] !== session || session.upload !== pending) return@upload
                    session.upload = null
                    if (job == null || job <= 0 || job > 9007199254740991L) completion(BridgeProtocol.sessionClosed(sessionId))
                    else completion(mapOf("protocolVersion" to 1, "sessionId" to sessionId, "jobId" to job))
                }
            }
        } catch (_: Throwable) {
            bytes.fill(0)
            synchronized(lock) {
                if (session.upload === pending) { session.upload = null; completion(BridgeProtocol.sessionClosed(sessionId)) }
            }
            return
        }
        synchronized(lock) {
            pending.handle = handle
            if (sessions[sessionId] !== session || session.upload !== pending) handle.cancel()
        }
    }

    private fun fail(operation: Operation, code: String) {
        val owned = synchronized(lock) {
            if (operations[operation.request.operationId] === operation) {
                operations.remove(operation.request.operationId)
                true
            } else {
                false
            }
        }
        if (!owned) return
        val sessionId = operation.sessionId
        if (sessionId != null) {
            closeSession(sessionId, removeOperation = false)
        } else {
            operation.socket?.close()
        }
        operation.finish(BridgeProtocol.failure(code, operation.request.operationId))
    }

    private fun closeSession(id: String, removeOperation: Boolean = true) {
        val pending: ((Map<String, Any>) -> Unit)?
        val session: Session?
        val download: Download?
        val upload: Upload?
        synchronized(lock) {
            session = sessions.remove(id)
            if (session == null) return
            if (removeOperation) operations.remove(session.operationId)
            pending = session.pendingReceive
            session.pendingReceive = null
            session.frames.clear()
            download = session.download
            session.download = null
            upload = session.upload
            session.upload = null
        }
        upload?.handle?.cancel()
        upload?.completion?.invoke(BridgeProtocol.sessionClosed(id))
        download?.handle?.cancel()
        download?.completion?.invoke(BridgeProtocol.sessionClosed(id))
        session?.socket?.close()
        pending?.invoke(BridgeProtocol.sessionClosed(id))
    }

    private inner class Events(private val operation: Operation) : PinnedWebSocketEvents {
        override fun onOpen() {
            // The transport is only returned by `connect`, so an open callback
            // delivered on the client's own thread can arrive before this
            // operation owns its handle. Wait for that hand-off instead of
            // dropping the session and leaving the caller to time out.
            val socket = operation.awaitSocket() ?: return
            val response: Map<String, Any>
            synchronized(lock) {
                if (operations[operation.request.operationId] !== operation) return
                if (operation.sessionId != null) return
                var id = newSessionId()
                while (sessions.containsKey(id)) id = newSessionId()
                operation.sessionId = id
                sessions[id] = Session(socket, operation.request.operationId)
                response = mapOf(
                    "protocolVersion" to BridgeProtocol.PROTOCOL_VERSION,
                    "operationId" to operation.request.operationId,
                    "sessionId" to id,
                )
            }
            operation.finish(response)
        }

        override fun onFrame(frame: String) {
            if (frame.toByteArray(Charsets.UTF_8).size > BridgeProtocol.MAXIMUM_FRAME_BYTES) {
                operation.sessionId?.let { closeSession(it) }
                return
            }
            val pending: ((Map<String, Any>) -> Unit)?
            val id = operation.sessionId ?: return
            synchronized(lock) {
                val session = sessions[id] ?: return
                pending = session.pendingReceive
                session.pendingReceive = null
                if (pending == null) session.frames.add(frame)
            }
            pending?.invoke(
                mapOf(
                    "protocolVersion" to BridgeProtocol.PROTOCOL_VERSION,
                    "sessionId" to id,
                    "frame" to frame,
                ),
            )
        }

        override fun onClosed() {
            val id = operation.sessionId
            if (id != null) closeSession(id) else fail(operation, "pinnedReconnectFailed")
        }

        override fun onFailure(code: String) {
            val id = operation.sessionId
            if (id != null) closeSession(id) else fail(operation, code)
        }
    }

    private class Operation(
        val request: PinnedRpcRequest,
        private val completion: (Map<String, Any>) -> Unit,
    ) {
        @Volatile
        var socket: PinnedWebSocket? = null
            private set

        private val attached = CountDownLatch(1)

        @Volatile
        var sessionId: String? = null
        private var completed = false

        fun attach(value: PinnedWebSocket) {
            socket = value
            attached.countDown()
        }

        /// Bounded so a backend that never returns a handle cannot pin a
        /// callback thread; the caller then treats the open as not owned.
        fun awaitSocket(): PinnedWebSocket? {
            attached.await(SOCKET_HANDOFF_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS)
            return socket
        }

        fun finish(response: Map<String, Any>) {
            synchronized(this) {
                if (completed) return
                completed = true
            }
            completion(response)
        }
    }

    private class Session(val socket: PinnedWebSocket, val operationId: String) {
        val frames = ArrayDeque<String>()
        var pendingReceive: ((Map<String, Any>) -> Unit)? = null
        var download: Download? = null
        var upload: Upload? = null
    }
    private class Download(val jobId: Long, val completion: (Map<String, Any>) -> Unit) {
        var handle: PinnedDownloadHandle? = null
    }
    private class Upload(val completion: (Map<String, Any>) -> Unit) {
        var handle: PinnedDownloadHandle? = null
    }
}

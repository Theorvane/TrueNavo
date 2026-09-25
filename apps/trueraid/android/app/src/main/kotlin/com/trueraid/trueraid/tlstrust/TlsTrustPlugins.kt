package com.trueraid.trueraid.tlstrust

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

private val mainHandler = Handler(Looper.getMainLooper())

private fun onMain(result: MethodChannel.Result): (Map<String, Any>) -> Unit = { response ->
    mainHandler.post {
        try { result.success(response) }
        finally { response.values.filterIsInstance<ByteArray>().forEach { it.fill(0) } }
    }
}

/// Registers the capture-only presented-leaf bridge. It exposes no send,
/// receive, or credential method and returns no transport handle.
class PresentedLeafProbePlugin : MethodChannel.MethodCallHandler {
    private val core = PresentedLeafProbeCore()
    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "trueraid.presented_leaf_probe.v1").also {
            it.setMethodCallHandler(this)
        }
    }

    fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val respond = onMain(result)
        when (call.method) {
            "trueraid.capturePresentedLeaf" -> core.capture(call.arguments, respond)
            "trueraid.cancelPresentedLeaf" -> core.cancel(call.arguments, respond)
            else -> result.notImplemented()
        }
    }
}

/// Registers the transport-only pinned reconnect bridge. It owns no
/// certificate capture capability.
class PinnedRpcPlugin : MethodChannel.MethodCallHandler {
    private val core = PinnedRpcCore()
    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "trueraid.pinned_rpc.v1").also {
            it.setMethodCallHandler(this)
        }
    }

    fun detach() {
        core.closeAll()
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val respond = onMain(result)
        when (call.method) {
            "trueraid.connectPinnedRpc" -> core.connect(call.arguments, respond)
            "trueraid.cancelPinnedRpc" -> core.cancel(call.arguments, respond)
            "trueraid.sendPinnedRpc" -> core.send(call.arguments, respond)
            "trueraid.receivePinnedRpc" -> core.receive(call.arguments, respond)
            "trueraid.closePinnedRpc" -> core.close(call.arguments, respond)
            "trueraid.downloadConfigurationBackup" -> core.downloadConfigurationBackup(call.arguments, respond)
            "trueraid.uploadConfigurationRestore" -> core.uploadConfigurationRestore(call.arguments, respond)
            else -> result.notImplemented()
        }
    }
}

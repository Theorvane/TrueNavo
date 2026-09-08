package com.truedash.truedash.tlstrust

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

private val mainHandler = Handler(Looper.getMainLooper())

private fun onMain(result: MethodChannel.Result): (Map<String, Any>) -> Unit = { response ->
    mainHandler.post { result.success(response) }
}

/// Registers the capture-only presented-leaf bridge. It exposes no send,
/// receive, or credential method and returns no transport handle.
class PresentedLeafProbePlugin : MethodChannel.MethodCallHandler {
    private val core = PresentedLeafProbeCore()
    private var channel: MethodChannel? = null

    fun attach(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, "truedash.presented_leaf_probe.v1").also {
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
            "truedash.capturePresentedLeaf" -> core.capture(call.arguments, respond)
            "truedash.cancelPresentedLeaf" -> core.cancel(call.arguments, respond)
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
        channel = MethodChannel(messenger, "truedash.pinned_rpc.v1").also {
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
            "truedash.connectPinnedRpc" -> core.connect(call.arguments, respond)
            "truedash.cancelPinnedRpc" -> core.cancel(call.arguments, respond)
            "truedash.sendPinnedRpc" -> core.send(call.arguments, respond)
            "truedash.receivePinnedRpc" -> core.receive(call.arguments, respond)
            "truedash.closePinnedRpc" -> core.close(call.arguments, respond)
            else -> result.notImplemented()
        }
    }
}

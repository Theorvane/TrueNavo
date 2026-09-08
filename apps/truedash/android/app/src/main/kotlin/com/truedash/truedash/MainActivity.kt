package com.truedash.truedash

import com.truedash.truedash.tlstrust.PinnedRpcPlugin
import com.truedash.truedash.tlstrust.PresentedLeafProbePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val presentedLeafProbe = PresentedLeafProbePlugin()
    private val pinnedRpc = PinnedRpcPlugin()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        presentedLeafProbe.attach(messenger)
        pinnedRpc.attach(messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        presentedLeafProbe.detach()
        pinnedRpc.detach()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}

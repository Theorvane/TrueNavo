package com.truenavo.truenavo

import android.content.Intent
import com.truenavo.truenavo.configurationbackup.ConfigurationBackupFilePlugin
import com.truenavo.truenavo.configurationrestore.ConfigurationRestoreFilePlugin
import com.truenavo.truenavo.tlstrust.PinnedRpcPlugin
import com.truenavo.truenavo.tlstrust.PresentedLeafProbePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val presentedLeafProbe = PresentedLeafProbePlugin()
    private val pinnedRpc = PinnedRpcPlugin()
    private val configurationBackupFile = ConfigurationBackupFilePlugin()
    private val configurationRestoreFile = ConfigurationRestoreFilePlugin()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        presentedLeafProbe.attach(messenger)
        pinnedRpc.attach(messenger)
        configurationBackupFile.attach(this, messenger)
        configurationRestoreFile.attach(this, messenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        presentedLeafProbe.detach()
        pinnedRpc.detach()
        configurationBackupFile.detach()
        configurationRestoreFile.detach()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (configurationRestoreFile.onActivityResult(requestCode, resultCode, data)) return
        if (configurationBackupFile.onActivityResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }
}

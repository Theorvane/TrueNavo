package com.trueraid.trueraid

import android.content.Intent
import com.trueraid.trueraid.configurationbackup.ConfigurationBackupFilePlugin
import com.trueraid.trueraid.configurationrestore.ConfigurationRestoreFilePlugin
import com.trueraid.trueraid.tlstrust.PinnedRpcPlugin
import com.trueraid.trueraid.tlstrust.PresentedLeafProbePlugin
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

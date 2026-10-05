package com.truenavo.truenavo.configurationbackup

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.OutputStream
import java.util.concurrent.Executors

/** Storage Access Framework only: no broad permission, private copy or path API. */
class ConfigurationBackupFilePlugin : MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var activity: Activity? = null
    private var picker: ((String?) -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())
    private var executor = Executors.newSingleThreadExecutor()
    private var cancellationExecutor = Executors.newSingleThreadExecutor()
    private var core: ConfigurationBackupFileCore? = null

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        this.activity = activity
        if (executor.isShutdown) executor = Executors.newSingleThreadExecutor()
        if (cancellationExecutor.isShutdown) cancellationExecutor = Executors.newSingleThreadExecutor()
        core = ConfigurationBackupFileCore(
            choose = { filename, completed ->
                picker = completed
                val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "application/octet-stream"
                    putExtra(Intent.EXTRA_TITLE, filename)
                }
                try { activity.startActivityForResult(intent, REQUEST_CODE) }
                catch (error: Throwable) { picker = null; throw error }
            },
            target = { selected -> AndroidWriteTarget(activity, Uri.parse(selected), cancellationExecutor) },
            execute = { task -> executor.execute(task) },
        )
        channel = MethodChannel(messenger, "truenavo.configuration_backup_file.v1").also { it.setMethodCallHandler(this) }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val completed = picker
        picker = null
        completed?.invoke(if (resultCode == Activity.RESULT_OK) data?.data?.toString() else null)
        return true
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val current = core
        if (current == null) { result.error("unavailable", "Document saving unavailable.", null); return }
        val respond: (Map<String, Any>) -> Unit = { response -> main.post { result.success(response) } }
        when (call.method) {
            "chooseDocument" -> current.chooseDocument(call.arguments, respond)
            "writeSelectedDocument" -> current.writeSelectedDocument(call.arguments, respond)
            "cancelDocument" -> { current.cancelDocument(call.arguments); result.success(null) }
            else -> result.notImplemented()
        }
    }

    fun detach() {
        core?.close(); core = null; picker = null; activity = null
        channel?.setMethodCallHandler(null); channel = null
        executor.shutdown()
        cancellationExecutor.shutdown()
    }
    companion object { const val REQUEST_CODE = 0x54B1 }
}

private class AndroidWriteTarget(private val activity: Activity, private val uri: Uri, private val cancellationExecutor: java.util.concurrent.Executor) : ConfigurationBackupWriteTarget {
    private val cancellation = CancellationSignal()
    @Volatile private var output: OutputStream? = null
    override fun open(): OutputStream {
        cancellation.throwIfCanceled()
        val descriptor = activity.contentResolver.openAssetFileDescriptor(uri, "w", cancellation)
            ?: throw IllegalStateException("Document unavailable.")
        val stream = try { descriptor.createOutputStream() }
        catch (error: Throwable) { descriptor.close(); throw error }
        output = stream
        if (cancellation.isCanceled) { stream.close(); throw IllegalStateException("Document save cancelled.") }
        return stream
    }
    override fun cancel() {
        cancellationExecutor.execute {
            try { cancellation.cancel(); output?.close() } catch (_: Throwable) {}
            finally { output = null }
        }
    }
}

package com.trueraid.trueraid.configurationrestore

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.util.concurrent.Executor
import java.util.concurrent.Executors

/** User-selected read-only SAF access. No persisted grant, filename query,
 * temporary file, upload, or broad storage permission is exposed here. */
class ConfigurationRestoreFilePlugin : MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var picker: ((String?) -> Unit)? = null
    private val main = Handler(Looper.getMainLooper())
    private var worker = Executors.newSingleThreadExecutor()
    private var cancellationWorker = Executors.newSingleThreadExecutor()
    private var core: ConfigurationRestoreFileCore? = null

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        if (worker.isShutdown) worker = Executors.newSingleThreadExecutor()
        if (cancellationWorker.isShutdown) cancellationWorker = Executors.newSingleThreadExecutor()
        core = ConfigurationRestoreFileCore(
            choose = { completed ->
                picker = completed
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                try { activity.startActivityForResult(intent, REQUEST_CODE) }
                catch (error: Throwable) { picker = null; throw error }
            },
            target = { selected -> AndroidReadTarget(activity, Uri.parse(selected), cancellationWorker) },
            execute = { task -> worker.execute(task) },
        )
        channel = MethodChannel(messenger, "trueraid.configuration_restore_file.v1").also { it.setMethodCallHandler(this) }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val completed = picker; picker = null
        completed?.invoke(if (resultCode == Activity.RESULT_OK) data?.data?.toString() else null)
        return true
    }
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val current = core
        if (current == null) { result.error("unavailable", "Document reading unavailable.", null); return }
        val respond: (Map<String, Any>) -> Unit = { response ->
            main.post {
                try { result.success(response) }
                finally { response.values.filterIsInstance<ByteArray>().forEach { it.fill(0) } }
            }
        }
        when (call.method) {
            "chooseDocument" -> current.chooseDocument(call.arguments, respond)
            "readSelectedDocument" -> current.readSelectedDocument(call.arguments, respond)
            "cancelDocument" -> { current.cancelDocument(call.arguments); result.success(null) }
            else -> result.notImplemented()
        }
    }
    fun detach() {
        core?.close(); core = null; picker = null
        channel?.setMethodCallHandler(null); channel = null
        worker.shutdown(); cancellationWorker.shutdown()
    }
    companion object { const val REQUEST_CODE = 0x54B2 }
}

private class AndroidReadTarget(private val activity: Activity, private val uri: Uri, private val cancellationWorker: Executor) : ConfigurationRestoreReadTarget {
    private val cancellation = CancellationSignal()
    @Volatile private var input: InputStream? = null
    override fun open(): InputStream {
        cancellation.throwIfCanceled()
        val descriptor = activity.contentResolver.openAssetFileDescriptor(uri, "r", cancellation)
            ?: throw IllegalStateException("Document unavailable.")
        val stream = try { descriptor.createInputStream() }
        catch (error: Throwable) { descriptor.close(); throw error }
        input = stream
        if (cancellation.isCanceled) { stream.close(); throw IllegalStateException("Document read cancelled.") }
        return stream
    }
    override fun cancel() {
        cancellationWorker.execute {
            try { cancellation.cancel(); input?.close() } catch (_: Throwable) {}
            finally { input = null }
        }
    }
}

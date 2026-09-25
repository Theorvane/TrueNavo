package com.trueraid.trueraid.configurationbackup

import java.io.OutputStream
import java.net.URI

internal interface ConfigurationBackupWriteTarget {
    fun open(): OutputStream
    fun cancel()
}

/** Two-phase, one-use user selection. No URI is supplied by Dart or returned to
 * Dart; no bytes are accepted until the OS picker has completed. */
internal class ConfigurationBackupFileCore(
    private val choose: (String, (String?) -> Unit) -> Unit,
    private val target: (String) -> ConfigurationBackupWriteTarget,
    private val execute: (() -> Unit) -> Unit,
) {
    private val lock = Any()
    private var active: Selection? = null
    private var pickerPending = false
    private var workerRunning = false

    fun chooseDocument(raw: Any?, completion: (Map<String, Any>) -> Unit) {
        val values = args(raw, setOf("protocolVersion", "operationId", "filename"))
        val id = values?.get("operationId") as? String
        val name = values?.get("filename")
        if (id == null || name !in setOf("truenas-configuration.db", "truenas-configuration.tar")) {
            completion(response(id, "failed")); return
        }
        val selection = Selection(id, completion)
        synchronized(lock) {
            if (active != null || pickerPending || workerRunning) { completion(response(id, "failed")); return }
            active = selection
            pickerPending = true
        }
        try {
            choose(name as String) { uri ->
                synchronized(lock) {
                    pickerPending = false
                    if (active !== selection) return@choose
                    if (!validContentUri(uri)) {
                        active = null
                        selection.finishChoose(response(id, if (uri == null) "cancelled" else "failed"))
                    } else {
                        selection.uri = uri
                        selection.finishChoose(response(id, "selected"))
                    }
                }
            }
        } catch (_: Throwable) {
            synchronized(lock) {
                pickerPending = false
                if (active === selection) active = null
                selection.finishChoose(response(id, "failed"))
            }
        }
    }

    fun writeSelectedDocument(raw: Any?, completion: (Map<String, Any>) -> Unit) {
        val values = args(raw, setOf("protocolVersion", "operationId", "bytes"))
        val id = values?.get("operationId") as? String
        val bytes = (raw as? Map<*, *>)?.get("bytes") as? ByteArray
        val selected: Selection
        synchronized(lock) {
            val current = active
            if (values == null || id == null || bytes == null || bytes.isEmpty() || bytes.size > MAX_BYTES ||
                current == null || current.id != id || current.uri == null || current.write != null) {
                bytes?.fill(0); completion(response(id, "failed")); return
            }
            selected = current
            selected.bytes = bytes
            selected.write = completion
            try { selected.target = target(selected.uri!!) }
            catch (_: Throwable) { active = null; bytes.fill(0); selected.finishWrite(response(id, "failed")); return }
            workerRunning = true
        }
        try { execute { write(selected) } }
        catch (_: Throwable) { synchronized(lock) { workerRunning = false }; cancelSelection(selected, "failed") }
    }

    private fun write(selected: Selection) {
        var outcome = "failed"
        val bytes = selected.bytes ?: return
        try {
            if (selected.cancelled) return
            selected.target!!.open().use { output ->
                var offset = 0
                while (offset < bytes.size && !selected.cancelled) {
                    val count = minOf(8192, bytes.size - offset)
                    output.write(bytes, offset, count)
                    offset += count
                }
                if (selected.cancelled) outcome = "cancelled"
                else { output.flush(); outcome = "saved" }
            }
        } catch (_: Throwable) { outcome = if (selected.cancelled) "cancelled" else "failed" }
        finally {
            bytes.fill(0)
            synchronized(lock) {
                if (active === selected) active = null
                workerRunning = false
                selected.bytes = null; selected.uri = null; selected.target = null
                selected.finishWrite(response(selected.id, outcome))
            }
        }
    }

    fun cancelDocument(raw: Any?) {
        val id = args(raw, setOf("protocolVersion", "operationId"))?.get("operationId")
        val selection = synchronized(lock) { active?.takeIf { it.id == id } } ?: return
        cancelSelection(selection, "cancelled")
    }
    fun close() { synchronized(lock) { active }?.let { cancelSelection(it, "cancelled") } }
    private fun cancelSelection(selection: Selection, status: String) {
        val cancelledTarget: ConfigurationBackupWriteTarget?
        synchronized(lock) {
            if (active !== selection) return
            active = null
            selection.cancelled = true
            cancelledTarget = selection.target
            selection.bytes?.fill(0)
            selection.uri = null
            selection.finishChoose(response(selection.id, status))
            selection.finishWrite(response(selection.id, status))
        }
        // Provider cancellation may involve another process. Never hold our
        // state lock while it runs; the Android adapter also keeps it off main.
        try { cancelledTarget?.cancel() } catch (_: Throwable) {}
    }

    private class Selection(val id: String, var choose: ((Map<String, Any>) -> Unit)?) {
        var write: ((Map<String, Any>) -> Unit)? = null
        var uri: String? = null
        var target: ConfigurationBackupWriteTarget? = null
        var bytes: ByteArray? = null
        @Volatile var cancelled = false
        fun finishChoose(value: Map<String, Any>) { choose?.invoke(value); choose = null }
        fun finishWrite(value: Map<String, Any>) { write?.invoke(value); write = null }
    }
    companion object {
        const val MAX_BYTES = 16 * 1024 * 1024
        private fun args(raw: Any?, keys: Set<String>): Map<*, *>? {
            val map = raw as? Map<*, *> ?: return null
            if (map.keys != keys || map["protocolVersion"] != 1 ||
                map["operationId"] !is String || !Regex("[0-9]{1,20}-[0-9]{1,10}").matches(map["operationId"] as String)) return null
            return map
        }
        private fun validContentUri(raw: String?): Boolean = try {
            val uri = raw?.let { URI(it) }
            uri?.scheme == "content" && !uri.rawAuthority.isNullOrEmpty() && uri.userInfo == null
        } catch (_: Throwable) { false }
        private fun response(id: String?, status: String): Map<String, Any> = mapOf("protocolVersion" to 1, "operationId" to (id ?: ""), "status" to status)
    }
}

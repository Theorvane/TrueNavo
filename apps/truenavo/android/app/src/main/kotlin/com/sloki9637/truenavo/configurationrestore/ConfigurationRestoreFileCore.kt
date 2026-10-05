package com.sloki9637.truenavo.configurationrestore

import java.io.InputStream
import java.net.URI

internal interface ConfigurationRestoreReadTarget { fun open(): InputStream; fun cancel() }

/** Read-only, two-phase, one-use OS selection. Never accepts a caller URI. */
internal class ConfigurationRestoreFileCore(
    private val choose: ((String?) -> Unit) -> Unit,
    private val target: (String) -> ConfigurationRestoreReadTarget,
    private val execute: (() -> Unit) -> Unit,
) {
    private val lock = Any()
    private var active: Selection? = null
    private var pickerPending = false
    private var workerRunning = false

    fun chooseDocument(raw: Any?, completion: (Map<String, Any>) -> Unit) {
        val id = identifier(raw)
        if (id == null) { completion(response(null, "failed")); return }
        val selected = Selection(id, completion)
        synchronized(lock) {
            if (active != null || pickerPending || workerRunning) { completion(response(id, "failed")); return }
            active = selected; pickerPending = true
        }
        try {
            choose { uri ->
                synchronized(lock) {
                    pickerPending = false
                    if (active !== selected) return@choose
                    if (!validContentUri(uri)) {
                        active = null
                        selected.finishChoose(response(id, if (uri == null) "cancelled" else "failed"))
                    } else { selected.uri = uri; selected.finishChoose(response(id, "selected")) }
                }
            }
        } catch (_: Throwable) {
            synchronized(lock) {
                pickerPending = false
                if (active === selected) active = null
                selected.finishChoose(response(id, "failed"))
            }
        }
    }

    fun readSelectedDocument(raw: Any?, completion: (Map<String, Any>) -> Unit) {
        val id = identifier(raw)
        val selected: Selection
        synchronized(lock) {
            val current = active
            if (id == null || current == null || current.id != id || current.uri == null || current.read != null || workerRunning) {
                completion(response(id, "failed")); return
            }
            selected = current; selected.read = completion
            try { selected.target = target(selected.uri!!) }
            catch (_: Throwable) { active = null; selected.finishRead(response(id, "failed")); return }
            workerRunning = true
        }
        try { execute { read(selected) } }
        catch (_: Throwable) { synchronized(lock) { workerRunning = false }; cancelSelection(selected, "failed") }
    }

    private fun read(selected: Selection) {
        val storage = ByteArray(MAX_BYTES + 1)
        var result: ByteArray? = null
        var status = "failed"
        try {
            if (selected.cancelled) return
            selected.target!!.open().use { input ->
                var used = 0
                while (!selected.cancelled) {
                    val count = input.read(storage, used, storage.size - used)
                    if (count < 0) break
                    used += count
                    if (used > MAX_BYTES) throw IllegalStateException("Read unavailable.")
                }
                if (selected.cancelled) status = "cancelled"
                else if (used > 0) { result = storage.copyOf(used); status = "read" }
            }
        } catch (_: Throwable) { result?.fill(0); result = null; status = if (selected.cancelled) "cancelled" else "failed" }
        finally {
            storage.fill(0)
            synchronized(lock) {
                workerRunning = false
                if (active === selected) {
                    active = null
                    val bytes = result
                    selected.finishRead(if (bytes == null) response(selected.id, status) else response(selected.id, "read") + ("bytes" to bytes))
                } else result?.fill(0)
                selected.uri = null; selected.target = null
            }
        }
    }

    fun cancelDocument(raw: Any?) {
        val id = identifier(raw)
        val selected = synchronized(lock) { active?.takeIf { it.id == id } } ?: return
        cancelSelection(selected, "cancelled")
    }
    fun close() { synchronized(lock) { active }?.let { cancelSelection(it, "cancelled") } }
    private fun cancelSelection(selected: Selection, status: String) {
        val reader: ConfigurationRestoreReadTarget?
        synchronized(lock) {
            if (active !== selected) return
            active = null; selected.cancelled = true; reader = selected.target; selected.uri = null
            selected.finishChoose(response(selected.id, status)); selected.finishRead(response(selected.id, status))
        }
        // Adapter must schedule potentially blocking provider cancellation off main.
        try { reader?.cancel() } catch (_: Throwable) {}
    }
    private class Selection(val id: String, var choose: ((Map<String, Any>) -> Unit)?) {
        var read: ((Map<String, Any>) -> Unit)? = null
        var uri: String? = null
        var target: ConfigurationRestoreReadTarget? = null
        @Volatile var cancelled = false
        fun finishChoose(value: Map<String, Any>) { choose?.invoke(value); choose = null }
        fun finishRead(value: Map<String, Any>) { read?.invoke(value); read = null }
    }
    companion object {
        const val MAX_BYTES = 10 * 1024 * 1024
        private fun identifier(raw: Any?): String? {
            val map = raw as? Map<*, *> ?: return null
            val id = map["operationId"] as? String ?: return null
            return id.takeIf { map.keys == setOf("protocolVersion", "operationId") && map["protocolVersion"] == 1 && Regex("[0-9]{1,20}-[0-9]{1,10}").matches(it) }
        }
        private fun validContentUri(raw: String?): Boolean = try {
            val uri = raw?.let { URI(it) }
            uri?.scheme == "content" && !uri.rawAuthority.isNullOrEmpty() && uri.userInfo == null
        } catch (_: Throwable) { false }
        private fun response(id: String?, status: String): Map<String, Any> = mapOf("protocolVersion" to 1, "operationId" to (id ?: ""), "status" to status)
    }
}

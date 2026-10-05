package com.truenavo.truenavo.tlstrust

internal const val MAXIMUM_CONFIGURATION_BACKUP_BYTES = 16 * 1024 * 1024

internal class ConfigurationBackupDownloadRequest private constructor(val jobId: Long, val token: String) {
    companion object {
        fun parse(job: Any?, relative: Any?): ConfigurationBackupDownloadRequest? {
            val id = when (job) { is Int -> job.toLong(); is Long -> job; else -> return null }
            if (id <= 0 || id > 9007199254740991L || relative !is String) return null
            val match = Regex("/_download/([1-9][0-9]{0,15})\\?auth_token=([A-Za-z0-9_-]{32,512})").matchEntire(relative) ?: return null
            if (match.groupValues[1] != id.toString()) return null
            return ConfigurationBackupDownloadRequest(id, match.groupValues[2])
        }
    }
}

internal fun interface PinnedDownloadHandle { fun cancel() }
internal interface ConfigurationBackupPinnedSocket {
    fun download(request: ConfigurationBackupDownloadRequest, completion: (ByteArray?) -> Unit): PinnedDownloadHandle
}

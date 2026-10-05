package com.sloki9637.truenavo.tlstrust

internal const val MAXIMUM_CONFIGURATION_RESTORE_BYTES = 10 * 1024 * 1024

internal interface ConfigurationRestorePinnedSocket {
    /** Consumes bytes on every outcome; cancellation clears only after last use. */
    fun upload(token: String, bytes: ByteArray, completion: (Long?) -> Unit): PinnedDownloadHandle
}

internal fun validRestoreToken(value: Any?): Boolean =
    value is String && Regex("[A-Za-z0-9_-]{32,512}").matches(value)

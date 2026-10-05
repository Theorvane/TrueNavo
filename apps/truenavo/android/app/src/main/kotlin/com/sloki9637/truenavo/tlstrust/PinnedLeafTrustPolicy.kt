package com.sloki9637.truenavo.tlstrust

import java.security.MessageDigest
import java.security.cert.CertificateExpiredException
import java.security.cert.CertificateNotYetValidException
import java.security.cert.X509Certificate
import java.util.Date

/// The deterministic policy boundary applied during the pinned handshake. It
/// checks the exact DER leaf before the TLS stack is allowed to complete the
/// connection, making the security-sensitive ordering testable. Certificate
/// hostname matching stays with the platform verifier that runs after this.
internal object PinnedLeafTrustPolicy {

    fun evaluate(
        expectedHost: String,
        presentedHost: String,
        expectedDigest: ByteArray,
        leaf: X509Certificate?,
        verifyDate: Date,
    ): String? {
        val challengeHost = presentedHost.removeSurrounding("[", "]").lowercase()
        if (expectedHost != challengeHost) return "hostnameMismatch"
        if (leaf == null) return "malformedCertificate"
        val der = try {
            leaf.encoded
        } catch (error: Throwable) {
            return "malformedCertificate"
        }
        if (der.isEmpty() || der.size > BridgeProtocol.MAXIMUM_DER_BYTES) return "malformedCertificate"
        val digest = MessageDigest.getInstance("SHA-256").digest(der)
        if (!BridgeProtocol.constantTimeEquals(digest, expectedDigest)) return "pinMismatch"
        return try {
            leaf.checkValidity(verifyDate)
            null
        } catch (error: CertificateNotYetValidException) {
            "notYetValidCertificate"
        } catch (error: CertificateExpiredException) {
            "expiredCertificate"
        } catch (error: Throwable) {
            "malformedCertificate"
        }
    }
}

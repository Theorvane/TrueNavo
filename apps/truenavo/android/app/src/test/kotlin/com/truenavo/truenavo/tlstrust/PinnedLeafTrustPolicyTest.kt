package com.truenavo.truenavo.tlstrust

import java.io.ByteArrayInputStream
import java.security.MessageDigest
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.Date
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/// A checked-in, non-production self-signed certificate for `nas.example.test`.
/// It is never used by the app and exists only to make the pinning policy
/// deterministic; the test derives every date from the fixture itself.
private const val FIXTURE_DER_BASE64 =
        "MIIDNDCCAhygAwIBAgIUY08pGW8g75JcRZ/ATdb/VHup2vQwDQYJKoZIhvcNAQELBQAwGzEZMBcG" +
        "A1UEAwwQbmFzLmV4YW1wbGUudGVzdDAeFw0yNjA5MDcxNzQ4NDdaFw0zNjA5MDQxNzQ4NDdaMBsx" +
        "GTAXBgNVBAMMEG5hcy5leGFtcGxlLnRlc3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIB" +
        "AQCv0kCXSraMDfmnAzYcfoePskF63yRe+V5kFSz9I7pI9XHnwYmc9aVFo9/XDZJmLzLhupKwH5tD" +
        "n3uzAY4XybxCku/m8QEBoGk3/tqyYbPwUOtCYQfdnhvpTXkFiTZ1u74tS3tmfrJSGVltxiwSKQFO" +
        "7Pe/3T7f5qBn8ViPx83Y39/0cuJ4V2QQ662klqxIaZvN+MPYuAu8rSz+b/EYpo5EpMA1uqLMk0Aa" +
        "1QnQRI1KsLeF78NMJ5CnGq/k0YaBEC73u7c4n/Aimv5HtCNdxwpt9LOk5WBiFJdHcXa9w0XJliZm" +
        "NkiFlUE22UZdSiqgF53EIQyeVAlzSQ4+AtT/82G3AgMBAAGjcDBuMB0GA1UdDgQWBBTNlqn3liXg" +
        "ohkswpD54o/bVT3p/jAfBgNVHSMEGDAWgBTNlqn3liXgohkswpD54o/bVT3p/jAPBgNVHRMBAf8E" +
        "BTADAQH/MBsGA1UdEQQUMBKCEG5hcy5leGFtcGxlLnRlc3QwDQYJKoZIhvcNAQELBQADggEBAFIk" +
        "FlMX5rR58HIsbkfUS6SjEgi0oyeEgbUDwfKpt7Q2/uLgYvB7aPgexKAvCcaRfhjOxhupzGmXVjh6" +
        "ldqniHrBSaVVrvoUulKdin5rHtOCkLMgvkLbTUVRc1OSEBqG3ySdBVKd6k9up6RsEVHT5UjZOK5A" +
        "5Q50n3D8usWnumZDRvESYkNulV7TLTNOIz9WNN6f9gxZ5A5lkVSFUPrOIYAZnsw+yq9ZPU83T7TG" +
        "/SLyOehE8GPfqdNw38dGGISAbB/EdM6pJvd4OKeW1w2+ylIcAlPRF593HhnxQaQUojpkkMURXrna" +
        "58NLxXLyjx0mb2VwPaR69mKpEwkx9BNr6EM="

class PinnedLeafTrustPolicyTest {
    private val leaf: X509Certificate = CertificateFactory.getInstance("X.509")
        .generateCertificate(ByteArrayInputStream(decode(FIXTURE_DER_BASE64))) as X509Certificate
    private val digest: ByteArray = MessageDigest.getInstance("SHA-256").digest(leaf.encoded)
    private val insideValidity = Date(
        (leaf.notBefore.time + leaf.notAfter.time) / 2,
    )

    @Test
    fun `the exact pinned leaf inside its validity window is accepted`() {
        assertNull(evaluate(digest = digest, verifyDate = insideValidity))
    }

    @Test
    fun `a different leaf digest is a pin mismatch`() {
        val other = digest.copyOf()
        other[0] = (other[0] + 1).toByte()
        assertEquals("pinMismatch", evaluate(digest = other, verifyDate = insideValidity))
    }

    @Test
    fun `a mismatched authority is refused before the digest is compared`() {
        val other = digest.copyOf()
        other[0] = (other[0] + 1).toByte()
        assertEquals(
            "hostnameMismatch",
            evaluate(presentedHost = "other.example.test", digest = other, verifyDate = insideValidity),
        )
    }

    @Test
    fun `a bracketed IPv6 challenge host still matches its bracketless pin`() {
        assertEquals(
            "pinMismatch",
            PinnedLeafTrustPolicy.evaluate(
                expectedHost = "2001:db8::1",
                presentedHost = "[2001:DB8::1]",
                expectedDigest = ByteArray(32),
                leaf = leaf,
                verifyDate = insideValidity,
            ),
        )
    }

    @Test
    fun `an expired or not yet valid leaf is refused with its exact reason`() {
        assertEquals(
            "notYetValidCertificate",
            evaluate(digest = digest, verifyDate = Date(leaf.notBefore.time - 1000)),
        )
        assertEquals(
            "expiredCertificate",
            evaluate(digest = digest, verifyDate = Date(leaf.notAfter.time + 1000)),
        )
    }

    @Test
    fun `an absent leaf is malformed rather than trusted`() {
        assertEquals(
            "malformedCertificate",
            PinnedLeafTrustPolicy.evaluate(
                expectedHost = "nas.example.test",
                presentedHost = "nas.example.test",
                expectedDigest = digest,
                leaf = null,
                verifyDate = insideValidity,
            ),
        )
    }

    private fun evaluate(
        presentedHost: String = "nas.example.test",
        digest: ByteArray,
        verifyDate: Date,
    ) = PinnedLeafTrustPolicy.evaluate(
        expectedHost = "nas.example.test",
        presentedHost = presentedHost,
        expectedDigest = digest,
        leaf = leaf,
        verifyDate = verifyDate,
    )
}

private fun decode(value: String): ByteArray {
    val alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    val bits = StringBuilder()
    for (character in value) {
        if (character == '=') continue
        val index = alphabet.indexOf(character)
        require(index >= 0) { "Unexpected base64 character." }
        bits.append(index.toString(2).padStart(6, '0'))
    }
    val bytes = ByteArray(bits.length / 8)
    for (index in bytes.indices) {
        bytes[index] = bits.substring(index * 8, index * 8 + 8).toInt(2).toByte()
    }
    return bytes
}

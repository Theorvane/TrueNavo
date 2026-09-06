import Foundation
import Network
import CryptoKit
import XCTest

final class RunnerTests: XCTestCase {
  func testPinnedValidityUsesOnlyTBSCertificateValidity() {
    let der = pinnedValidityDER(issuerTime: "500101000000Z", before: "260101000000Z", after: "270101000000Z")
    let validity = DERValidity(der)
    XCTAssertNotNil(validity)
    XCTAssertTrue(validity!.contains(Date(timeIntervalSince1970: 1_790_000_000)))
    XCTAssertTrue(validity!.isNotYetValid(at: Date(timeIntervalSince1970: 1_700_000_000)))
    XCTAssertNil(DERValidity(pinnedValidityDER(issuerTime: nil, before: "270101000000Z", after: "260101000000Z")))
    var nonCanonical = pinnedValidityDER(issuerTime: nil, before: "260101000000Z", after: "270101000000Z")
    nonCanonical[1] = 0x81
    XCTAssertNil(DERValidity(nonCanonical))
  }

  func testPinnedRequestAllowsCanonicalSingleLabelAndRejectsAuthorityTricks() {
    let id = "0123456789abcdef0123456789abcdef"
    func request(_ host: String, _ path: String = "/rpc", _ digest: String = String(repeating: "A", count: 64)) -> [String: Any] { ["protocolVersion": 1, "operationId": id, "host": host, "port": 443, "rpcPath": path, "leafDerSha256": digest] }
    XCTAssertNotNil(PinnedRpcRequest(request("nas")))
    let ipv6 = PinnedRpcRequest(request("2001:db8::1"))
    XCTAssertEqual(ipv6?.host, "2001:db8::1")
    XCTAssertEqual(ipv6?.url.absoluteString, "wss://[2001:db8::1]:443/rpc")
    XCTAssertEqual(PinnedRpcRequest(request("::1"))?.url.absoluteString, "wss://[::1]:443/rpc")
    for host in ["-nas", "nas-", "na s", "nas..test", "[::1]", "127.000.000.001", "2001:0db8::1", "nas%2ftest"] { XCTAssertNil(PinnedRpcRequest(request(host))) }
    for path in ["rpc", "/../rpc", "/rpc?x", "/rpc#x", "/rpc%2fnext", "/rpc path", "/r\u{00e9}", "/rpc\n"] { XCTAssertNil(PinnedRpcRequest(request("nas", path))) }
    XCTAssertNil(PinnedRpcRequest(request("nas", "/rpc", String(repeating: "a", count: 64))))
    XCTAssertNil(PinnedRpcRequest(request(String(repeating: "a", count: 64) + "." + String(repeating: "b", count: 64) + "." + String(repeating: "c", count: 64) + "." + String(repeating: "d", count: 64))))
  }

  func testPinnedTrustPolicyRejectsEveryFailureBeforeSSLAndAcceptsExactLeaf() {
    let der = pinnedValidityDER(issuerTime: nil, before: "260101000000Z", after: "270101000000Z")
    let digest = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
    let raw: [String: Any] = ["protocolVersion": 1, "operationId": "0123456789abcdef0123456789abcdef", "host": "nas.example.test", "port": 443, "rpcPath": "/rpc", "leafDerSha256": digest]
    let request = PinnedRpcRequest(raw)!
    let date = Date(timeIntervalSince1970: 1_780_000_000)
    var sslCalls = 0
    XCTAssertNil(PinnedLeafTrustPolicy.evaluate(request: request, presentedHost: "nas.example.test", leafDER: der, verifyDate: date) { sslCalls += 1; return nil })
    XCTAssertEqual(sslCalls, 1)
    for (host, leaf, when, expected) in [("other.example.test", der, date, "hostnameMismatch"), ("nas.example.test", Data([0]), date, "pinMismatch"), ("nas.example.test", der, Date(timeIntervalSince1970: 1_900_000_000), "expiredCertificate"), ("nas.example.test", der, Date(timeIntervalSince1970: 1_700_000_000), "notYetValidCertificate")] {
      sslCalls = 0
      XCTAssertEqual(PinnedLeafTrustPolicy.evaluate(request: request, presentedHost: host, leafDER: leaf, verifyDate: when) { sslCalls += 1; return nil }, expected)
      XCTAssertEqual(sslCalls, 0)
    }
    XCTAssertEqual(PinnedLeafTrustPolicy.evaluate(request: request, presentedHost: "nas.example.test", leafDER: der, verifyDate: date) { "malformedCertificate" }, "malformedCertificate")
    let malformed = Data([0])
    let malformedDigest = SHA256.hash(data: malformed).map { String(format: "%02X", $0) }.joined()
    let malformedRequest = PinnedRpcRequest(["protocolVersion": 1, "operationId": "fedcba9876543210fedcba9876543210", "host": "nas.example.test", "port": 443, "rpcPath": "/rpc", "leafDerSha256": malformedDigest])!
    XCTAssertEqual(PinnedLeafTrustPolicy.evaluate(request: malformedRequest, presentedHost: "nas.example.test", leafDER: malformed, verifyDate: date) { XCTFail("must not evaluate malformed DER"); return nil }, "malformedCertificate")
  }

  func testPinnedOperationStateEmitsSuccessOnlyAfterOpenAndOnlyOnce() {
    let state = PinnedOperationState()
    XCTAssertFalse(state.finishOpen())
    state.acceptTrust()
    XCTAssertTrue(state.finishOpen())
    XCTAssertFalse(state.finishOpen())
    XCTAssertFalse(state.finishFailure())
    let cancelled = PinnedOperationState()
    XCTAssertTrue(cancelled.finishFailure())
    cancelled.acceptTrust()
    XCTAssertFalse(cancelled.finishOpen())
  }
  func testPinnedRpcRejectsStrictRequestsBeforeNetworkCreation() {
    let core = ApplePinnedRpcCore()
    let id = "0123456789abcdef0123456789abcdef"
    let invalid: [[String: Any]] = [
      ["protocolVersion": 1, "operationId": id, "host": "NAS.example.test", "port": 443, "rpcPath": "/rpc", "leafDerSha256": String(repeating: "a", count: 64)],
      ["protocolVersion": 1, "operationId": id, "host": "nas.example.test", "port": 443, "rpcPath": "/../rpc", "leafDerSha256": String(repeating: "a", count: 64)],
      ["protocolVersion": 1, "operationId": id, "host": "127.000.000.001", "port": 443, "rpcPath": "/rpc", "leafDerSha256": String(repeating: "a", count: 64)],
      ["protocolVersion": 1, "operationId": id, "host": "nas.example.test", "port": 443, "rpcPath": "/rpc?x", "leafDerSha256": String(repeating: "a", count: 64)],
    ]
    for (index, request) in invalid.enumerated() {
      let done = expectation(description: "pinned invalid \(index)")
      core.connect(request) { response in
        XCTAssertEqual(response["failureCode"] as? String, "malformedCertificate")
        done.fulfill()
      }
      wait(for: [done], timeout: 1)
    }
  }

  func testPinnedRpcRejectsMalformedSessionMethodsWithFixedClosedMap() {
    let core = ApplePinnedRpcCore()
    for call in [core.send, core.receive, core.close] {
      let done = expectation(description: "bad session")
      call(["protocolVersion": 1, "sessionId": "BAD"]) { response in
        XCTAssertEqual(response["closed"] as? Bool, true)
        XCTAssertEqual(response["sessionId"] as? String, String(repeating: "0", count: 32))
        done.fulfill()
      }
      wait(for: [done], timeout: 1)
    }
  }

  #if DEBUG
  func testPinnedRpcCancelRemovesEstablishedOperationAndSession() {
    let core = ApplePinnedRpcCore()
    let id = "11111111111111111111111111111111"
    let opened = expectation(description: "opened")
    guard let fixture = core.debugInstallAcceptedOperation(operationId: id, completion: { response in
      XCTAssertEqual(response["operationId"] as? String, id)
      opened.fulfill()
    }) else { return XCTFail("fixture must install") }

    core.urlSession(fixture.session, webSocketTask: fixture.task, didOpenWithProtocol: nil)
    wait(for: [opened], timeout: 1)
    XCTAssertEqual(core.debugStateSnapshot, ApplePinnedRpcDebugStateSnapshot(operationCount: 1, taskCount: 1, sessionCount: 1))

    let cancelled = expectation(description: "cancelled")
    core.cancel(["protocolVersion": 1, "operationId": id]) { response in
      XCTAssertEqual(response["failureCode"] as? String, "cancelled")
      cancelled.fulfill()
    }
    wait(for: [cancelled], timeout: 1)
    XCTAssertEqual(core.debugStateSnapshot, .init(operationCount: 0, taskCount: 0, sessionCount: 0))
  }

  func testPinnedRpcCompletionRemovesAcceptedSessionAndResolvesPendingReceiveOnce() {
    let core = ApplePinnedRpcCore()
    let id = "22222222222222222222222222222222"
    let opened = expectation(description: "opened")
    guard let fixture = core.debugInstallAcceptedOperation(operationId: id, completion: { _ in opened.fulfill() }) else { return XCTFail("fixture must install") }
    core.urlSession(fixture.session, webSocketTask: fixture.task, didOpenWithProtocol: nil)
    wait(for: [opened], timeout: 1)
    guard let sessionId = core.debugSessionId(for: id) else { return XCTFail("open must create session") }

    let received = expectation(description: "pending receive resolves once")
    received.expectedFulfillmentCount = 1
    var receiveCount = 0
    core.receive(["protocolVersion": 1, "sessionId": sessionId]) { response in
      receiveCount += 1
      XCTAssertEqual(response["sessionId"] as? String, sessionId)
      XCTAssertEqual(response["closed"] as? Bool, true)
      received.fulfill()
    }
    core.urlSession(fixture.session, task: fixture.task, didCompleteWithError: nil)
    wait(for: [received], timeout: 1)
    XCTAssertEqual(receiveCount, 1)
    XCTAssertEqual(core.debugStateSnapshot, .init(operationCount: 0, taskCount: 0, sessionCount: 0))
  }

  func testPinnedRpcRedirectReturnsNilAndTearsDownEstablishedState() {
    let core = ApplePinnedRpcCore()
    let id = "33333333333333333333333333333333"
    let opened = expectation(description: "opened")
    guard let fixture = core.debugInstallAcceptedOperation(operationId: id, completion: { _ in opened.fulfill() }) else { return XCTFail("fixture must install") }
    core.urlSession(fixture.session, webSocketTask: fixture.task, didOpenWithProtocol: nil)
    wait(for: [opened], timeout: 1)

    let response = HTTPURLResponse(url: URL(string: "https://nas.example.test/rpc")!, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
    var redirect: URLRequest? = URLRequest(url: URL(string: "https://other.example.test/rpc")!)
    core.urlSession(fixture.session, task: fixture.task, willPerformHTTPRedirection: response, newRequest: redirect!) { redirect = $0 }
    XCTAssertNil(redirect)
    XCTAssertEqual(core.debugStateSnapshot, .init(operationCount: 0, taskCount: 0, sessionCount: 0))
  }

  func testPinnedRpcLateOpenAndCompletionAfterCleanupCannotRecreateOrCompleteTwice() {
    let core = ApplePinnedRpcCore()
    let id = "44444444444444444444444444444444"
    let completed = expectation(description: "cancel completion")
    completed.expectedFulfillmentCount = 1
    var completionCount = 0
    guard let fixture = core.debugInstallAcceptedOperation(operationId: id, completion: { response in
      completionCount += 1
      XCTAssertEqual(response["failureCode"] as? String, "cancelled")
      completed.fulfill()
    }) else { return XCTFail("fixture must install") }

    let cancelled = expectation(description: "cancel acknowledgement")
    core.cancel(["protocolVersion": 1, "operationId": id]) { _ in cancelled.fulfill() }
    wait(for: [completed, cancelled], timeout: 1)
    core.urlSession(fixture.session, webSocketTask: fixture.task, didOpenWithProtocol: nil)
    core.urlSession(fixture.session, task: fixture.task, didCompleteWithError: nil)
    XCTAssertEqual(core.debugStateSnapshot, .init(operationCount: 0, taskCount: 0, sessionCount: 0))
    XCTAssertEqual(completionCount, 1)
  }

  func testPinnedRpcLateSuccessfulSendAfterCloseReturnsFixedClosedResponseOnce() {
    let core = ApplePinnedRpcCore()
    let id = "55555555555555555555555555555555"
    let opened = expectation(description: "opened")
    guard let fixture = core.debugInstallAcceptedOperation(operationId: id, completion: { _ in opened.fulfill() }) else { return XCTFail("fixture must install") }
    core.urlSession(fixture.session, webSocketTask: fixture.task, didOpenWithProtocol: nil)
    wait(for: [opened], timeout: 1)
    guard let sessionId = core.debugSessionId(for: id) else { return XCTFail("open must create session") }

    let sendStarted = expectation(description: "send held")
    var releaseSend: ((Error?) -> Void)?
    core.debugSend = { _, _, completion in releaseSend = completion; sendStarted.fulfill() }
    let sent = expectation(description: "send closed response")
    sent.expectedFulfillmentCount = 1
    var sendCount = 0
    core.send(["protocolVersion": 1, "sessionId": sessionId, "frame": "x"]) { response in
      sendCount += 1
      XCTAssertEqual(response["protocolVersion"] as? Int, 1)
      XCTAssertEqual(response["sessionId"] as? String, sessionId)
      XCTAssertEqual(response["closed"] as? Bool, true)
      XCTAssertEqual(response.count, 3)
      sent.fulfill()
    }
    wait(for: [sendStarted], timeout: 1)
    let closed = expectation(description: "closed")
    core.close(["protocolVersion": 1, "sessionId": sessionId]) { _ in closed.fulfill() }
    wait(for: [closed], timeout: 1)
    releaseSend?(nil)
    wait(for: [sent], timeout: 1)
    XCTAssertEqual(sendCount, 1)
  }
  #endif

  func testRequestValidationAndCancellationCompletionOnce() {
    let connection = FakeConnection()
    let core = PresentedLeafProbeCore(factory: { _, _, _, state in connection.state = state; return connection })
    let result = expectation(description: "capture completion")
    result.expectedFulfillmentCount = 1
    core.capture(["protocolVersion": 1, "operationId": "abcdefabcdefabcdefabcdefabcdefab", "host": "nas.example.test", "port": 443], completion: { response in
      XCTAssertEqual(response["failureCode"] as? String, "cancelled")
      result.fulfill()
    })
    core.cancel(["protocolVersion": 1, "operationId": "abcdefabcdefabcdefabcdefabcdefab"], completion: { _ in })
    wait(for: [result], timeout: 1)
    connection.state?(.cancelled)
    XCTAssertEqual(connection.cancelCount, 1)
  }

  func testNilTrustIsRejectedAndCompletesCaptureOnce() {
    let connection = FakeConnection()
    let ready = expectation(description: "verify installed")
    let core = PresentedLeafProbeCore(factory: { _, _, verify, state in
      connection.verify = verify
      connection.state = state
      connection.installed = { ready.fulfill() }
      return connection
    }, leafCopier: { _ in nil })
    let capture = expectation(description: "capture")
    var calls = 0
    core.capture(["protocolVersion": 1, "operationId": "1234567890abcdef1234567890abcdef", "host": "nas.example.test", "port": 443]) { response in
      calls += 1
      XCTAssertEqual(response["failureCode"] as? String, "captureFailed")
      capture.fulfill()
    }
    wait(for: [ready], timeout: 1)
    var decisions = [Bool]()
    connection.verify?(nil, { decisions.append($0) })
    connection.verify?(nil, { decisions.append($0) })
    wait(for: [capture], timeout: 1)
    XCTAssertEqual(decisions, [false, false])
    XCTAssertEqual(calls, 1)
  }

  func testInjectedPassingPlatformTrustIsReportedButCaptureStillRejects() {
    let connection = FakeConnection()
    let ready = expectation(description: "verify installed")
    let core = PresentedLeafProbeCore(factory: { _, _, verify, state in
      connection.verify = verify; connection.state = state
      connection.installed = { ready.fulfill() }; return connection
    }, leafCopier: { _ in Data([1, 2, 3]) }, platformTrustEvaluator: { _ in true })
    let captured = expectation(description: "captured")
    core.capture(request("99999999999999999999999999999999")) { response in
      XCTAssertEqual(response["platformTrust"] as? String, "passed")
      captured.fulfill()
    }
    wait(for: [ready], timeout: 1)
    var decisions = [Bool]()
    connection.verify?(nil, { decisions.append($0) })
    wait(for: [captured], timeout: 1)
    XCTAssertEqual(decisions, [false])
  }

  func testSynchronousFailureFromVerifyRejectionDoesNotDiscardCopiedLeaf() {
    let connection = FakeConnection()
    let ready = expectation(description: "verify installed")
    let core = PresentedLeafProbeCore(factory: { _, _, verify, state in
      connection.verify = verify; connection.state = state
      connection.installed = { ready.fulfill() }; return connection
    }, leafCopier: { _ in Data([1, 2, 3]) })
    let captured = expectation(description: "captured leaf")
    core.capture(request("0123456789abcdef0123456789abcdef")) { response in
      XCTAssertEqual(response["leafDerBase64"] as? String, Data([1, 2, 3]).base64EncodedString())
      XCTAssertEqual(response["platformTrust"] as? String, "didNotPass")
      captured.fulfill()
    }
    wait(for: [ready], timeout: 1)
    var decisions = [Bool]()
    connection.verify?(nil, { accepted in
      decisions.append(accepted)
      connection.state?(.failed(NWError.posix(.ECONNREFUSED)))
    })
    wait(for: [captured], timeout: 1)
    XCTAssertEqual(decisions, [false])
    XCTAssertEqual(connection.cancelCount, 1)
  }

  func testTwoOperationsCancelIndependentlyAndIdempotently() {
    let aConnection = FakeConnection(), bConnection = FakeConnection()
    let installed = expectation(description: "connections installed")
    installed.expectedFulfillmentCount = 2
    var connections = [aConnection, bConnection]
    let core = PresentedLeafProbeCore(factory: { _, _, _, state in
      let connection = connections.removeFirst(); connection.state = state
      connection.installed = { installed.fulfill() }; return connection
    })
    let a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    let aResult = expectation(description: "A result"), bResult = expectation(description: "B result")
    var aCompletions = 0
    core.capture(request(a), completion: { response in aCompletions += 1; XCTAssertEqual(response["failureCode"] as? String, "cancelled"); aResult.fulfill() })
    core.capture(request(b), completion: { response in XCTAssertEqual(response["failureCode"] as? String, "cancelled"); bResult.fulfill() })
    wait(for: [installed], timeout: 1)
    let firstCancel = expectation(description: "cancel A")
    core.cancel(cancelRequest(a), completion: { _ in firstCancel.fulfill() })
    wait(for: [aResult, firstCancel], timeout: 1)
    XCTAssertEqual(aConnection.cancelCount, 1); XCTAssertEqual(bConnection.cancelCount, 0)
    let repeatCancel = expectation(description: "repeat A")
    core.cancel(cancelRequest(a), completion: { _ in repeatCancel.fulfill() })
    wait(for: [repeatCancel], timeout: 1)
    XCTAssertEqual(aConnection.cancelCount, 1); XCTAssertEqual(aCompletions, 1)
    let bCancel = expectation(description: "cancel B")
    core.cancel(cancelRequest(b), completion: { _ in bCancel.fulfill() })
    wait(for: [bResult, bCancel], timeout: 1)
    XCTAssertEqual(bConnection.cancelCount, 1)
  }

  func testStrictRequestsDoNotCreateConnections() {
    var calls = 0
    let core = PresentedLeafProbeCore(factory: { _, _, _, _ in calls += 1; return FakeConnection() })
    let id = "0123456789abcdef0123456789abcdef"
    let invalid: [[String: Any]] = [
      ["protocolVersion": 1, "operationId": id, "host": "nas.example.test", "port": 443, "x": 1],
      ["protocolVersion": 2, "operationId": id, "host": "nas.example.test", "port": 443],
      ["protocolVersion": "1", "operationId": id, "host": "nas.example.test", "port": 443],
      ["protocolVersion": 1, "operationId": "bad", "host": "nas.example.test", "port": 443],
      ["protocolVersion": 1, "operationId": id, "host": "NAS.example.test", "port": 443],
      ["protocolVersion": 1, "operationId": id, "host": "127.000.000.001", "port": 443],
      ["protocolVersion": 1, "operationId": id, "host": "2001:0db8::1", "port": 443],
      ["protocolVersion": 1, "operationId": id, "host": "nas.example.test", "port": 0],
      ["protocolVersion": 1, "operationId": id, "host": "nas.example.test", "port": 65536],
      ["protocolVersion": 1, "operationId": id, "host": "nas.example.test", "port": "443"],
    ]
    for (index, request) in invalid.enumerated() {
      let done = expectation(description: "invalid \(index)")
      core.capture(request, completion: { response in XCTAssertEqual(response["failureCode"] as? String, "captureFailed"); done.fulfill() })
      wait(for: [done], timeout: 1)
    }
    XCTAssertEqual(calls, 0)
  }

  func testInjectedLeafBoundsAndLateCallbacksCompleteOnce() {
    for (index, leaf) in [Data(), Data(repeating: 7, count: 64 * 1024), Data(repeating: 7, count: 64 * 1024 + 1)].enumerated() {
      let connection = FakeConnection()
      let installed = expectation(description: "installed \(index)")
      let core = PresentedLeafProbeCore(factory: { _, _, verify, state in
        connection.verify = verify; connection.state = state; connection.installed = { installed.fulfill() }; return connection
      }, leafCopier: { _ in leaf })
      let complete = expectation(description: "complete \(index)")
      var responses = 0
      core.capture(request(String(format: "%032x", index + 1)), completion: { response in
        responses += 1
        if index == 1 { XCTAssertEqual((response["leafDerBase64"] as? String)?.count, leaf.base64EncodedString().count) }
        else { XCTAssertEqual(response["failureCode"] as? String, "captureFailed") }
        complete.fulfill()
      })
      wait(for: [installed], timeout: 1)
      var decisions = [Bool](); connection.verify?(nil, { decisions.append($0) }); connection.verify?(nil, { decisions.append($0) })
      connection.state?(.failed(NWError.posix(.ECONNREFUSED)))
      wait(for: [complete], timeout: 1)
      XCTAssertEqual(decisions, [false, false]); XCTAssertEqual(responses, 1)
    }
  }
}

// Synthetic DER structure only; no certificate or private-key material.
private func pinnedValidityDER(issuerTime: String?, before: String, after: String) -> Data {
  func tlv(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] { [tag, UInt8(body.count)] + body }
  let issuer = tlv(0x30, issuerTime.map { tlv(0x17, Array($0.utf8)) } ?? [])
  let validity = tlv(0x30, tlv(0x17, Array(before.utf8)) + tlv(0x17, Array(after.utf8)))
  let tbs = tlv(0x30, tlv(0x02, [1]) + tlv(0x30, []) + issuer + validity)
  return Data(tlv(0x30, tbs + tlv(0x30, []) + tlv(0x03, [0])))
}

private func request(_ id: String) -> [String: Any] { ["protocolVersion": 1, "operationId": id, "host": "nas.example.test", "port": 443] }
private func cancelRequest(_ id: String) -> [String: Any] { ["protocolVersion": 1, "operationId": id] }

private final class FakeConnection: PresentedLeafConnection {
  var verify: ((SecTrust?, @escaping VerifyDecision) -> Void)?
  var state: ((NWConnection.State) -> Void)?
  var installed: (() -> Void)?
  var cancelCount = 0
  func start() { installed?() }
  func cancel() { cancelCount += 1 }
}

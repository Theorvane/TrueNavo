import Foundation
import Network
import XCTest

final class RunnerTests: XCTestCase {
  func testRejectsMalformedProtocolWithoutTransport() {
    var called = false
    let core = PresentedLeafProbeCore(factory: { _, _, _, _ in called = true; return FakeConnection() })
    let done = expectation(description: "result")
    core.capture(["protocolVersion": 1], completion: { response in
      XCTAssertEqual(response["failureCode"] as? String, "captureFailed")
      done.fulfill()
    })
    wait(for: [done], timeout: 1)
    XCTAssertFalse(called)
  }

  func testCancellationIsOperationSpecificAndLateStateIsIgnored() {
    let fake = FakeConnection()
    let core = PresentedLeafProbeCore(factory: { _, _, _, state in fake.state = state; return fake })
    let capture = expectation(description: "capture")
    core.capture(["protocolVersion": 1, "operationId": "0123456789abcdef0123456789abcdef", "host": "nas.example.test", "port": 443], completion: { response in
      XCTAssertEqual(response["failureCode"] as? String, "cancelled")
      capture.fulfill()
    })
    let cancel = expectation(description: "cancel")
    core.cancel(["protocolVersion": 1, "operationId": "0123456789abcdef0123456789abcdef"], completion: { _ in cancel.fulfill() })
    wait(for: [capture, cancel], timeout: 1)
    fake.state?(.failed(NWError.posix(.ECONNREFUSED)))
    XCTAssertEqual(fake.cancelCount, 1)
  }

  func testVerifyAlwaysRejectsAndDuplicateCallbacksCannotCompleteTwice() {
    let fake = FakeConnection()
    let ready = expectation(description: "verify installed")
    let core = PresentedLeafProbeCore(
      factory: { _, _, verify, state in
        fake.verify = verify
        fake.state = state
        fake.installed = { ready.fulfill() }
        return fake
      },
      leafCopier: { _ in Data([1, 2, 3]) })
    let done = expectation(description: "capture")
    done.expectedFulfillmentCount = 1
    var captures = 0
    core.capture(["protocolVersion": 1, "operationId": "fedcba9876543210fedcba9876543210", "host": "nas.example.test", "port": 443]) { response in
      captures += 1
      XCTAssertNotNil(response["leafDerBase64"])
      done.fulfill()
    }
    // The factory hook is deterministic: start has installed the callbacks.
    wait(for: [ready], timeout: 1)
    var decisions = [Bool]()
    fake.verify?(nil, { decisions.append($0) })
    fake.verify?(nil, { decisions.append($0) })
    wait(for: [done], timeout: 1)
    XCTAssertEqual(decisions, [false, false])
    XCTAssertEqual(captures, 1)
    XCTAssertEqual(fake.cancelCount, 1)
  }

  func testTwoOperationsCancelIndependentlyAndIdempotently() {
    let first = FakeConnection()
    let second = FakeConnection()
    let installed = expectation(description: "both connections installed")
    installed.expectedFulfillmentCount = 2
    var connections = [first, second]
    let core = PresentedLeafProbeCore(factory: { _, _, _, state in
      let connection = connections.removeFirst()
      connection.state = state
      connection.installed = { installed.fulfill() }
      return connection
    })
    let a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    let b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    let aCapture = expectation(description: "A capture")
    let bCapture = expectation(description: "B capture")
    var aCaptures = 0
    core.capture(request(a), completion: { response in
      aCaptures += 1; XCTAssertEqual(response["failureCode"] as? String, "cancelled"); aCapture.fulfill()
    })
    core.capture(request(b), completion: { response in
      XCTAssertEqual(response["failureCode"] as? String, "cancelled"); bCapture.fulfill()
    })
    wait(for: [installed], timeout: 1)
    let firstCancel = expectation(description: "first cancel")
    core.cancel(cancelRequest(a), completion: { _ in firstCancel.fulfill() })
    wait(for: [aCapture, firstCancel], timeout: 1)
    XCTAssertEqual(first.cancelCount, 1); XCTAssertEqual(second.cancelCount, 0); XCTAssertEqual(aCaptures, 1)
    let secondCancel = expectation(description: "second cancel")
    core.cancel(cancelRequest(a), completion: { _ in secondCancel.fulfill() })
    wait(for: [secondCancel], timeout: 1)
    XCTAssertEqual(first.cancelCount, 1); XCTAssertEqual(aCaptures, 1)
    let bCancel = expectation(description: "B cancel")
    core.cancel(cancelRequest(b), completion: { _ in bCancel.fulfill() })
    wait(for: [bCapture, bCancel], timeout: 1)
    XCTAssertEqual(second.cancelCount, 1)
  }

  func testRejectsStrictRequestMatrixBeforeFactory() {
    var factoryCalls = 0
    let core = PresentedLeafProbeCore(factory: { _, _, _, _ in factoryCalls += 1; return FakeConnection() })
    let id = "0123456789abcdef0123456789abcdef"
    let cases: [[String: Any]] = [
      ["protocolVersion": 1, "operationId": id, "host": "nas.example.test", "port": 443, "extra": 1],
      ["protocolVersion": 2, "operationId": id, "host": "nas.example.test", "port": 443],
      ["protocolVersion": "1", "operationId": id, "host": "nas.example.test", "port": 443],
      ["protocolVersion": 1, "operationId": "BAD", "host": "nas.example.test", "port": 443],
      ["protocolVersion": 1, "operationId": id, "host": "NAS.example.test", "port": 443],
      ["protocolVersion": 1, "operationId": id, "host": "127.000.000.001", "port": 443],
      ["protocolVersion": 1, "operationId": id, "host": "2001:0db8::1", "port": 443],
      ["protocolVersion": 1, "operationId": id, "host": "nas.example.test", "port": 0],
      ["protocolVersion": 1, "operationId": id, "host": "nas.example.test", "port": 65536],
      ["protocolVersion": 1, "operationId": id, "host": "nas.example.test", "port": "443"],
    ]
    for (index, value) in cases.enumerated() {
      let done = expectation(description: "rejected \(index)")
      core.capture(value, completion: { response in XCTAssertEqual(response["failureCode"] as? String, "captureFailed"); done.fulfill() })
      wait(for: [done], timeout: 1)
    }
    XCTAssertEqual(factoryCalls, 0)
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

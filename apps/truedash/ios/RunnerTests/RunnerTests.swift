import Foundation
import Network
import XCTest

final class RunnerTests: XCTestCase {
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

import CryptoKit
import Foundation
import Network
import Security

#if DEBUG
struct ApplePinnedRpcDebugStateSnapshot: Equatable {
  let operationCount: Int
  let taskCount: Int
  let sessionCount: Int
}

struct ApplePinnedRpcDebugFixture {
  let session: URLSession
  let task: URLSessionWebSocketTask
}
#endif

/// Per-process bridge core for exact leaf-pin WebSocket sessions.  This is
/// deliberately independent of PresentedLeafProbeCore: a probe is never a
/// transport and a transport is created fresh for each connect request.
final class ApplePinnedRpcCore: NSObject, URLSessionWebSocketDelegate, URLSessionTaskDelegate {
  static let protocolVersion = 1
  // A real TrueNAS `core.get_methods` reply is several megabytes. This stays a
  // hard bound; an oversized frame closes the session rather than buffering.
  static let maximumFrameBytes = 16 * 1024 * 1024
  private let queue = DispatchQueue(label: "com.truenavo.pinned-rpc")
  private let now: () -> Date
  private var operations: [String: Operation] = [:]
  // URLSession task identifiers are only unique within a URLSession.  Object
  // identity is scoped to the live operation and avoids scans/collisions.
  private var operationByTask: [ObjectIdentifier: String] = [:]
  private var sessions: [String: Session] = [:]

  #if DEBUG
  /// Test-only seam for holding a WebSocket send completion deterministically.
  var debugSend: ((URLSessionWebSocketTask, String, @escaping (Error?) -> Void) -> Void)?
  #endif

  init(now: @escaping () -> Date = Date.init) { self.now = now; super.init() }

  #if DEBUG
  /// Installs an already trust-accepted operation without resuming its task so
  /// native tests can drive the actual URLSession delegate lifecycle.
  func debugInstallAcceptedOperation(operationId: String, completion: @escaping ([String: Any]) -> Void) -> ApplePinnedRpcDebugFixture? {
    guard let request = PinnedRpcRequest([
      "protocolVersion": Self.protocolVersion,
      "operationId": operationId,
      "host": "nas.example.test",
      "port": 443,
      "rpcPath": "/rpc",
      "leafDerSha256": String(repeating: "A", count: 64),
    ]) else { return nil }
    return queue.sync {
      guard operations[operationId] == nil else { return nil }
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.urlCredentialStorage = nil
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.httpAdditionalHeaders = nil
      let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      let task = session.webSocketTask(with: request.url)
      let operation = Operation(request, Self.main(completion), task: task, urlSession: session)
      operation.state.acceptTrust()
      operations[operationId] = operation
      operationByTask[ObjectIdentifier(task)] = operationId
      return ApplePinnedRpcDebugFixture(session: session, task: task)
    }
  }

  var debugStateSnapshot: ApplePinnedRpcDebugStateSnapshot {
    queue.sync { ApplePinnedRpcDebugStateSnapshot(operationCount: operations.count, taskCount: operationByTask.count, sessionCount: sessions.count) }
  }

  func debugSessionId(for operationId: String) -> String? {
    queue.sync { operations[operationId]?.sessionId }
  }
  #endif

  func connect(_ raw: Any?, completion: @escaping ([String: Any]) -> Void) {
    let completion = Self.main(completion)
    guard let request = PinnedRpcRequest(raw) else { completion(Self.failure("malformedCertificate", id: nil)); return }
    queue.async {
      guard self.operations[request.operationId] == nil else { completion(Self.failure("pinnedReconnectFailed", id: request.operationId)); return }
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpCookieStorage = nil
      configuration.httpShouldSetCookies = false
      configuration.urlCredentialStorage = nil
      configuration.urlCache = nil
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.httpAdditionalHeaders = nil
      let urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
      let task = urlSession.webSocketTask(with: request.url)
      let operation = Operation(request, completion, task: task, urlSession: urlSession)
      self.operations[request.operationId] = operation
      self.operationByTask[ObjectIdentifier(task)] = request.operationId
      task.resume()
    }
  }

  func cancel(_ raw: Any?, completion: @escaping ([String: Any]) -> Void) {
    let completion = Self.main(completion)
    guard let id = Self.operationId(raw) else { completion(Self.failure("cancelled", id: nil)); return }
    queue.async {
      guard let operation = self.operations.removeValue(forKey: id) else { completion(Self.failure("cancelled", id: id)); return }
      self.operationByTask.removeValue(forKey: ObjectIdentifier(operation.task))
      if let sessionId = operation.sessionId {
        self.closeSession(sessionId, removeOperation: false)
      } else {
        operation.task.cancel(with: .goingAway, reason: nil)
        operation.urlSession.invalidateAndCancel()
        operation.finish(Self.failure("cancelled", id: id))
      }
      completion(Self.failure("cancelled", id: id))
    }
  }

  func send(_ raw: Any?, completion: @escaping ([String: Any]) -> Void) {
    let completion = Self.main(completion)
    guard let request = FrameRequest(raw), request.frame.utf8.count <= Self.maximumFrameBytes else { completion(Self.sessionFailure(nil)); return }
    queue.async {
      guard let session = self.sessions[request.sessionId] else { completion(Self.sessionFailure(request.sessionId)); return }
      self.send(session, frame: request.frame) { error in
        self.queue.async {
          // URLSession can acknowledge an already-issued send after this
          // session has been removed by close/cleanup. An acknowledgement is
          // valid only while it still refers to this live session object.
          guard error == nil, self.sessions[request.sessionId] === session else {
            completion(Self.sessionFailure(request.sessionId))
            return
          }
          completion(Self.ack(request.sessionId))
        }
      }
    }
  }

  func receive(_ raw: Any?, completion: @escaping ([String: Any]) -> Void) {
    let completion = Self.main(completion)
    guard let id = Self.sessionId(raw) else { completion(Self.sessionFailure(nil)); return }
    queue.async {
      guard let session = self.sessions[id], !session.receivePending else { completion(Self.sessionFailure(id)); return }
      session.receivePending = true
      session.receiveCompletion = completion
      session.task.receive { result in
        self.queue.async {
          guard self.sessions[id] === session else { return }
          session.receivePending = false
          guard let receiveCompletion = session.receiveCompletion else { return }
          session.receiveCompletion = nil
          switch result {
          case .success(.string(let frame)) where frame.utf8.count <= Self.maximumFrameBytes:
            receiveCompletion(["protocolVersion": Self.protocolVersion, "sessionId": id, "frame": frame])
          default:
            self.closeSession(id)
            receiveCompletion(["protocolVersion": Self.protocolVersion, "sessionId": id, "closed": true])
          }
        }
      }
    }
  }

  func close(_ raw: Any?, completion: @escaping ([String: Any]) -> Void) {
    let completion = Self.main(completion)
    guard let id = Self.sessionId(raw) else { completion(Self.sessionFailure(nil)); return }
    queue.async { self.closeSession(id); completion(Self.ack(id)) }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  completionHandler: @escaping (URLRequest?) -> Void) {
    completionHandler(nil)
    queue.async { self.fail(task, "pinnedReconnectFailed") }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
          let trust = challenge.protectionSpace.serverTrust else { completionHandler(.cancelAuthenticationChallenge, nil); return }
    queue.async {
      guard let operation = self.operation(for: task) else { completionHandler(.cancelAuthenticationChallenge, nil); return }
      guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first else { self.fail(operation, "malformedCertificate"); completionHandler(.cancelAuthenticationChallenge, nil); return }
      let leafData = SecCertificateCopyData(leaf) as Data
      let verifyDate = self.now()
      let failure = PinnedLeafTrustPolicy.evaluate(
        request: operation.request,
        presentedHost: challenge.protectionSpace.host,
        leafDER: leafData,
        verifyDate: verifyDate
      ) {
        // A pinned connection's identity is the exact leaf the user approved
        // for this authority, the way an SSH known-hosts entry works, so a
        // certificate that does not name the address is not by itself a reason
        // to refuse; the approval screen says so before any pin is written.
        // Chain, protocol, and validity policy still apply.
        let policy = SecPolicyCreateSSL(true, nil)
        SecTrustSetPolicies(trust, policy)
        SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        SecTrustSetVerifyDate(trust, verifyDate as CFDate)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error) ? nil : Self.trustCode(error)
      }
      if let failure {
        self.fail(operation, failure)
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      operation.state.acceptTrust()
      completionHandler(.useCredential, URLCredential(trust: trust))
    }
  }

  func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
    queue.async {
      guard let operation = self.operation(for: webSocketTask), operation.state.canOpen else { webSocketTask.cancel(with: .policyViolation, reason: nil); return }
      var id: String
      repeat { id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() } while self.sessions[id] != nil
      operation.sessionId = id
      self.sessions[id] = Session(webSocketTask, operation.urlSession, operationId: operation.request.operationId)
      operation.finishOpen(["protocolVersion": Self.protocolVersion, "operationId": operation.request.operationId, "sessionId": id])
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    queue.async {
      guard let operation = self.operation(for: task) else { return }
      if let sessionId = operation.sessionId {
        self.closeSession(sessionId)
      } else {
        self.fail(operation, "pinnedReconnectFailed")
      }
    }
  }

  private func operation(for task: URLSessionTask) -> Operation? { operationByTask[ObjectIdentifier(task)].flatMap { operations[$0] } }
  private func send(_ session: Session, frame: String, completion: @escaping (Error?) -> Void) {
    #if DEBUG
    if let debugSend { debugSend(session.task, frame, completion); return }
    #endif
    session.task.send(.string(frame), completionHandler: completion)
  }
  private func fail(_ task: URLSessionTask, _ code: String) { if let operation = operation(for: task) { fail(operation, code) } }
  private func fail(_ operation: Operation, _ code: String) {
    guard operations.removeValue(forKey: operation.request.operationId) != nil else { return }
    operationByTask.removeValue(forKey: ObjectIdentifier(operation.task))
    if let sessionId = operation.sessionId {
      closeSession(sessionId, removeOperation: false)
    } else {
      operation.task.cancel(with: .goingAway, reason: nil)
      operation.urlSession.invalidateAndCancel()
      operation.finish(Self.failure(code, id: operation.request.operationId))
    }
  }
  private func closeSession(_ id: String, removeOperation: Bool = true) {
    guard let session = sessions.removeValue(forKey: id) else { return }
    if removeOperation, let operation = operations.removeValue(forKey: session.operationId) {
      operationByTask.removeValue(forKey: ObjectIdentifier(operation.task))
      operation.sessionId = nil
    }
    let pending = session.receiveCompletion
    session.receiveCompletion = nil; session.receivePending = false
    session.task.cancel(with: .normalClosure, reason: nil)
    session.urlSession.invalidateAndCancel()
    pending?(Self.sessionFailure(id))
  }
  private static func ack(_ id: String) -> [String: Any] { ["protocolVersion": protocolVersion, "sessionId": id] }
  private static func main(_ completion: @escaping ([String: Any]) -> Void) -> ([String: Any]) -> Void { { value in DispatchQueue.main.async { completion(value) } } }
  private static func sessionFailure(_ id: String?) -> [String: Any] { ["protocolVersion": protocolVersion, "sessionId": id ?? "00000000000000000000000000000000", "closed": true] }
  private static func failure(_ code: String, id: String?) -> [String: Any] { ["protocolVersion": protocolVersion, "operationId": id ?? "00000000000000000000000000000000", "failureCode": code] }
  private static func operationId(_ raw: Any?) -> String? { guard let values = raw as? [String: Any], values.count == 2, values["protocolVersion"] as? Int == protocolVersion, let id = values["operationId"] as? String, validId(id) else { return nil }; return id }
  private static func sessionId(_ raw: Any?) -> String? { guard let values = raw as? [String: Any], values.count == 2, values["protocolVersion"] as? Int == protocolVersion, let id = values["sessionId"] as? String, validId(id) else { return nil }; return id }
  fileprivate static func validId(_ id: String) -> Bool { id.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil }
  fileprivate static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool { guard left.count == right.count else { return false }; return zip(left, right).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0 }
  private static func trustCode(_ error: CFError?) -> String {
    let status = error.map { CFErrorGetCode($0) } ?? 0
    if status == OSStatus(errSecHostNameMismatch) { return "hostnameMismatch" }
    if status == OSStatus(errSecCertificateExpired) { return "expiredCertificate" }
    if status == OSStatus(errSecCertificateNotValidYet) { return "notYetValidCertificate" }
    return "malformedCertificate"
  }
}

/// Minimal, bounded DER reader used solely to classify the exact leaf's
/// validity interval before SecTrust.  It accepts only DER definite lengths
/// and UTC/GeneralizedTime values; trust evaluation remains authoritative for
/// SSL hostname and chain policy.
struct DERValidity {
  let notBefore: Date
  let notAfter: Date
  init?(_ der: Data) {
    guard der.count > 0 && der.count <= 1024 * 1024 else { return nil }
    var cursor = DERCursor(der)
    guard let certificate = cursor.element(), certificate.tag == 0x30,
          certificate.end == der.count else { return nil }
    var outer = DERCursor(der, certificate.contentStart, certificate.end)
    guard let tbs = outer.element(), tbs.tag == 0x30 else { return nil }
    // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm,
    // signatureValue }; require all three boundaries exactly.
    guard outer.element()?.tag == 0x30, outer.element()?.tag == 0x03,
          outer.atEnd else { return nil }
    var fields = DERCursor(der, tbs.contentStart, tbs.end)
    if fields.peekTag == 0xa0 { guard fields.element()?.tag == 0xa0 else { return nil } }
    // serialNumber, signature, issuer
    guard fields.element()?.tag == 0x02, fields.element()?.tag == 0x30,
          fields.element()?.tag == 0x30,
          let validity = fields.element(), validity.tag == 0x30 else { return nil }
    var dates = DERCursor(der, validity.contentStart, validity.end)
    guard let before = dates.element(), let after = dates.element(), dates.atEnd,
          (before.tag == 0x17 || before.tag == 0x18),
          (after.tag == 0x17 || after.tag == 0x18),
          let first = Self.date(Data(der[before.contentStart..<before.end]), generalized: before.tag == 0x18),
          let second = Self.date(Data(der[after.contentStart..<after.end]), generalized: after.tag == 0x18),
          first < second else { return nil }
    notBefore = first; notAfter = second
  }
  func contains(_ date: Date) -> Bool { date >= notBefore && date <= notAfter }
  func isNotYetValid(at date: Date) -> Bool { date < notBefore }
  private static func date(_ bytes: Data, generalized: Bool) -> Date? {
    let digits = generalized ? 14 : 12
    guard bytes.count == digits + 1, bytes.last == 0x5a,
          bytes.dropLast().allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
    let v = bytes.dropLast().map { Int($0 - 48) }
    func number(_ start: Int, _ count: Int) -> Int { v[start..<(start + count)].reduce(0) { $0 * 10 + $1 } }
    let year = generalized ? number(0, 4) : (number(0, 2) <= 49 ? 2000 + number(0, 2) : 1900 + number(0, 2))
    let shift = generalized ? 4 : 2
    let month = number(shift, 2), day = number(shift + 2, 2), hour = number(shift + 4, 2), minute = number(shift + 6, 2), second = number(shift + 8, 2)
    guard (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: day, hour: hour, minute: minute, second: second)
    let expected = DateComponents(
      year: year,
      month: month,
      day: day,
      hour: hour,
      minute: minute,
      second: second)
    guard let result = calendar.date(from: components),
          calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: result) == expected else { return nil }
    return result
  }
}

private struct DERElement { let tag: UInt8; let contentStart: Int; let end: Int }
private struct DERCursor {
  let data: Data; var index: Int; let limit: Int
  init(_ data: Data, _ index: Int = 0, _ limit: Int? = nil) { self.data = data; self.index = index; self.limit = limit ?? data.count }
  var atEnd: Bool { index == limit }; var peekTag: UInt8? { index < limit ? data[index] : nil }
  mutating func element() -> DERElement? {
    guard index + 2 <= limit else { return nil }; let tag = data[index]; index += 1; let first = Int(data[index]); index += 1
    let length: Int
    if first < 128 { length = first } else { let count = first & 0x7f; guard count > 0 && count <= 4 && index + count <= limit, data[index] != 0 else { return nil }; var parsed = 0; for _ in 0..<count { parsed = (parsed << 8) | Int(data[index]); index += 1 }; guard parsed >= 128 else { return nil }; length = parsed }
    guard length <= limit - index else { return nil }; let start = index; index += length; return DERElement(tag: tag, contentStart: start, end: index)
  }
}

final class PinnedOperationState {
  private var completed = false
  private var trustAccepted = false
  var canOpen: Bool { trustAccepted && !completed }
  func acceptTrust() { guard !completed else { return }; trustAccepted = true }
  func finishFailure() -> Bool { guard !completed else { return false }; completed = true; return true }
  func finishOpen() -> Bool { guard canOpen else { return false }; completed = true; return true }
}
private final class Operation { let request: PinnedRpcRequest; let completion: ([String: Any]) -> Void; let task: URLSessionWebSocketTask; let urlSession: URLSession; let state = PinnedOperationState(); var sessionId: String?; init(_ request: PinnedRpcRequest, _ completion: @escaping ([String: Any]) -> Void, task: URLSessionWebSocketTask, urlSession: URLSession) { self.request = request; self.completion = completion; self.task = task; self.urlSession = urlSession }; func finish(_ value: [String: Any]) { guard state.finishFailure() else { return }; completion(value) }; func finishOpen(_ value: [String: Any]) { guard state.finishOpen() else { return }; completion(value) } }
private final class Session { let task: URLSessionWebSocketTask; let urlSession: URLSession; let operationId: String; var receivePending = false; var receiveCompletion: (([String: Any]) -> Void)?; init(_ task: URLSessionWebSocketTask, _ urlSession: URLSession, operationId: String) { self.task = task; self.urlSession = urlSession; self.operationId = operationId } }
private struct FrameRequest { let sessionId: String; let frame: String; init?(_ raw: Any?) { guard let values = raw as? [String: Any], values.count == 3, values["protocolVersion"] as? Int == ApplePinnedRpcCore.protocolVersion, let id = values["sessionId"] as? String, ApplePinnedRpcCore.validId(id), let frame = values["frame"] as? String else { return nil }; sessionId = id; self.frame = frame } }
struct PinnedRpcRequest {
  let operationId: String; let host: String; let port: Int; let rpcPath: String; let digest: Data; let url: URL
  init?(_ raw: Any?) {
    guard let v = raw as? [String: Any], v.count == 6,
          v["protocolVersion"] as? Int == ApplePinnedRpcCore.protocolVersion,
          let id = v["operationId"] as? String, ApplePinnedRpcCore.validId(id),
          let host = v["host"] as? String, Self.host(host),
          let port = v["port"] as? Int, (1...65535).contains(port),
          let path = v["rpcPath"] as? String, Self.path(path),
          let hex = v["leafDerSha256"] as? String,
          hex.range(of: "^[0-9A-F]{64}$", options: .regularExpression) != nil else { return nil }
    // URLComponents requires brackets in its host input for an IPv6 literal,
    // while the bridge/pin identity deliberately remains bracketless.
    let urlHost = host.contains(":") ? "[\(host)]" : host
    var components = URLComponents(); components.scheme = "wss"; components.host = urlHost; components.port = port; components.path = path
    guard let url = components.url, url.scheme == "wss", url.host == host, url.port == port, url.path == path, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
    operationId = id; self.host = host; self.port = port; rpcPath = path
    let bytes = stride(from: 0, to: 64, by: 2).compactMap { UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16) }
    guard bytes.count == 32 else { return nil }
    digest = Data(bytes); self.url = url
  }
  static func path(_ value: String) -> Bool {
    guard value.first == "/", !value.contains("?"), !value.contains("#"), !value.contains("@"), !value.contains("\\"), !value.contains("%") else { return false }
    return !value.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) && value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e }
  }
  static func host(_ value: String) -> Bool {
    guard !value.isEmpty, value == value.lowercased(), value.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7f }), !value.contains("/") && !value.contains("@") && !value.contains("%") && !value.contains("[") && !value.contains("]") else { return false }
    if value.contains(":") {
      // Dart passes the internal, bracketless canonical form.  Network's
      // description is RFC 5952-normalized, so expanded/noncanonical input
      // cannot become a different authority during URL construction.
      return IPv6Address(value).map { String(describing: $0) == value } ?? false
    }
    if value.allSatisfy({ $0.isNumber || $0 == "." }) {
      let parts = value.split(separator: ".", omittingEmptySubsequences: false)
      return parts.count == 4 && parts.allSatisfy { part in guard let n = Int(part), String(n) == part else { return false }; return n <= 255 }
    }
    guard value.count <= 253 else { return false }
    let labels = value.split(separator: ".", omittingEmptySubsequences: false)
    return labels.allSatisfy { label in !label.isEmpty && label.count <= 63 && label.first != "-" && label.last != "-" && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
  }
}

/// The deterministic policy boundary used by the URLSession challenge.  It
/// checks the exact DER leaf before asking Security.framework to apply SSL
/// hostname/chain policy, making the security-sensitive ordering testable.
struct PinnedLeafTrustPolicy {
  static func evaluate(request: PinnedRpcRequest, presentedHost: String, leafDER: Data,
                       verifyDate: Date, evaluateSSLTrust: () -> String?) -> String? {
    let challengeHost = presentedHost.hasPrefix("[") && presentedHost.hasSuffix("]")
      ? String(presentedHost.dropFirst().dropLast()) : presentedHost
    guard request.host == challengeHost.lowercased() else { return "hostnameMismatch" }
    guard ApplePinnedRpcCore.constantTimeEqual(Data(SHA256.hash(data: leafDER)), request.digest) else { return "pinMismatch" }
    guard let validity = DERValidity(leafDER) else { return "malformedCertificate" }
    guard validity.contains(verifyDate) else {
      return validity.isNotYetValid(at: verifyDate) ? "notYetValidCertificate" : "expiredCertificate"
    }
    return evaluateSSLTrust()
  }
}

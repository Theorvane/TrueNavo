import Darwin
import Foundation
import Network
import Security

/// Capture-only transport abstraction: deliberately no send/receive capability.
protocol PresentedLeafConnection: AnyObject {
  func start()
  func cancel()
}

typealias VerifyDecision = (Bool) -> Void
typealias PresentedLeafConnectionFactory = (
  _ host: String,
  _ port: UInt16,
  _ verify: @escaping (SecTrust?, @escaping VerifyDecision) -> Void,
  _ state: @escaping (NWConnection.State) -> Void
) -> PresentedLeafConnection
typealias PresentedLeafCopier = (SecTrust?) -> Data?

final class PresentedLeafProbeCore {
  static let protocolVersion = 1
  static let maximumDerBytes = 64 * 1024

  private let queue = DispatchQueue(label: "com.truedash.presented-leaf-probe")
  private let makeConnection: PresentedLeafConnectionFactory
  private let copyLeaf: PresentedLeafCopier
  private var operations: [String: Operation] = [:]

  init(
    factory: @escaping PresentedLeafConnectionFactory = PresentedLeafProbeCore.networkConnection,
    leafCopier: @escaping PresentedLeafCopier = PresentedLeafProbeCore.copyPresentedLeaf
  ) {
    makeConnection = factory
    copyLeaf = leafCopier
  }

  func capture(_ arguments: Any?, completion: @escaping ([String: Any]) -> Void) {
    guard let request = Request(arguments) else {
      completion(Self.failure("captureFailed", operationId: nil))
      return
    }
    queue.async { [weak self] in
      guard let self else { return }
      guard self.operations[request.operationId] == nil else {
        completion(Self.failure("captureFailed", operationId: request.operationId))
        return
      }
      let operation = Operation(request: request, completion: completion)
      self.operations[request.operationId] = operation
      operation.connection = self.makeConnection(
        request.host,
        request.port,
        { [weak self, weak operation] trust, decision in
          // Network.framework must never be allowed to authenticate this
          // capture-only connection. Copy and queue the leaf before rejecting:
          // rejection may synchronously emit a terminal connection state.
          let leaf = self?.copyLeaf(trust)
          self?.queue.async { self?.verified(operation, leaf: leaf) }
          // Every callback gets exactly one reject.
          decision(false)
        },
        { [weak self, weak operation] state in
          self?.queue.async { self?.stateChanged(operation, state: state) }
        }
      )
      operation.connection?.start()
    }
  }

  func cancel(_ arguments: Any?, completion: @escaping ([String: Any]) -> Void) {
    guard let values = arguments as? [String: Any], values.count == 2,
          values["protocolVersion"] as? Int == Self.protocolVersion,
          let id = values["operationId"] as? String, Request.validOperationId(id) else {
      completion(Self.failure("captureFailed", operationId: nil))
      return
    }
    queue.async { [weak self] in
      guard let operation = self?.operations.removeValue(forKey: id) else {
        completion(Self.failure("cancelled", operationId: id))
        return
      }
      operation.connection?.cancel()
      operation.finish(Self.failure("cancelled", operationId: id))
      completion(Self.failure("cancelled", operationId: id))
    }
  }

  private func verified(_ operation: Operation?, leaf: Data?) {
    guard let operation, operations[operation.request.operationId] === operation else { return }
    guard let leaf, !leaf.isEmpty, leaf.count <= Self.maximumDerBytes else {
      finish(operation, Self.failure("captureFailed", operationId: operation.request.operationId))
      return
    }
    operation.connection?.cancel()
    finish(operation, [
      "protocolVersion": Self.protocolVersion,
      "operationId": operation.request.operationId,
      "leafDerBase64": leaf.base64EncodedString(),
    ])
  }

  private func stateChanged(_ operation: Operation?, state: NWConnection.State) {
    guard let operation, operations[operation.request.operationId] === operation else { return }
    switch state {
    case .failed, .cancelled:
      finish(operation, Self.failure("captureFailed", operationId: operation.request.operationId))
    default:
      break
    }
  }

  private func finish(_ operation: Operation, _ response: [String: Any]) {
    guard operations.removeValue(forKey: operation.request.operationId) != nil else { return }
    operation.finish(response)
  }

  private static func failure(_ code: String, operationId: String?) -> [String: Any] {
    [
      "protocolVersion": protocolVersion,
      "operationId": operationId ?? "00000000000000000000000000000000",
      "failureCode": code,
    ]
  }

  private static func copyPresentedLeaf(_ trust: SecTrust?) -> Data? {
    guard let trust,
          let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
          let certificate = chain.first else { return nil }
    return SecCertificateCopyData(certificate) as Data
  }

  private static func networkConnection(
    _ host: String,
    _ port: UInt16,
    _ verify: @escaping (SecTrust?, @escaping VerifyDecision) -> Void,
    _ state: @escaping (NWConnection.State) -> Void
  ) -> PresentedLeafConnection {
    let options = NWProtocolTLS.Options()
    sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
      // `sec_trust_t` is Network.framework's borrowed trust representation.
      // Convert it through its public ownership API before leaving this block.
      verify(sec_trust_copy_ref(trust).takeRetainedValue(), complete)
    }, DispatchQueue(label: "com.truedash.presented-leaf-verify"))
    let endpointPort = NWEndpoint.Port(rawValue: port)!
    let connection = NWConnection(
      host: NWEndpoint.Host(host), port: endpointPort, using: NWParameters(tls: options))
    connection.stateUpdateHandler = state
    return NetworkConnection(connection)
  }
}

private final class NetworkConnection: PresentedLeafConnection {
  private let connection: NWConnection
  init(_ connection: NWConnection) { self.connection = connection }
  func start() { connection.start(queue: DispatchQueue(label: "com.truedash.presented-leaf-network")) }
  func cancel() { connection.cancel() }
}

private final class Operation {
  let request: Request
  var connection: PresentedLeafConnection?
  private var completed = false
  private let completion: ([String: Any]) -> Void
  init(request: Request, completion: @escaping ([String: Any]) -> Void) {
    self.request = request
    self.completion = completion
  }
  func finish(_ response: [String: Any]) {
    guard !completed else { return }
    completed = true
    completion(response)
  }
}

private struct Request {
  let operationId: String
  let host: String
  let port: UInt16
  init?(_ raw: Any?) {
    guard let values = raw as? [String: Any], values.count == 4,
          values["protocolVersion"] as? Int == PresentedLeafProbeCore.protocolVersion,
          let operationId = values["operationId"] as? String, Self.validOperationId(operationId),
          let host = values["host"] as? String, Self.validHost(host),
          let intPort = values["port"] as? Int, (1 ... 65535).contains(intPort) else { return nil }
    self.operationId = operationId
    self.host = host
    port = UInt16(intPort)
  }
  static func validOperationId(_ value: String) -> Bool {
    value.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
  }
  static func validHost(_ host: String) -> Bool {
    guard !host.isEmpty, host.utf8.allSatisfy({ $0 < 128 }), !host.contains("@"),
          !host.contains("/"), !host.contains("%") else { return false }
    if host.contains(":") {
      var address = in6_addr()
      guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
      var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      return inet_ntop(AF_INET6, &address, &text, socklen_t(text.count)).map {
        String(cString: $0) == host
      } ?? false
    }
    if host.range(of: "^[0-9.]+$", options: .regularExpression) != nil {
      var address = in_addr()
      guard inet_pton(AF_INET, host, &address) == 1 else { return false }
      var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      return inet_ntop(AF_INET, &address, &text, socklen_t(text.count)).map {
        String(cString: $0) == host
      } ?? false
    }
    guard host == host.lowercased(), !host.contains("xn--") else { return false }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    return !labels.isEmpty && labels.allSatisfy {
      $0.count <= 63 && $0.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$", options: .regularExpression) != nil
    }
  }
}

import FlutterMacOS

final class ApplePinnedRpcPlugin: NSObject, FlutterPlugin {
  private let core = ApplePinnedRpcCore()
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "truedash.pinned_rpc.v1", binaryMessenger: registrar.messenger)
    registrar.addMethodCallDelegate(ApplePinnedRpcPlugin(), channel: channel)
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let respond: ([String: Any]) -> Void = { value in DispatchQueue.main.async { result(value) } }
    switch call.method {
    case "truedash.connectPinnedRpc": core.connect(call.arguments, completion: respond)
    case "truedash.cancelPinnedRpc": core.cancel(call.arguments, completion: respond)
    case "truedash.sendPinnedRpc": core.send(call.arguments, completion: respond)
    case "truedash.receivePinnedRpc": core.receive(call.arguments, completion: respond)
    case "truedash.closePinnedRpc": core.close(call.arguments, completion: respond)
    default: result(FlutterMethodNotImplemented)
    }
  }
}

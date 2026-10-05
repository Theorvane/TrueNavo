import Flutter

final class PresentedLeafProbePlugin: NSObject, FlutterPlugin {
  private let core = PresentedLeafProbeCore()
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "truenavo.presented_leaf_probe.v1", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(PresentedLeafProbePlugin(), channel: channel)
  }
  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let respond: ([String: Any]) -> Void = { response in
      DispatchQueue.main.async { result(response) }
    }
    switch call.method {
    case "truenavo.capturePresentedLeaf": core.capture(call.arguments, completion: respond)
    case "truenavo.cancelPresentedLeaf": core.cancel(call.arguments, completion: respond)
    default: result(FlutterMethodNotImplemented)
    }
  }
}

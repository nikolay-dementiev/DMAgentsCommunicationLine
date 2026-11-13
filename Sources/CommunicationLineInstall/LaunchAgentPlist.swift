import Foundation

enum LaunchAgentPlist {
  /// The LaunchAgent that runs the installed service on the store. It starts at load and is
  /// restarted after a crash but not after a clean stop. It holds no token and no environment.
  static func data(layout: HostLayout) throws -> Data {
    let contents: [String: Any] = [
      "Label": HostLayout.launchAgentLabel,
      "ProgramArguments": [layout.serviceBinary.path, layout.storeFolder.path],
      "RunAtLoad": true,
      "KeepAlive": ["SuccessfulExit": false],
      "StandardOutPath": layout.logURL.path,
      "StandardErrorPath": layout.logURL.path,
    ]
    return try PropertyListSerialization.data(
      fromPropertyList: contents, format: .xml, options: 0)
  }
}

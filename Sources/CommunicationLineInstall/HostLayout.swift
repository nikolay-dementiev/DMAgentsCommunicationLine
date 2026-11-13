import Foundation

/// Every path the install writes, derived from one home folder. Nothing outside it is touched, so a
/// test can point the whole install at a throwaway folder.
public struct HostLayout: Sendable, Equatable {
  /// The LaunchAgent label. A working name until the first release.
  public static let launchAgentLabel = "com.commline.service"
  public static let clientName = "commline"
  public static let serviceName = "commline-service"

  public let home: URL

  public init(home: URL) {
    self.home = home
  }

  public var supportFolder: URL {
    home.appendingPathComponent("Library/Application Support/commline", isDirectory: true)
  }
  public var binFolder: URL { supportFolder.appendingPathComponent("bin", isDirectory: true) }
  public var storeFolder: URL { supportFolder.appendingPathComponent("store", isDirectory: true) }
  public var manifestURL: URL { supportFolder.appendingPathComponent("manifest.json") }

  public var clientBinary: URL { binFolder.appendingPathComponent(Self.clientName) }
  public var serviceBinary: URL { binFolder.appendingPathComponent(Self.serviceName) }

  public var launchAgentsFolder: URL {
    home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
  }
  public var plistURL: URL {
    launchAgentsFolder.appendingPathComponent(Self.launchAgentLabel + ".plist")
  }

  public var ownerTokenURL: URL { storeFolder.appendingPathComponent("owner.token") }
  public var logURL: URL { storeFolder.appendingPathComponent("service.log") }
  public var databaseURL: URL { storeFolder.appendingPathComponent("commline.sqlite") }
  public var socketURL: URL { storeFolder.appendingPathComponent("commline.sock") }
}

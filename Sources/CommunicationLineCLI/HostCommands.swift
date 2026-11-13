import CommunicationLineInstall
import CommunicationLineWire
import Foundation

/// The commands that act on the host instead of asking the service: install and, later, uninstall.
/// Each returns the lines to print.
public protocol HostCommands {
  /// Installs under `home`, or under the home folder of the caller when nil.
  func install(home: String?) throws -> [String]
}

/// The real host: the account that runs `commline`, its launchd, and the programs next to the
/// running `commline`.
public struct SystemHostCommands: HostCommands {
  private let executableFolder: URL
  private let userID: UInt32
  private let defaultHome: URL
  private let launchd: any LaunchdControl
  private let readiness: any ServiceReadiness
  private let connect: (String) -> any ServiceConnection

  public init(
    executableFolder: URL, userID: UInt32 = UInt32(geteuid()),
    defaultHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    launchd: any LaunchdControl = SystemLaunchd(),
    readiness: any ServiceReadiness = SocketReadiness(),
    connect: @escaping (String) -> any ServiceConnection = {
      SocketServiceConnection(socketPath: $0)
    }
  ) {
    self.executableFolder = executableFolder
    self.userID = userID
    self.defaultHome = defaultHome
    self.launchd = launchd
    self.readiness = readiness
    self.connect = connect
  }

  public func install(home: String?) throws -> [String] {
    let layout = HostLayout(
      home: home.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultHome)
    let report = try Installer(
      layout: layout, executableFolder: executableFolder, userID: userID, launchd: launchd,
      readiness: readiness, connect: connect
    ).install()
    return [
      report.upgraded ? "upgraded" : "installed",
      "programs: \(report.binFolder)",
      "store: \(report.storeFolder)",
      report.ownerTokenIssued
        ? "owner token file: \(report.ownerTokenPath)"
        : "owner token file kept: \(report.ownerTokenPath)",
    ]
  }
}

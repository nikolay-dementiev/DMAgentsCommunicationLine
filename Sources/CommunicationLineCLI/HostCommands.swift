import CommunicationLineInstall
import CommunicationLineWire
import Foundation

/// The commands that act on the host instead of asking the service: install, uninstall and the
/// setup of an agent.
/// Each returns the lines to print.
public protocol HostCommands {
  /// Installs under `home`, or under the home folder of the caller when nil.
  func install(home: String?) throws -> [String]
  /// Removes what the install wrote under `home`, or under the home folder of the caller when nil.
  /// The store stays unless `deleteData` is set and no mail is pending.
  func uninstall(home: String?, deleteData: Bool) throws -> [String]
  /// Gives the owner a new token without the old one, for a lost or never written token file. It
  /// stops the service while the database changes and starts it again.
  func recoverOwner(home: String?) throws -> [String]
  /// Creates an agent with the owner's token. Its files go inside `storeFolder`; a mail command for
  /// a client goes under `home`, or under the home folder of the caller when nil.
  func addAgent(storeFolder: String, home: String?, ownerToken: String, request: AgentRequest)
    throws -> [String]
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
  private let pendingMail: any PendingMailCounter

  public init(
    executableFolder: URL, userID: UInt32 = UInt32(geteuid()),
    defaultHome: URL = FileManager.default.homeDirectoryForCurrentUser,
    launchd: any LaunchdControl = SystemLaunchd(),
    readiness: any ServiceReadiness = SocketReadiness(),
    connect: @escaping (String) -> any ServiceConnection = {
      SocketServiceConnection(socketPath: $0)
    },
    pendingMail: any PendingMailCounter = StorePendingMailCounter()
  ) {
    self.executableFolder = executableFolder
    self.userID = userID
    self.defaultHome = defaultHome
    self.launchd = launchd
    self.readiness = readiness
    self.connect = connect
    self.pendingMail = pendingMail
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

  public func uninstall(home: String?, deleteData: Bool) throws -> [String] {
    let layout = HostLayout(
      home: home.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultHome)
    let report = try Uninstaller(
      layout: layout, userID: userID, launchd: launchd, pendingMail: pendingMail
    ).uninstall(deleteData: deleteData)
    return [
      "uninstalled",
      report.storeDeleted
        ? "store deleted: \(report.storeFolder)" : "store kept: \(report.storeFolder)",
    ]
  }

  public func recoverOwner(home: String?) throws -> [String] {
    let layout = HostLayout(
      home: home.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultHome)
    let report = try OwnerRecovery(
      layout: layout, userID: userID, launchd: launchd, readiness: readiness
    ).recover()
    return "\(report)".split(separator: "\n").map(String.init)
  }

  public func addAgent(
    storeFolder: String, home: String?, ownerToken: String, request: AgentRequest
  )
    throws -> [String]
  {
    let layout = HostLayout(
      home: home.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultHome)
    let report = try AgentSetup(
      layout: layout, storeFolder: URL(fileURLWithPath: storeFolder, isDirectory: true),
      manifest: FileManifestListing(manifestURL: layout.manifestURL), connect: connect
    ).add(request, ownerToken: ownerToken)
    return [
      "agent: \(report.principalID)", "token file: \(report.tokenFile)",
      "instructions: \(report.instructionFile)",
    ] + (report.commandFile.map { ["command: \($0)"] } ?? [])
  }
}

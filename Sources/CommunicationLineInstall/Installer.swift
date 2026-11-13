import CommunicationLineStore
import CommunicationLineWire
import Foundation

public enum InstallError: Error, Equatable {
  /// Install runs under the owner's account and never as root.
  case refusedAsRoot
  case missingExecutable(String)
  case serviceNotReady(String)
  /// The service already has an owner credential but the token file is gone. It is not replaced.
  case ownerCredentialUnavailable
  case ownerTokenNotWritten(String)
  case launchd(String)
  case filesystem(String)
}

extension InstallError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .refusedAsRoot:
      return "install runs under your own account; it does not run as root"
    case .missingExecutable(let name):
      return "\(name) was not found next to commline"
    case .serviceNotReady(let reason):
      return "the service did not start: \(reason)"
    case .ownerCredentialUnavailable:
      return
        "the service already has an owner credential but the owner token file is missing; "
        + "the credential was not replaced"
    case .ownerTokenNotWritten(let reason):
      return "the owner token could not be written: \(reason)"
    case .launchd(let reason): return "launchd refused the request: \(reason)"
    case .filesystem(let reason): return "a file could not be written: \(reason)"
    }
  }
}

public struct InstallReport: Equatable, Sendable, CustomStringConvertible {
  public let upgraded: Bool
  public let ownerTokenIssued: Bool
  public let ownerTokenPath: String
  public let storeFolder: String
  public let binFolder: String

  public var description: String {
    "installed in \(binFolder); store \(storeFolder); owner token file \(ownerTokenPath)"
  }
}

/// Installs the service for the account that runs it: the programs, the store, the LaunchAgent and
/// the owner credential. Running it again is an upgrade: the programs and the plist are replaced,
/// the database and the owner credential are kept.
public struct Installer {
  /// How long to wait for the service to answer after it was loaded.
  public static let readinessSeconds: TimeInterval = 15
  /// The resource bundles of this package are named after it.
  private static let bundlePrefix = "CommunicationLine_"

  private let layout: HostLayout
  private let executableFolder: URL
  private let userID: UInt32
  private let launchd: any LaunchdControl
  private let readiness: any ServiceReadiness
  private let connect: (String) -> any ServiceConnection

  public init(
    layout: HostLayout, executableFolder: URL, userID: UInt32, launchd: any LaunchdControl,
    readiness: any ServiceReadiness, connect: @escaping (String) -> any ServiceConnection
  ) {
    self.layout = layout
    self.executableFolder = executableFolder
    self.userID = userID
    self.launchd = launchd
    self.readiness = readiness
    self.connect = connect
  }

  public func install() throws -> InstallReport {
    guard userID != 0 else { throw InstallError.refusedAsRoot }
    let programs = try sourcePrograms()
    do {
      let upgraded = FileManager.default.fileExists(atPath: layout.manifestURL.path)
      try unloadIfLoaded()
      try prepareFolders()
      let bundles = try placeResourceBundles()
      try place(programs)
      try writePlist()
      try writeManifest(folders: bundles)
      try launchd.bootstrap(plist: layout.plistURL, userID: userID)
      let issued = try provideOwnerToken()
      return InstallReport(
        upgraded: upgraded, ownerTokenIssued: issued, ownerTokenPath: layout.ownerTokenURL.path,
        storeFolder: layout.storeFolder.path, binFolder: layout.binFolder.path)
    } catch let error as InstallError {
      throw error
    } catch {
      throw InstallError.filesystem("\(error)")
    }
  }

  // MARK: - Steps

  private func sourcePrograms() throws -> [(name: String, source: URL)] {
    try [HostLayout.clientName, HostLayout.serviceName].map { name in
      let source = executableFolder.appendingPathComponent(name)
      guard isFile(source) else {
        throw InstallError.missingExecutable(name)
      }
      return (name, source)
    }
  }

  private func isFile(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && !isDirectory.boolValue
  }

  private func unloadIfLoaded() throws {
    guard try launchd.isLoaded(label: HostLayout.launchAgentLabel, userID: userID) else { return }
    try launchd.bootout(label: HostLayout.launchAgentLabel, userID: userID)
  }

  private func prepareFolders() throws {
    try HostFiles.makeFolder(layout.supportFolder, mode: 0o700)
    try HostFiles.makeFolder(layout.binFolder, mode: 0o755)
    try StoreFolder.prepare(layout.storeFolder, waitingUpTo: 5000)
    let store = try SQLiteStore.open(
      at: layout.databaseURL, busyTimeoutMilliseconds: 5000, migrations: SchemaMigrations.all)
    store.close()
    try HostFiles.ensureFile(at: layout.logURL, mode: 0o600)
    try FileManager.default.createDirectory(
      at: layout.launchAgentsFolder, withIntermediateDirectories: true)
  }

  private func place(_ programs: [(name: String, source: URL)]) throws {
    for program in programs {
      let data = try Data(contentsOf: program.source)
      try HostFiles.replace(
        data, at: layout.binFolder.appendingPathComponent(program.name), mode: 0o755)
    }
  }

  /// The service reads its defaults from a resource bundle that sits next to the program, so the
  /// bundles of this package travel with it. Returns the installed folders.
  private func placeResourceBundles() throws -> [String] {
    let found = try FileManager.default.contentsOfDirectory(
      at: executableFolder, includingPropertiesForKeys: [.isDirectoryKey]
    ).filter {
      $0.lastPathComponent.hasPrefix(Self.bundlePrefix) && $0.pathExtension == "bundle"
        && !isFile($0)
    }
    return try found.map { source in
      let target = layout.binFolder.appendingPathComponent(source.lastPathComponent)
      try HostFiles.copyFolder(from: source, to: target)
      return target.path
    }
  }

  private func writePlist() throws {
    try HostFiles.replace(
      try LaunchAgentPlist.data(layout: layout), at: layout.plistURL, mode: 0o644)
  }

  private func writeManifest(folders: [String]) throws {
    let manifest = Manifest(
      files: [
        layout.clientBinary.path, layout.serviceBinary.path, layout.plistURL.path,
        layout.manifestURL.path,
      ], folders: folders,
      registrations: [.launchAgent(label: HostLayout.launchAgentLabel, userID: userID)],
      storeFolder: layout.storeFolder.path)
    try HostFiles.replace(try manifest.encoded(), at: layout.manifestURL, mode: 0o600)
  }

  /// Returns true when a new owner credential was issued.
  private func provideOwnerToken() throws -> Bool {
    do {
      try readiness.waitUntilAnswering(socket: layout.socketURL, within: Self.readinessSeconds)
    } catch {
      throw InstallError.serviceNotReady("\(error); see \(layout.logURL.path)")
    }
    if FileManager.default.fileExists(atPath: layout.ownerTokenURL.path) { return false }
    let response: WireResponse
    do {
      response = try connect(layout.socketURL.path).exchange(
        WireRequest(token: nil, operation: "owner.credential"))
    } catch {
      throw InstallError.serviceNotReady("\(error)")
    }
    guard response.isSuccess, case .object(let fields)? = response.result,
      case .string(let token)? = fields["token"]
    else { throw InstallError.ownerCredentialUnavailable }
    do {
      try HostFiles.createExclusively(
        Data((token + "\n").utf8), at: layout.ownerTokenURL, mode: 0o600)
    } catch {
      throw InstallError.ownerTokenNotWritten("\(error)")
    }
    return true
  }
}

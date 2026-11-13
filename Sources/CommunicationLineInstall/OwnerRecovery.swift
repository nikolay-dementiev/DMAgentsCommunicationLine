import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation

public struct OwnerRecoveryReport: Equatable, Sendable, CustomStringConvertible {
  public let ownerTokenPath: String

  public var description: String {
    "owner token file: \(ownerTokenPath)\nthe previous owner token no longer works"
  }
}

/// Gives the owner a new token when the file that held it is lost or was never written.
///
/// It needs the account owner's own access to the store folder and nothing else: no network and no
/// token on the command line. The service is stopped while the database changes, so the swap cannot
/// race with a request, and it is started again afterwards.
public struct OwnerRecovery {
  private struct SystemClock: WallClock {
    func now() -> Date { Date() }
  }

  private let layout: HostLayout
  private let userID: UInt32
  private let launchd: any LaunchdControl
  private let readiness: any ServiceReadiness
  private let readinessSeconds: TimeInterval

  public init(
    layout: HostLayout, userID: UInt32, launchd: any LaunchdControl,
    readiness: any ServiceReadiness, readinessSeconds: TimeInterval = Installer.readinessSeconds
  ) {
    self.layout = layout
    self.userID = userID
    self.launchd = launchd
    self.readiness = readiness
    self.readinessSeconds = readinessSeconds
  }

  public func recover() throws -> OwnerRecoveryReport {
    guard userID != 0 else { throw InstallError.refusedAsRoot }
    guard FileManager.default.fileExists(atPath: layout.manifestURL.path) else {
      throw InstallError.notInstalled
    }
    let wasLoaded = try launchd.isLoaded(label: HostLayout.launchAgentLabel, userID: userID)
    if wasLoaded {
      try launchd.bootout(label: HostLayout.launchAgentLabel, userID: userID)
    }
    do {
      let token = try issueToken()
      do {
        try HostFiles.replace(
          Data((token.encoded + "\n").utf8), at: layout.ownerTokenURL, mode: 0o600)
      } catch {
        throw InstallError.ownerTokenNotWritten("\(error)")
      }
    } catch {
      if wasLoaded { try restartAfterFailure(of: error) }
      throw error
    }
    try launchd.bootstrap(plist: layout.plistURL, userID: userID)
    do {
      try readiness.waitUntilAnswering(socket: layout.socketURL, within: readinessSeconds)
    } catch {
      throw InstallError.serviceNotReady("\(error); see \(layout.logURL.path)")
    }
    return OwnerRecoveryReport(ownerTokenPath: layout.ownerTokenURL.path)
  }

  /// The service ran before the recovery began, so a failed recovery must not leave it stopped.
  /// The original failure stays the error; a failed restart is added to it.
  private func restartAfterFailure(of failure: any Error) throws {
    do {
      try launchd.bootstrap(plist: layout.plistURL, userID: userID)
    } catch {
      throw InstallError.launchd(
        "\(failure); the service could not be started again either: \(error)")
    }
  }

  private func issueToken() throws -> CredentialToken {
    let store: SQLiteStore
    do {
      store = try SQLiteStore.open(
        at: layout.databaseURL, busyTimeoutMilliseconds: 5000, migrations: SchemaMigrations.all)
    } catch {
      throw InstallError.filesystem("the store could not be opened: \(error)")
    }
    defer { store.close() }
    let identity = IdentityService(
      store: SQLiteIdentityStore(store: store), random: SecureRandomSource(),
      identifiers: UUIDIdentifierSource(), clock: SystemClock())
    return try identity.recoverOwnerCredential()
  }
}

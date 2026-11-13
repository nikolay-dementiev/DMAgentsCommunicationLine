import CommunicationLineApplication
import CommunicationLineStore
import Darwin
import Foundation

/// Counts the mail that nobody has acknowledged yet, so that deleting the data never loses it.
public protocol PendingMailCounter {
  func pendingCount(database: URL) throws -> Int
}

/// Reads the count from the database of the store.
public struct StorePendingMailCounter: PendingMailCounter {
  public init() {}

  public func pendingCount(database: URL) throws -> Int {
    let store = try SQLiteStore.open(
      at: database, busyTimeoutMilliseconds: 5000, migrations: SchemaMigrations.all)
    defer { store.close() }
    return try SQLiteHealthStore(store: store).totalPending()
  }
}

public enum UninstallError: Error, Equatable {
  case refusedAsRoot
  case notInstalled
  /// Deleting the data was asked for, but this much mail is still waiting. Nothing was deleted.
  case pendingMail(count: Int, storeFolder: String)
  /// The manifest names a path outside the home folder, so it is not trusted.
  case unsafeManifest(String)
  /// A service still holds the store: launchd did not own it, or started it again.
  case serviceRunning(storeFolder: String)
  case launchd(String)
  case filesystem(String)
}

extension UninstallError: CustomStringConvertible {
  public var description: String {
    switch self {
    case .refusedAsRoot:
      return "uninstall runs under your own account; it does not run as root"
    case .notInstalled:
      return "commline is not installed here: there is no manifest to uninstall from"
    case .pendingMail(let count, let storeFolder):
      return
        "\(count) message(s) are still pending, so nothing was deleted; "
        + "read and acknowledge them first, or keep the data in \(storeFolder). "
        + "The service may have been stopped: run commline install to start it again"
    case .unsafeManifest(let path):
      return "the manifest names a path outside the home folder: \(path); nothing was removed"
    case .serviceRunning(let storeFolder):
      return
        "a commline service is still running on \(storeFolder), so nothing was deleted; "
        + "stop it and run the command again. The launchd job was stopped: "
        + "run commline install to start it again"
    case .launchd(let reason): return "launchd refused the request: \(reason)"
    case .filesystem(let reason): return "a file could not be removed: \(reason)"
    }
  }
}

public struct UninstallReport: Equatable, Sendable {
  public let removed: [String]
  public let storeFolder: String
  public let storeDeleted: Bool
}

/// Removes what the install wrote, as the manifest lists it, and nothing else. The store folder
/// (the database and the tokens) stays unless the caller asks to delete it and no mail is pending.
public struct Uninstaller {
  private let layout: HostLayout
  private let userID: UInt32
  private let launchd: any LaunchdControl
  private let pendingMail: any PendingMailCounter
  private let storeLock: any StoreLocking

  public init(
    layout: HostLayout, userID: UInt32, launchd: any LaunchdControl,
    pendingMail: any PendingMailCounter, storeLock: any StoreLocking = FileStoreLock()
  ) {
    self.layout = layout
    self.userID = userID
    self.launchd = launchd
    self.pendingMail = pendingMail
    self.storeLock = storeLock
  }

  public func uninstall(deleteData: Bool) throws -> UninstallReport {
    guard userID != 0 else { throw UninstallError.refusedAsRoot }
    let manifest = try readManifest()
    try requireRecognised(manifest)
    if deleteData { try requireNoPendingMail(manifest) }
    try unregister(manifest)
    // The lock is taken before the last count and kept until the store is gone: no service can
    // start in between and take mail the count did not see.
    let holding = deleteData ? try acquireStore(manifest) : nil
    defer { holding?.release() }
    if deleteData { try requireNoPendingMail(manifest) }
    var removed = try remove(manifest)
    // The store goes before the manifest, so that a failure here can be retried.
    if deleteData { try removeStore(manifest) }
    removed += try removeManifest()
    // Best effort, as for the program folder: it stays when something else lives in it.
    if deleteData { rmdir(layout.supportFolder.path) }
    return UninstallReport(
      removed: removed, storeFolder: manifest.storeFolder, storeDeleted: deleteData)
  }

  // MARK: - Steps

  private func readManifest() throws -> Manifest {
    guard FileManager.default.fileExists(atPath: layout.manifestURL.path) else {
      throw UninstallError.notInstalled
    }
    do {
      return try Manifest.read(from: layout.manifestURL)
    } catch {
      throw UninstallError.filesystem("\(layout.manifestURL.path) is unreadable: \(error)")
    }
  }

  private func requireRecognised(_ manifest: Manifest) throws {
    if let path = ManifestPolicy(layout: layout).firstRefusedEntry(in: manifest) {
      throw UninstallError.unsafeManifest(path)
    }
    // A registration goes straight to launchd, so only the one this install makes is accepted.
    for case .launchAgent(let label, let owner) in manifest.registrations
    where label != HostLayout.launchAgentLabel || owner != userID {
      throw UninstallError.unsafeManifest("launch agent \(label) of user \(owner)")
    }
  }

  private func acquireStore(_ manifest: Manifest) throws -> any StoreLockHolding {
    do {
      return try storeLock.lock(storeFolder: URL(fileURLWithPath: manifest.storeFolder))
    } catch StoreLockError.held {
      throw UninstallError.serviceRunning(storeFolder: manifest.storeFolder)
    } catch {
      throw UninstallError.filesystem("the store could not be locked: \(error)")
    }
  }

  private func requireNoPendingMail(_ manifest: Manifest) throws {
    let database = URL(fileURLWithPath: manifest.storeFolder, isDirectory: true)
      .appendingPathComponent(layout.databaseURL.lastPathComponent)
    guard FileManager.default.fileExists(atPath: database.path) else { return }
    let count: Int
    do {
      count = try pendingMail.pendingCount(database: database)
    } catch {
      throw UninstallError.filesystem("the pending mail could not be counted: \(error)")
    }
    if count > 0 {
      throw UninstallError.pendingMail(count: count, storeFolder: manifest.storeFolder)
    }
  }

  private func unregister(_ manifest: Manifest) throws {
    for registration in manifest.registrations {
      switch registration {
      case .launchAgent(let label, let registeredUser):
        do {
          if try launchd.isLoaded(label: label, userID: registeredUser) {
            try launchd.bootout(label: label, userID: registeredUser)
          }
        } catch {
          throw UninstallError.launchd("\(error)")
        }
      }
    }
  }

  private func remove(_ manifest: Manifest) throws -> [String] {
    let manifestPath = layout.manifestURL.path
    var removed: [String] = []
    for path in manifest.files where path != manifestPath {
      if try unlinkFile(path) { removed.append(path) }
    }
    for folder in manifest.folders where FileManager.default.fileExists(atPath: folder) {
      do {
        try FileManager.default.removeItem(atPath: folder)
      } catch {
        throw UninstallError.filesystem("\(folder): \(error)")
      }
      removed.append(folder)
    }
    // Best effort: the folder stays when the user put something in it, and that is fine.
    rmdir(layout.binFolder.path)
    return removed
  }

  /// The manifest goes last, so a run that stops half way can be repeated.
  private func removeManifest() throws -> [String] {
    try unlinkFile(layout.manifestURL.path) ? [layout.manifestURL.path] : []
  }

  /// Removes one file, never a folder. A file that is already gone is fine.
  private func unlinkFile(_ path: String) throws -> Bool {
    if unlink(path) == 0 { return true }
    if errno == ENOENT { return false }
    throw UninstallError.filesystem("\(path): \(String(cString: strerror(errno)))")
  }

  private func removeStore(_ manifest: Manifest) throws {
    if FileManager.default.fileExists(atPath: manifest.storeFolder) {
      do {
        try FileManager.default.removeItem(atPath: manifest.storeFolder)
      } catch {
        throw UninstallError.filesystem("\(manifest.storeFolder): \(error)")
      }
    }
  }
}

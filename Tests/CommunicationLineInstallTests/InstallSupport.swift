import Testing
import CommunicationLineInstall
import CommunicationLineWire
import Darwin
import Foundation

/// A throwaway home folder under /tmp. Socket paths are limited to about a hundred bytes, which the
/// usual per-test temporary folders exceed.
final class TemporaryHome {
  let url: URL

  init() throws {
    url = URL(
      fileURLWithPath: "/tmp/cli-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: url)
  }

  func mode(of target: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
    return try #require(attributes[.posixPermissions] as? Int)
  }
}

/// Remembers what was asked of launchd and what the host looked like at that moment.
final class RecordingLaunchd: LaunchdControl, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var calls: [String] = []
  private(set) var loaded = false
  private let observe: @Sendable () -> String

  init(observe: @escaping @Sendable () -> String = { "" }) { self.observe = observe }

  func isLoaded(label: String, userID: UInt32) throws -> Bool {
    lock.withLock { loaded }
  }

  func bootstrap(plist: URL, userID: UInt32) throws {
    lock.withLock {
      calls.append("bootstrap uid=\(userID) \(plist.lastPathComponent) \(observe())")
      loaded = true
    }
  }

  func bootout(label: String, userID: UInt32) throws {
    lock.withLock {
      calls.append("bootout uid=\(userID) \(label)")
      loaded = false
    }
  }
}

struct AlwaysReady: ServiceReadiness {
  func waitUntilAnswering(socket: URL, within seconds: TimeInterval) throws {}
}

struct NeverReady: ServiceReadiness {
  struct NotAnswering: Error {}
  func waitUntilAnswering(socket: URL, within seconds: TimeInterval) throws {
    throw NotAnswering()
  }
}

/// A service that issues one owner credential and then refuses to issue another.
final class FakeOwnerService: ServiceConnection, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var requests: [WireRequest] = []
  private let token: String

  init(token: String = "owner-token-0123456789-abcdefghijklmnopqrstuvwxyz") { self.token = token }

  func exchange(_ request: WireRequest) throws -> WireResponse {
    let first = lock.withLock { () -> Bool in
      requests.append(request)
      return requests.count == 1
    }
    if first { return .success(.object(["token": .string(token)])) }
    return .failure(code: .ownerRequired, message: "the owner token is required")
  }
}

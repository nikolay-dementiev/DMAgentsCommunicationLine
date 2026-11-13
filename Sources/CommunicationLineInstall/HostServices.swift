import Foundation

/// What the install needs from launchd. The real one runs `launchctl`; tests record the calls.
public protocol LaunchdControl {
  func isLoaded(label: String, userID: UInt32) throws -> Bool
  func bootstrap(plist: URL, userID: UInt32) throws
  func bootout(label: String, userID: UInt32) throws
}

/// Waits until the service answers on its socket.
public protocol ServiceReadiness {
  /// - Throws: when nothing answers within `seconds`.
  func waitUntilAnswering(socket: URL, within seconds: TimeInterval) throws
}

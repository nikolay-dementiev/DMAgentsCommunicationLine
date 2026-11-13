import Darwin

/// Who is on the other end of an accepted connection.
public protocol PeerCredentialReader: Sendable {
  func effectiveUserID(ofSocket descriptor: Int32) throws -> UInt32
}

/// Asks the system for the effective user ID the peer had when it connected.
public struct SystemPeerCredentialReader: PeerCredentialReader {
  public init() {}

  public func effectiveUserID(ofSocket descriptor: Int32) throws -> UInt32 {
    var user: uid_t = 0
    var group: gid_t = 0
    guard getpeereid(descriptor, &user, &group) == 0 else {
      throw ServiceHostError.system(operation: "getpeereid", code: errno)
    }
    return user
  }
}

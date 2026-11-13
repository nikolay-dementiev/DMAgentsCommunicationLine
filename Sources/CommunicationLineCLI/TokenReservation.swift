import Darwin
import Foundation

/// A file reserved for a token that the service has not issued yet.
///
/// The file is created before the request is sent, so a path that cannot be used is found out
/// while nothing has changed in the store. Whatever happens afterwards, the file is either filled
/// with the token or removed; an empty file never stays behind.
final class TokenReservation {
  enum Failure: Error, Equatable {
    case cannotCreate(path: String, reason: String)
    case cannotWrite(path: String, reason: String)
  }

  let path: String
  private var descriptor: Int32

  init(path: String) throws {
    self.path = path
    descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw Failure.cannotCreate(path: path, reason: String(cString: strerror(errno)))
    }
    guard fchmod(descriptor, 0o600) == 0 else {
      let reason = String(cString: strerror(errno))
      discard()
      throw Failure.cannotCreate(path: path, reason: reason)
    }
  }

  deinit { discard() }

  /// Writes the token and closes the file. A failed write removes the file.
  func commit(token: String) throws {
    guard descriptor >= 0 else { return }
    let bytes = Array((token + "\n").utf8)
    var offset = 0
    while offset < bytes.count {
      let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
      if written < 0, errno == EINTR { continue }
      guard written > 0 else {
        let reason = String(cString: strerror(errno))
        discard()
        throw Failure.cannotWrite(path: path, reason: reason)
      }
      offset += written
    }
    guard close(descriptor) == 0 else {
      descriptor = -1
      let reason = String(cString: strerror(errno))
      unlink(path)
      throw Failure.cannotWrite(path: path, reason: reason)
    }
    descriptor = -1
  }

  /// Closes and removes the file unless it was committed.
  func discard() {
    guard descriptor >= 0 else { return }
    close(descriptor)
    descriptor = -1
    unlink(path)
  }
}

import Darwin

/// An exclusive lock on a file inside the store folder. It is held for as long as the object lives
/// and is released by the system when the process dies, so a crashed instance never blocks a new one.
final class InstanceLock {
  private var descriptor: Int32

  /// - Throws: ``ServiceHostError/alreadyRunning`` while another instance holds the lock.
  init(path: String) throws {
    descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else {
      throw ServiceHostError.system(operation: "open lock", code: errno)
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(descriptor)
      descriptor = -1
      if code == EWOULDBLOCK { throw ServiceHostError.alreadyRunning }
      throw ServiceHostError.system(operation: "flock", code: code)
    }
  }

  func release() {
    guard descriptor >= 0 else { return }
    close(descriptor)
    descriptor = -1
  }

  deinit { release() }
}

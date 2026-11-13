import CommunicationLineWire
import Darwin
import Foundation

/// The lock a running service holds on its store folder. Taking it proves that no service uses the
/// store, and keeps one from starting until it is released.
public protocol StoreLocking {
  /// - Throws: ``StoreLockError/held`` while a service holds the lock.
  func lock(storeFolder: URL) throws -> any StoreLockHolding
}

public protocol StoreLockHolding {
  func release()
}

public enum StoreLockError: Error, Equatable {
  /// A service (or another uninstall) holds the lock.
  case held
  case system(String)
}

/// The same `flock` on `commline.lock` that the service takes at start, so the two exclude each
/// other whether or not launchd started the service.
public struct FileStoreLock: StoreLocking {
  public init() {}

  public func lock(storeFolder: URL) throws -> any StoreLockHolding {
    var isFolder: ObjCBool = false
    guard FileManager.default.fileExists(atPath: storeFolder.path, isDirectory: &isFolder),
      isFolder.boolValue
    else { return Holding(descriptor: -1) }
    let path = storeFolder.appendingPathComponent(ServiceFiles.lockName).path
    let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      throw StoreLockError.system("open \(path): \(String(cString: strerror(errno)))")
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      close(descriptor)
      if code == EWOULDBLOCK { throw StoreLockError.held }
      throw StoreLockError.system("flock \(path): \(String(cString: strerror(code)))")
    }
    return Holding(descriptor: descriptor)
  }

  private final class Holding: StoreLockHolding {
    private var descriptor: Int32

    init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { release() }

    func release() {
      guard descriptor >= 0 else { return }
      close(descriptor)
      descriptor = -1
    }
  }
}

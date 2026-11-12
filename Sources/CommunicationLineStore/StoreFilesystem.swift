import Darwin
import Foundation

/// Creates and checks the store's folder and files so that only the owner can reach them,
/// whatever the process umask is.
enum StoreFilesystem {
  static let folderMode: mode_t = 0o700
  static let fileMode: mode_t = 0o600

  /// Creates the folder with mode 0700 when it is missing; an existing folder must already be private.
  ///
  /// A strict umask makes the creator's folder briefly narrower than the owner needs, until its
  /// explicit `chmod` lands. Other processes wait for that, for at most `timeoutMilliseconds`.
  static func prepareFolder(_ folder: URL, waitingUpTo timeoutMilliseconds: Int) throws {
    let path = folder.path
    if try entry(at: path) == nil {
      if mkdir(path, folderMode) == 0 {
        // The umask can only remove bits from the mode given to mkdir; set it explicitly afterwards.
        guard chmod(path, folderMode) == 0 else {
          throw StoreError.posix(operation: "set folder mode", path: path, code: errno)
        }
      } else if errno != EEXIST {
        // EEXIST means another process created it first; it is checked below like any existing folder.
        throw StoreError.posix(operation: "create folder", path: path, code: errno)
      }
    }
    try awaitOwnerAccess(path, bits: 0o700, waitingUpTo: timeoutMilliseconds)
    try verify(path, kind: S_IFDIR, maximumMode: folderMode)
  }

  /// Creates the database file with mode 0600 when it is missing; an existing file must already be private.
  static func prepareDatabaseFile(_ file: URL, waitingUpTo timeoutMilliseconds: Int) throws {
    let path = file.path
    if try entry(at: path) == nil {
      let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, fileMode)
      if descriptor >= 0 {
        defer { close(descriptor) }
        guard fchmod(descriptor, fileMode) == 0 else {
          throw StoreError.posix(operation: "set database file mode", path: path, code: errno)
        }
      } else if errno != EEXIST {
        // EEXIST means another process created it first; it is checked below like any existing file.
        throw StoreError.posix(operation: "create database file", path: path, code: errno)
      }
    }
    try awaitOwnerAccess(path, bits: 0o600, waitingUpTo: timeoutMilliseconds)
    try verify(path, kind: S_IFREG, maximumMode: fileMode)
  }

  /// Runs `body` while holding an exclusive advisory lock on the store folder, so that only one
  /// process at a time sets the store up. The folder is locked rather than the database file because
  /// SQLite takes its own `flock` locks on that file. SQLite creates the write-ahead log and shared-memory files
  /// itself and fixes their mode a moment later; the lock keeps other processes from meeting them
  /// in between. Waits at most `timeoutMilliseconds` for the lock.
  static func withSetupLock<T>(
    on folder: URL, waitingUpTo timeoutMilliseconds: Int, _ body: () throws -> T
  ) throws -> T {
    let path = folder.path
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    guard descriptor >= 0 else {
      throw StoreError.posix(operation: "open store folder for locking", path: path, code: errno)
    }
    defer { close(descriptor) }
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000)
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK, Date() < deadline else {
        throw StoreError.posix(operation: "lock store folder", path: path, code: errno)
      }
      Thread.sleep(forTimeInterval: 0.005)
    }
    defer { flock(descriptor, LOCK_UN) }
    return try body()
  }

  /// Checks the write-ahead log and shared-memory files of `database` when they exist.
  static func verifySidecars(of database: URL) throws {
    for suffix in ["-wal", "-shm"] {
      let path = database.path + suffix
      if try entry(at: path) != nil {
        try verify(path, kind: S_IFREG, maximumMode: fileMode)
      }
    }
  }

  /// Waits until the owner has `bits` on the entry. An entry that never gets them (for example one
  /// the user made read-only) is left to fail in the next step with the system's own error.
  private static func awaitOwnerAccess(
    _ path: String, bits: mode_t, waitingUpTo timeoutMilliseconds: Int
  ) throws {
    let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1000)
    while let info = try entry(at: path), info.st_mode & bits != bits, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.005)
    }
  }

  private static func entry(at path: String) throws -> stat? {
    var info = stat()
    if lstat(path, &info) == 0 { return info }
    guard errno == ENOENT else {
      throw StoreError.posix(operation: "inspect", path: path, code: errno)
    }
    return nil
  }

  private static func verify(_ path: String, kind: mode_t, maximumMode: mode_t) throws {
    guard let info = try entry(at: path), info.st_mode & S_IFMT == kind else {
      throw StoreError.unexpectedFileType(path: path)
    }
    let mode = info.st_mode & 0o777
    guard mode & ~maximumMode == 0 else {
      throw StoreError.insecurePermissions(
        path: path, mode: Int(mode), maximumMode: Int(maximumMode))
    }
  }
}

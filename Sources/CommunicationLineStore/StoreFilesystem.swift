import Darwin
import Foundation

/// Creates and checks the store's folder and files so that only the owner can reach them,
/// whatever the process umask is.
enum StoreFilesystem {
  static let folderMode: mode_t = 0o700
  static let fileMode: mode_t = 0o600

  /// Creates the folder with mode 0700 when it is missing; an existing folder must already be private.
  static func prepareFolder(_ folder: URL) throws {
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
    try verify(path, kind: S_IFDIR, maximumMode: folderMode)
  }

  /// Creates the database file with mode 0600 when it is missing; an existing file must already be private.
  static func prepareDatabaseFile(_ file: URL) throws {
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
    try verify(path, kind: S_IFREG, maximumMode: fileMode)
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

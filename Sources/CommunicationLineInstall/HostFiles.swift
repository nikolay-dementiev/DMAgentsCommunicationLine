import Darwin
import Foundation

enum HostFileError: Error {
  case system(String, Int32)
}

/// File writes with an explicit mode, whatever the umask of the caller is.
enum HostFiles {
  /// Creates the folder (and its parents) and sets `mode` on the last one.
  static func makeFolder(_ url: URL, mode: Int) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
  }

  /// Writes `data` to a new file at `url` with `mode`; fails when the file already exists.
  static func createExclusively(_ data: Data, at url: URL, mode: mode_t) throws {
    let descriptor = open(
      url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
    guard descriptor >= 0 else { throw HostFileError.system("create \(url.path)", errno) }
    defer { close(descriptor) }
    do {
      guard fchmod(descriptor, mode) == 0 else { throw HostFileError.system("chmod", errno) }
      try writeAll(data, to: descriptor, path: url.path)
    } catch {
      // A half-written file would be taken for a finished one by the next run.
      unlink(url.path)
      throw error
    }
  }

  /// Replaces the file at `url` in one step: the new contents are written next to it and renamed
  /// over it, so a reader never sees half a file.
  static func replace(_ data: Data, at url: URL, mode: mode_t) throws {
    let staged = url.deletingLastPathComponent()
      .appendingPathComponent(".\(url.lastPathComponent).new")
    unlink(staged.path)
    try createExclusively(data, at: staged, mode: mode)
    guard rename(staged.path, url.path) == 0 else {
      let code = errno
      unlink(staged.path)
      throw HostFileError.system("replace \(url.path)", code)
    }
  }

  /// Replaces the folder at `target` with a copy of `source`. The copy is made beside the target
  /// first and swapped in, so a copy that fails leaves the old folder as it was.
  static func replaceFolder(from source: URL, to target: URL) throws {
    let manager = FileManager.default
    let staged = target.deletingLastPathComponent()
      .appendingPathComponent(".\(target.lastPathComponent).new")
    if manager.fileExists(atPath: staged.path) { try manager.removeItem(at: staged) }
    do {
      try manager.copyItem(at: source, to: staged)
      if manager.fileExists(atPath: target.path) {
        _ = try manager.replaceItemAt(target, withItemAt: staged)
      } else {
        try manager.moveItem(at: staged, to: target)
      }
    } catch {
      // The copy error is the one that matters; a staged folder that stays is replaced next time.
      if manager.fileExists(atPath: staged.path) { try? manager.removeItem(at: staged) }
      throw error
    }
  }

  /// Creates the file empty with `mode` unless it exists; an existing file keeps its contents.
  static func ensureFile(at url: URL, mode: mode_t) throws {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode)
    guard descriptor >= 0 else { throw HostFileError.system("create \(url.path)", errno) }
    defer { close(descriptor) }
    guard fchmod(descriptor, mode) == 0 else { throw HostFileError.system("chmod", errno) }
  }

  private static func writeAll(_ data: Data, to descriptor: Int32, path: String) throws {
    var offset = 0
    try data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      while offset < buffer.count {
        let written = write(descriptor, base + offset, buffer.count - offset)
        if written < 0 {
          if errno == EINTR { continue }
          throw HostFileError.system("write \(path)", errno)
        }
        offset += written
      }
    }
  }
}

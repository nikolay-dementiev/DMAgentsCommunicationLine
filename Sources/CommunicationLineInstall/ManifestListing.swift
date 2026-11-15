import Darwin
import Foundation

/// Lists a file in the manifest of an install, so that uninstall removes it.
public protocol ManifestListing {
  func list(file path: String) throws
}

/// Reads the manifest, adds the path and replaces the file, holding an exclusive lock on the folder
/// of the manifest from the read to the replace. Two runs at once therefore take turns, and the
/// second one reads what the first one wrote. The folder is locked, not the manifest: replacing
/// the manifest swaps the file, which would drop a lock held on the old one, and no lock file is
/// left behind for uninstall to remove.
public struct FileManifestListing: ManifestListing {
  private let manifestURL: URL
  private let read: (URL) throws -> Manifest

  /// `read` is the way the manifest is read; a test replaces it to stop between the read and the
  /// write.
  public init(
    manifestURL: URL, read: @escaping (URL) throws -> Manifest = { try Manifest.read(from: $0) }
  ) {
    self.manifestURL = manifestURL
    self.read = read
  }

  public func list(file path: String) throws {
    let folder = manifestURL.deletingLastPathComponent().path
    let descriptor = open(folder, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw HostFileError.system("open \(folder)", errno) }
    defer { close(descriptor) }
    // Blocks until the other run is done; the lock goes with the descriptor.
    guard flock(descriptor, LOCK_EX) == 0 else {
      throw HostFileError.system("lock \(folder)", errno)
    }
    var manifest = try read(manifestURL)
    manifest.files.append(path)
    try manifest.write(to: manifestURL)
  }
}

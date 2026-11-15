import Foundation

/// Lists a file in the manifest of an install, so that uninstall removes it.
public protocol ManifestListing {
  func list(file path: String) throws
}

/// Reads the manifest, adds the path and replaces the file.
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
    var manifest = try read(manifestURL)
    manifest.files.append(path)
    try manifest.write(to: manifestURL)
  }
}

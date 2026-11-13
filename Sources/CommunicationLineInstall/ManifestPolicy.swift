import Darwin
import Foundation

/// What an install can have written, derived from the layout and not from the manifest. The
/// manifest is a file on disk that anyone running as the account can change, so uninstall removes
/// only entries that match this policy.
struct ManifestPolicy {
  let layout: HostLayout

  func isCommandFile(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let name = url.lastPathComponent
    return same(url.deletingLastPathComponent(), layout.claudeCommandsFolder)
      && name.hasPrefix("commline-") && name.hasSuffix(".md")
  }

  func isResourceBundle(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    return same(url.deletingLastPathComponent(), layout.binFolder)
      && url.lastPathComponent.hasPrefix("CommunicationLine_") && url.pathExtension == "bundle"
  }

  func isFileToRemove(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let fixed = [
      layout.clientBinary, layout.serviceBinary, layout.plistURL, layout.manifestURL,
    ]
    return fixed.contains { same($0, url) } || isCommandFile(path)
  }

  func isStoreFolder(_ path: String) -> Bool {
    same(URL(fileURLWithPath: path), layout.storeFolder)
  }

  /// The first entry of the manifest that this install would not have written, or that is a
  /// symbolic link (which would send a removal somewhere else).
  func firstRefusedEntry(in manifest: Manifest) -> String? {
    if let path = manifest.files.first(where: { !isFileToRemove($0) || isLink($0) }) { return path }
    if let path = manifest.folders.first(where: { !isResourceBundle($0) || isLink($0) }) {
      return path
    }
    return isStoreFolder(manifest.storeFolder) ? nil : manifest.storeFolder
  }

  private func same(_ left: URL, _ right: URL) -> Bool {
    left.standardizedFileURL.path == right.standardizedFileURL.path
  }

  private func isLink(_ path: String) -> Bool {
    var status = stat()
    return lstat(path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFLNK
  }
}

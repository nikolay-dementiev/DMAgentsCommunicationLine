import CommunicationLineInstall
import Dispatch
import Foundation
import Testing

/// Two `agent add` runs list a command file each. The manifest is read, changed and replaced, so
/// without a lock the run that writes last drops the entry of the other one.
struct ManifestLockTests {
  private func makeManifest(in home: TemporaryHome) throws -> URL {
    let layout = HostLayout(home: home.url)
    try FileManager.default.createDirectory(
      at: layout.supportFolder, withIntermediateDirectories: true)
    try Manifest(files: [], registrations: [], storeFolder: layout.storeFolder.path)
      .write(to: layout.manifestURL)
    return layout.manifestURL
  }

  @Test func test_twoRunsAtOnce_bothEntriesEndUpInTheManifest() throws {
    let home = try TemporaryHome()
    let manifestURL = try makeManifest(in: home)
    let firstHasRead = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondHasRead = DispatchSemaphore(value: 0)
    let first = FileManifestListing(manifestURL: manifestURL) { url in
      let manifest = try Manifest.read(from: url)
      firstHasRead.signal()
      releaseFirst.wait()
      return manifest
    }
    let second = FileManifestListing(manifestURL: manifestURL) { url in
      let manifest = try Manifest.read(from: url)
      secondHasRead.signal()
      return manifest
    }
    let finished = DispatchGroup()
    nonisolated(unsafe) var failures: [Error] = []
    let failuresLock = NSLock()
    func run(_ listing: FileManifestListing, _ path: String) {
      finished.enter()
      Thread.detachNewThread {
        do {
          try listing.list(file: path)
        } catch {
          failuresLock.withLock { failures.append(error) }
        }
        finished.leave()
      }
    }

    run(first, "/commands/first.md")
    firstHasRead.wait()
    run(second, "/commands/second.md")
    let secondReadEarly = secondHasRead.wait(timeout: .now() + 0.4) == .success
    releaseFirst.signal()
    finished.wait()

    #expect(
      !secondReadEarly, "the second run waited for the first one before it read the manifest")
    #expect(failures.isEmpty, "neither run failed: \(failures)")
    #expect(
      Set(try Manifest.read(from: manifestURL).files)
        == ["/commands/first.md", "/commands/second.md"],
      "both command files are listed")
  }
}

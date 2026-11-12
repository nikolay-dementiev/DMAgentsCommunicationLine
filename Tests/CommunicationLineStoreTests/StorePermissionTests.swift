import CommunicationLineStore
import Darwin
import Foundation
import Testing

@Suite(.serialized) struct StorePermissionTests {
  private let migrations = [
    Migration(version: 1, statements: ["CREATE TABLE widgets (id INTEGER PRIMARY KEY)"])
  ]

  private func mode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
  }

  private func open(_ url: URL) throws -> SQLiteStore {
    try SQLiteStore.open(at: url, busyTimeoutMilliseconds: 1000, migrations: migrations)
  }

  @Test(arguments: [mode_t(0o022), mode_t(0o000), mode_t(0o077), mode_t(0o277)])
  func test_open_freshStore_createsPrivateFolderAndFilesWhateverTheUmask(mask: mode_t) throws {
    let scratch = try TemporaryDirectory()
    let previous = umask(mask)
    defer { umask(previous) }
    let database = scratch.storePath
    let store = try open(database)

    #expect(try mode(of: database.deletingLastPathComponent()) == 0o700, "folder is owner-only")
    #expect(try mode(of: database) == 0o600, "database file is owner read and write only")
    let write = URL(fileURLWithPath: database.path + "-wal")
    let shared = URL(fileURLWithPath: database.path + "-shm")
    #expect(try mode(of: write) == 0o600, "write-ahead log is owner read and write only")
    #expect(try mode(of: shared) == 0o600, "shared-memory file is owner read and write only")
    withExtendedLifetime(store) {}
  }

  @Test func test_open_existingFolderWiderThanOwnerOnly_failsAndLeavesItAlone() throws {
    let scratch = try TemporaryDirectory()
    let folder = scratch.storePath.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o755])

    #expect(
      throws: StoreError.insecurePermissions(path: folder.path, mode: 0o755, maximumMode: 0o700)
    ) {
      _ = try open(scratch.storePath)
    }
    #expect(try mode(of: folder) == 0o755, "the folder was not silently changed")
  }

  @Test func test_open_existingDatabaseWiderThanOwnerOnly_failsAndLeavesItAlone() throws {
    let scratch = try TemporaryDirectory()
    _ = try open(scratch.storePath)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o644], ofItemAtPath: scratch.storePath.path)

    #expect(
      throws: StoreError.insecurePermissions(
        path: scratch.storePath.path, mode: 0o644, maximumMode: 0o600)
    ) {
      _ = try open(scratch.storePath)
    }
    #expect(try mode(of: scratch.storePath) == 0o644, "the file was not silently changed")
  }

  @Test func test_open_databasePathIsASymbolicLink_isRejected() throws {
    let scratch = try TemporaryDirectory()
    let folder = scratch.storePath.deletingLastPathComponent()
    try FileManager.default.createDirectory(
      at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let target = scratch.url.appending(path: "elsewhere.sqlite")
    #expect(FileManager.default.createFile(atPath: target.path, contents: nil), "target created")
    try FileManager.default.createSymbolicLink(at: scratch.storePath, withDestinationURL: target)

    #expect(throws: StoreError.unexpectedFileType(path: scratch.storePath.path)) {
      _ = try open(scratch.storePath)
    }
  }

  @Test func test_open_negativeBusyTimeout_isRejected() throws {
    let scratch = try TemporaryDirectory()

    #expect(throws: StoreError.invalidBusyTimeout(-1)) {
      _ = try SQLiteStore.open(
        at: scratch.storePath, busyTimeoutMilliseconds: -1, migrations: migrations)
    }
  }

  @Test func test_open_existingWriteAheadLogWiderThanOwnerOnly_failsAndLeavesItAlone() throws {
    let scratch = try TemporaryDirectory()
    _ = try open(scratch.storePath)
    let log = URL(fileURLWithPath: scratch.storePath.path + "-wal")
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: log.path)

    #expect(
      throws: StoreError.insecurePermissions(path: log.path, mode: 0o666, maximumMode: 0o600)
    ) {
      _ = try open(scratch.storePath)
    }
    #expect(try mode(of: log) == 0o666, "the log was not silently changed")
  }

  @Test func test_open_folderPathIsARegularFile_isRejected() throws {
    let scratch = try TemporaryDirectory()
    let folder = scratch.storePath.deletingLastPathComponent()
    #expect(FileManager.default.createFile(atPath: folder.path, contents: nil), "file created")

    #expect(throws: StoreError.unexpectedFileType(path: folder.path)) {
      _ = try open(scratch.storePath)
    }
  }
}

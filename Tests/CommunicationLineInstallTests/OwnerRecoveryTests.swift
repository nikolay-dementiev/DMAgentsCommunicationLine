import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineInstall
import CommunicationLineStore
import CommunicationLineWire
import Foundation
import Testing

struct OwnerRecoveryTests {
  private struct Clock: WallClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
  }

  private struct World {
    let home: TemporaryHome
    let layout: HostLayout
    let launchd: RecordingLaunchd
    let oldToken: CredentialToken

    init() throws {
      home = try TemporaryHome()
      let executables = try TemporaryHome()
      layout = HostLayout(home: home.url)
      for name in ["commline", "commline-service"] {
        FileManager.default.createFile(
          atPath: executables.url.appendingPathComponent(name).path, contents: Data("x".utf8))
      }
      launchd = RecordingLaunchd()
      let service = FakeOwnerService()
      _ = try Installer(
        layout: layout, executableFolder: executables.url, userID: 501, launchd: launchd,
        readiness: AlwaysReady(), connect: { _ in service }
      ).install()
      oldToken = try Self.identity(layout) { try $0.issueOwnerCredential(replacing: nil) }
    }

    static func identity<T>(_ layout: HostLayout, _ body: (IdentityService) throws -> T) throws
      -> T
    {
      let store = try SQLiteStore.open(
        at: layout.databaseURL, busyTimeoutMilliseconds: 1000, migrations: SchemaMigrations.all)
      defer { store.close() }
      return try body(
        IdentityService(
          store: SQLiteIdentityStore(store: store), random: SecureRandomSource(),
          identifiers: UUIDIdentifierSource(), clock: Clock()))
    }

    func recover(userID: UInt32 = 501) throws -> OwnerRecoveryReport {
      try OwnerRecovery(
        layout: layout, userID: userID, launchd: launchd, readiness: AlwaysReady()
      ).recover()
    }
  }

  @Test func test_recover_givesTheOwnerAWorkingTokenAndRevokesTheOldOne() throws {
    let world = try World()
    FileManager.default.createFile(atPath: world.layout.ownerTokenURL.path, contents: Data())

    let report = try world.recover()

    let text = try String(contentsOf: world.layout.ownerTokenURL, encoding: .utf8)
      .trimmingCharacters(in: .newlines)
    let fresh = try #require(CredentialToken(encoded: text), "the file holds a token")
    #expect(report.ownerTokenPath == world.layout.ownerTokenURL.path, "the report names the file")
    #expect(try world.home.mode(of: world.layout.ownerTokenURL) == 0o600, "owner-only file")
    #expect(!"\(report)".contains(text), "the report never holds the token")
    try World.identity(world.layout) { (identity: IdentityService) throws in
      let actor = try identity.authenticate(fresh)
      #expect(actor == .owner, "the new token is the owner's")
      #expect(throws: IdentityError.self, "the old token no longer works") {
        _ = try identity.authenticate(world.oldToken)
      }
    }
  }

  @Test func test_recover_stopsTheServiceWhileItWorks_andStartsItAgain() throws {
    let world = try World()

    _ = try world.recover()

    #expect(
      world.launchd.calls.map { $0.split(separator: " ").first.map(String.init) ?? "" } == [
        "bootstrap", "bootout", "bootstrap",
      ], "the service is unloaded before the database is touched and loaded afterwards")
  }

  @Test func test_recover_withoutAnInstall_orAsRoot_isRefused() throws {
    let world = try World()
    let empty = try TemporaryHome()
    let uninstalled = OwnerRecovery(
      layout: HostLayout(home: empty.url), userID: 501, launchd: RecordingLaunchd(),
      readiness: AlwaysReady())

    #expect(throws: InstallError.notInstalled) { _ = try uninstalled.recover() }
    #expect(throws: InstallError.refusedAsRoot) { _ = try world.recover(userID: 0) }
    #expect(
      world.launchd.calls.count == 1, "a refused recovery leaves the service alone")
  }
}

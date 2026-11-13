import CommunicationLineInstall
import CommunicationLineWire
import Foundation
import Testing

struct InstallerTests {
  private struct World {
    let home: TemporaryHome
    let executables: TemporaryHome
    let layout: HostLayout
    let launchd: RecordingLaunchd
    let service: FakeOwnerService
    let installer: Installer

    init(userID: UInt32 = 501, readiness: any ServiceReadiness = AlwaysReady()) throws {
      home = try TemporaryHome()
      executables = try TemporaryHome()
      layout = HostLayout(home: home.url)
      for name in ["commline", "commline-service"] {
        FileManager.default.createFile(
          atPath: executables.url.appendingPathComponent(name).path,
          contents: Data("binary \(name)".utf8))
      }
      let plist = layout.plistURL
      launchd = RecordingLaunchd(observe: {
        FileManager.default.fileExists(atPath: plist.path) ? "plist-present" : "plist-missing"
      })
      service = FakeOwnerService()
      installer = Installer(
        layout: layout, executableFolder: executables.url, userID: userID, launchd: launchd,
        readiness: readiness, connect: { [service] _ in service })
    }
  }

  @Test func test_install_asRoot_isRefusedAndWritesNothing() throws {
    let world = try World(userID: 0)

    #expect(throws: InstallError.refusedAsRoot) { _ = try world.installer.install() }

    #expect(
      try FileManager.default.contentsOfDirectory(atPath: world.home.url.path).isEmpty,
      "the home folder is untouched")
    #expect(world.launchd.calls.isEmpty, "launchd was not asked for anything")
  }

  @Test func test_install_copiesTheBinariesNextToEachOther() throws {
    let world = try World()

    _ = try world.installer.install()

    for name in ["commline", "commline-service"] {
      let target = world.layout.binFolder.appendingPathComponent(name)
      #expect(
        try String(contentsOf: target, encoding: .utf8) == "binary \(name)", "\(name) is copied")
      #expect(try world.home.mode(of: target) == 0o755, "\(name) is runnable and not writable")
    }
  }

  @Test func test_install_missingBinary_isAnErrorBeforeAnythingIsWritten() throws {
    let world = try World()
    try FileManager.default.removeItem(
      at: world.executables.url.appendingPathComponent("commline-service"))

    #expect(throws: InstallError.missingExecutable("commline-service")) {
      _ = try world.installer.install()
    }

    #expect(
      !FileManager.default.fileExists(atPath: world.layout.supportFolder.path),
      "no install folder was created")
  }

  @Test func test_install_createsAPrivateStoreWithItsDatabaseAndLog() throws {
    let world = try World()

    _ = try world.installer.install()

    #expect(try world.home.mode(of: world.layout.storeFolder) == 0o700, "the store is private")
    #expect(
      FileManager.default.fileExists(
        atPath: world.layout.storeFolder.appendingPathComponent("commline.sqlite").path),
      "the database exists, migrated")
    #expect(try world.home.mode(of: world.layout.logURL) == 0o600, "the log is private")
  }

  @Test func test_theLaunchAgent_runsTheInstalledServiceOnTheStoreAndHoldsNoSecret() throws {
    let world = try World()

    _ = try world.installer.install()

    let data = try Data(contentsOf: world.layout.plistURL)
    let plist = try #require(
      try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(plist["Label"] as? String == HostLayout.launchAgentLabel, "the label")
    #expect(
      plist["ProgramArguments"] as? [String] == [
        world.layout.serviceBinary.path, world.layout.storeFolder.path,
      ], "the installed service and the store, nothing else")
    #expect(plist["RunAtLoad"] as? Bool == true, "starts at load")
    #expect(
      (plist["KeepAlive"] as? [String: Bool]) == ["SuccessfulExit": false],
      "restarted after a crash, not after a clean stop")
    #expect(plist["StandardOutPath"] as? String == world.layout.logURL.path, "stdout log")
    #expect(plist["StandardErrorPath"] as? String == world.layout.logURL.path, "stderr log")
    #expect(plist["EnvironmentVariables"] == nil, "no environment, so no secret in it")
    let token = try String(contentsOf: world.layout.ownerTokenURL, encoding: .utf8)
    #expect(
      !String(decoding: data, as: UTF8.self).contains(token.trimmingCharacters(in: .newlines)),
      "the owner token is not in the plist")
  }

  @Test func test_launchd_isAskedOnceAfterThePlistIsInPlace() throws {
    let world = try World()

    _ = try world.installer.install()

    #expect(
      world.launchd.calls == [
        "bootstrap uid=501 \(HostLayout.launchAgentLabel).plist plist-present"
      ],
      "one bootstrap for the user's domain, with the plist already written")
  }

  @Test func test_theOwnerToken_isStoredPrivately_andNeverPrinted() throws {
    let world = try World()

    let report = try world.installer.install()

    let token = "owner-token-0123456789-abcdefghijklmnopqrstuvwxyz"
    #expect(
      try String(contentsOf: world.layout.ownerTokenURL, encoding: .utf8)
        .trimmingCharacters(in: .newlines) == token, "the issued token is in the file")
    #expect(try world.home.mode(of: world.layout.ownerTokenURL) == 0o600, "owner-only")
    #expect(report.ownerTokenPath == world.layout.ownerTokenURL.path, "the report names the path")
    #expect(!"\(report)".contains(token), "the report never holds the token")
  }

  @Test func test_aSecondInstall_replacesTheProgram_butKeepsTheDatabaseAndTheOwnerToken() throws {
    let world = try World()
    _ = try world.installer.install()
    let database = world.layout.storeFolder.appendingPathComponent("commline.sqlite")
    let before =
      try FileManager.default.attributesOfItem(atPath: database.path)[
        .systemFileNumber] as? Int
    let tokenBefore = try String(contentsOf: world.layout.ownerTokenURL, encoding: .utf8)
    FileManager.default.createFile(
      atPath: world.executables.url.appendingPathComponent("commline").path,
      contents: Data("new commline".utf8))

    let report = try world.installer.install()

    #expect(report.upgraded, "the report says this was an upgrade")
    #expect(
      try String(
        contentsOf: world.layout.binFolder.appendingPathComponent("commline"), encoding: .utf8)
        == "new commline", "the program was replaced")
    #expect(
      try FileManager.default.attributesOfItem(atPath: database.path)[.systemFileNumber] as? Int
        == before, "the database file is the same file")
    #expect(
      try String(contentsOf: world.layout.ownerTokenURL, encoding: .utf8) == tokenBefore,
      "the owner token did not change")
    #expect(world.service.requests.count == 1, "no second owner credential was asked for")
    #expect(
      world.launchd.calls.map { $0.split(separator: " ").first.map(String.init) ?? "" } == [
        "bootstrap", "bootout", "bootstrap",
      ], "the running service is unloaded before it is loaded again")
  }

  @Test func test_aServiceThatNeverAnswers_failsTheInstallInsteadOfHanging() throws {
    let world = try World(readiness: NeverReady())

    #expect(throws: InstallError.self) { _ = try world.installer.install() }

    #expect(
      !FileManager.default.fileExists(atPath: world.layout.ownerTokenURL.path),
      "no token was written for a service that is not there")
  }

  @Test func test_anExistingOwnerCredentialWithoutItsFile_isReportedNotReplaced() throws {
    let world = try World()
    _ = try world.service.exchange(WireRequest(token: nil, operation: "owner.credential"))

    #expect(throws: InstallError.ownerCredentialUnavailable) {
      _ = try world.installer.install()
    }

    #expect(
      !FileManager.default.fileExists(atPath: world.layout.ownerTokenURL.path),
      "no token file was invented")
  }

  @Test func test_theManifest_namesEveryFileAndRegistrationTheInstallMade() throws {
    let world = try World()

    _ = try world.installer.install()

    let manifest = try Manifest.read(from: world.layout.manifestURL)
    #expect(
      Set(manifest.files) == [
        world.layout.clientBinary.path, world.layout.serviceBinary.path, world.layout.plistURL.path,
        world.layout.manifestURL.path,
      ], "the binaries, the plist and the manifest; the store is kept apart")
    #expect(
      manifest.registrations == [
        .launchAgent(label: HostLayout.launchAgentLabel, userID: 501)
      ], "the launchd registration")
    #expect(manifest.storeFolder == world.layout.storeFolder.path, "where the data is")
  }
}

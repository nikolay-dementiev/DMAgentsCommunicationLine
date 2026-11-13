import CommunicationLineInstall
import CommunicationLineWire
import Foundation
import Testing

/// Answers the pending count from a script: one value per question, the last one repeats.
final class ScriptedPendingCount: PendingMailCounter, @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [Int]
  private(set) var asked = 0

  init(_ answers: [Int]) { self.answers = answers }

  func pendingCount(database: URL) throws -> Int {
    lock.withLock {
      asked += 1
      return answers.count > 1 ? answers.removeFirst() : (answers.first ?? 0)
    }
  }
}

struct UninstallerTests {
  private struct World {
    let home: TemporaryHome
    let layout: HostLayout
    let launchd: RecordingLaunchd
    let pending: ScriptedPendingCount

    init(pending answers: [Int] = [0]) throws {
      home = try TemporaryHome()
      let executables = try TemporaryHome()
      layout = HostLayout(home: home.url)
      for name in ["commline", "commline-service"] {
        FileManager.default.createFile(
          atPath: executables.url.appendingPathComponent(name).path,
          contents: Data("binary \(name)".utf8))
      }
      launchd = RecordingLaunchd()
      pending = ScriptedPendingCount(answers)
      let service = FakeOwnerService()
      _ = try Installer(
        layout: layout, executableFolder: executables.url, userID: 501, launchd: launchd,
        readiness: AlwaysReady(), connect: { _ in service }
      ).install()
    }

    func uninstaller(userID: UInt32 = 501) -> Uninstaller {
      Uninstaller(layout: layout, userID: userID, launchd: launchd, pendingMail: pending)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func plant(_ url: URL, _ text: String = "mine") throws {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      FileManager.default.createFile(atPath: url.path, contents: Data(text.utf8))
    }
  }

  @Test func test_uninstall_removesWhatTheInstallWrote_andKeepsTheStore() throws {
    let world = try World()

    let report = try world.uninstaller().uninstall(deleteData: false)

    for gone in [
      world.layout.clientBinary, world.layout.serviceBinary, world.layout.plistURL,
      world.layout.manifestURL, world.layout.binFolder,
    ] {
      #expect(!world.exists(gone), "\(gone.lastPathComponent) is removed")
    }
    #expect(world.exists(world.layout.databaseURL), "the database stays")
    #expect(world.exists(world.layout.ownerTokenURL), "the owner token stays")
    #expect(report.storeFolder == world.layout.storeFolder.path, "the report names the store")
    #expect(!report.storeDeleted, "the store was kept")
    #expect(world.launchd.calls.last == "bootout uid=501 \(HostLayout.launchAgentLabel)", "stopped")
    #expect(world.pending.asked == 0, "keeping the data needs no look at the mail")
  }

  @Test func test_uninstall_neverRemovesAFileThatIsNotInTheManifest() throws {
    let world = try World()
    let strangers = [
      world.layout.binFolder.appendingPathComponent("my-notes.txt"),
      world.layout.launchAgentsFolder.appendingPathComponent("com.other.agent.plist"),
      world.layout.claudeCommandsFolder.appendingPathComponent("my-command.md"),
    ]
    for stranger in strangers { try world.plant(stranger) }

    _ = try world.uninstaller().uninstall(deleteData: false)

    for stranger in strangers {
      #expect(world.exists(stranger), "\(stranger.lastPathComponent) is not ours and stays")
    }
  }

  @Test func test_uninstall_removesTheCommandFilesTheManifestNames() throws {
    let world = try World()
    let command = world.layout.claudeCommandsFolder.appendingPathComponent("commline-lead.md")
    try world.plant(command)
    var manifest = try Manifest.read(from: world.layout.manifestURL)
    manifest.files.append(command.path)
    try manifest.write(to: world.layout.manifestURL)

    _ = try world.uninstaller().uninstall(deleteData: false)

    #expect(!world.exists(command), "a recorded command file is removed")
  }

  @Test func test_uninstall_removesTheFoldersTheManifestNames_andNoOtherFolder() throws {
    let world = try World()
    let ours = world.layout.binFolder.appendingPathComponent(
      "CommunicationLine_Ours.bundle", isDirectory: true)
    let theirs = world.layout.binFolder.appendingPathComponent("Theirs.bundle", isDirectory: true)
    try world.plant(ours.appendingPathComponent("Contents/data"))
    try world.plant(theirs.appendingPathComponent("Contents/data"))
    var manifest = try Manifest.read(from: world.layout.manifestURL)
    manifest.folders = [ours.path]
    try manifest.write(to: world.layout.manifestURL)

    _ = try world.uninstaller().uninstall(deleteData: false)

    #expect(!world.exists(ours), "the recorded folder is removed with its contents")
    #expect(world.exists(theirs), "a folder that is not recorded stays")
  }

  @Test func test_deleteData_withPendingMail_refusesAndChangesNothing() throws {
    let world = try World(pending: [3])
    let callsBefore = world.launchd.calls

    #expect(
      throws: UninstallError.pendingMail(count: 3, storeFolder: world.layout.storeFolder.path)
    ) {
      _ = try world.uninstaller().uninstall(deleteData: true)
    }

    #expect(world.exists(world.layout.databaseURL), "the database is untouched")
    #expect(world.exists(world.layout.serviceBinary), "the programs are untouched")
    #expect(world.exists(world.layout.manifestURL), "the manifest is untouched")
    #expect(world.launchd.calls == callsBefore, "the service was not stopped")
  }

  @Test func test_deleteData_withNoPendingMail_removesTheStoreToo() throws {
    let world = try World(pending: [0])

    let report = try world.uninstaller().uninstall(deleteData: true)

    #expect(report.storeDeleted, "the report says the store went")
    #expect(!world.exists(world.layout.storeFolder), "the store folder is gone")
    #expect(!world.exists(world.layout.supportFolder), "nothing is left of the install folder")
  }

  @Test func test_deleteData_mailThatArrivesWhileTheServiceStops_keepsTheStore() throws {
    let world = try World(pending: [0, 2])

    #expect(
      throws: UninstallError.pendingMail(count: 2, storeFolder: world.layout.storeFolder.path)
    ) {
      _ = try world.uninstaller().uninstall(deleteData: true)
    }

    #expect(world.exists(world.layout.databaseURL), "late mail is not deleted")
    #expect(world.exists(world.layout.serviceBinary), "nothing is removed after the late count")
  }

  @Test func test_uninstall_asRoot_isRefused() throws {
    let world = try World()

    #expect(throws: UninstallError.refusedAsRoot) {
      _ = try world.uninstaller(userID: 0).uninstall(deleteData: false)
    }

    #expect(world.exists(world.layout.manifestURL), "nothing was removed")
  }

  @Test func test_uninstall_withoutAnInstall_saysSo() throws {
    let home = try TemporaryHome()
    let uninstaller = Uninstaller(
      layout: HostLayout(home: home.url), userID: 501, launchd: RecordingLaunchd(),
      pendingMail: ScriptedPendingCount([0]))

    #expect(throws: UninstallError.notInstalled) {
      _ = try uninstaller.uninstall(deleteData: false)
    }
  }

  @Test func test_aManifestThatPointsOutsideTheHome_isRefusedBeforeAnythingIsRemoved() throws {
    let world = try World()
    let outsider = try TemporaryHome()
    let victim = outsider.url.appendingPathComponent("precious.txt")
    try world.plant(victim)
    var manifest = try Manifest.read(from: world.layout.manifestURL)
    manifest.files.append(victim.path)
    try manifest.write(to: world.layout.manifestURL)

    #expect(throws: UninstallError.unsafeManifest(victim.path)) {
      _ = try world.uninstaller().uninstall(deleteData: false)
    }

    #expect(world.exists(victim), "a file outside the home is not removed")
    #expect(world.exists(world.layout.serviceBinary), "nor is anything else")
  }

  @Test func test_aManifestEntryTheInstallNeverWrites_isRefusedAndNothingIsRemoved() throws {
    for kind in ["file", "folder", "store"] {
      let world = try World()
      let documents = world.home.url.appendingPathComponent("Documents", isDirectory: true)
      let note = documents.appendingPathComponent("note.txt")
      try world.plant(note)
      var manifest = try Manifest.read(from: world.layout.manifestURL)
      switch kind {
      case "file": manifest.files.append(note.path)
      case "folder": manifest.folders.append(documents.path)
      default: manifest.storeFolder = documents.path
      }
      try manifest.write(to: world.layout.manifestURL)

      #expect(throws: UninstallError.self, "a stray \(kind) entry is refused") {
        _ = try world.uninstaller().uninstall(deleteData: true)
      }

      #expect(world.exists(note), "\(kind): the user's file is untouched")
      #expect(world.exists(world.layout.serviceBinary), "\(kind): nothing else was removed")
    }
  }

  @Test func test_aManifestEntryThatIsASymbolicLink_isRefused() throws {
    let world = try World()
    let victim = world.home.url.appendingPathComponent("victim.txt")
    try world.plant(victim)
    try FileManager.default.removeItem(at: world.layout.serviceBinary)
    try FileManager.default.createSymbolicLink(
      at: world.layout.serviceBinary, withDestinationURL: victim)

    #expect(throws: UninstallError.self) {
      _ = try world.uninstaller().uninstall(deleteData: false)
    }

    #expect(world.exists(victim), "the link target is untouched")
    #expect(world.exists(world.layout.clientBinary), "nothing was removed")
  }

  @Test func test_deleteData_whenTheStoreIsAlreadyGone_stillFinishes() throws {
    let world = try World()
    try FileManager.default.removeItem(at: world.layout.storeFolder)

    let report = try world.uninstaller().uninstall(deleteData: true)

    #expect(report.storeDeleted, "nothing was left to delete, and that is fine")
    #expect(!world.exists(world.layout.manifestURL), "the manifest is gone too")
  }

  @Test func test_everyUninstallError_readsAsASentence() {
    let described: [(UninstallError, String)] = [
      (.refusedAsRoot, "root"),
      (.notInstalled, "not installed"),
      (.pendingMail(count: 4, storeFolder: "/s"), "4"),
      (.unsafeManifest("/etc/x"), "/etc/x"),
      (.launchd("bootout failed"), "bootout failed"),
      (.filesystem("busy"), "busy"),
    ]
    for (error, fragment) in described {
      #expect("\(error)".contains(fragment), "\(error) mentions \(fragment)")
      #expect(!"\(error)".contains("UninstallError"), "\(error) is not a case name")
    }
  }
}

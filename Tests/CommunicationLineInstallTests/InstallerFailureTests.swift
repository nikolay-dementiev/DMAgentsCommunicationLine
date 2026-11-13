import CommunicationLineInstall
import CommunicationLineWire
import Foundation
import Testing

/// What an install leaves behind when it fails half way, and what an upgrade keeps.
struct InstallerFailureTests {
  private struct World {
    let home: TemporaryHome
    let executables: TemporaryHome
    let layout: HostLayout
    let launchd = RecordingLaunchd()

    init() throws {
      home = try TemporaryHome()
      executables = try TemporaryHome()
      layout = HostLayout(home: home.url)
      for name in ["commline", "commline-service"] {
        FileManager.default.createFile(
          atPath: executables.url.appendingPathComponent(name).path,
          contents: Data("binary \(name)".utf8))
      }
    }

    var installer: Installer {
      let service = FakeOwnerService()
      return Installer(
        layout: layout, executableFolder: executables.url, userID: 501, launchd: launchd,
        readiness: AlwaysReady(), connect: { _ in service })
    }

    var uninstaller: Uninstaller {
      Uninstaller(
        layout: layout, userID: 501, launchd: launchd, pendingMail: ScriptedPendingCount([0]))
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    func makeUnreadable(_ url: URL) throws {
      try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    }

    func addBundle(settings: String = "{}", extraFile: String? = nil) throws -> URL {
      let bundle = executables.url.appendingPathComponent(
        "CommunicationLine_CommunicationLineStore.bundle", isDirectory: true)
      let resources = bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
      try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
      try Data(settings.utf8).write(to: resources.appendingPathComponent("settings-defaults.json"))
      if let extraFile {
        let url = resources.appendingPathComponent(extraFile)
        try Data("x".utf8).write(to: url)
        try makeUnreadable(url)
      }
      return bundle
    }
  }

  @Test func test_aFailedFirstInstall_leavesAManifestSoUninstallRemovesWhatWasCopied() throws {
    let world = try World()
    try world.makeUnreadable(world.executables.url.appendingPathComponent("commline-service"))

    #expect(throws: InstallError.self, "the second program cannot be read") {
      _ = try world.installer.install()
    }

    #expect(world.exists(world.layout.clientBinary), "the first program was already copied")
    #expect(world.exists(world.layout.manifestURL), "so the manifest already names it")
    _ = try world.uninstaller.uninstall(deleteData: false)
    #expect(!world.exists(world.layout.clientBinary), "uninstall removes the copied program")
  }

  @Test func test_aFailedUpgrade_keepsTheInstalledResourceBundleWorking() throws {
    let world = try World()
    let bundle = try world.addBundle()
    _ = try world.installer.install()
    let installed = world.layout.binFolder.appendingPathComponent(bundle.lastPathComponent)
    let defaults = installed.appendingPathComponent("Contents/Resources/settings-defaults.json")

    _ = try world.addBundle(settings: "{\"new\":1}", extraFile: "locked.json")
    #expect(throws: InstallError.self, "the new bundle cannot be copied whole") {
      _ = try world.installer.install()
    }

    #expect(
      try String(contentsOf: defaults, encoding: .utf8) == "{}",
      "the installed bundle is the old one, complete")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: world.layout.binFolder.path)
      .filter { $0.hasSuffix(".new") }
    #expect(leftovers.isEmpty, "no staged copy is left behind: \(leftovers)")
  }

  @Test func test_anUnreadableOrCorruptManifest_stopsTheInstallAndIsLeftAlone() throws {
    for damage in ["corrupt", "unreadable"] {
      let world = try World()
      _ = try world.installer.install()
      let command = world.layout.claudeCommandsFolder.appendingPathComponent("commline-lead.md")
      var manifest = try Manifest.read(from: world.layout.manifestURL)
      manifest.files.append(command.path)
      try manifest.write(to: world.layout.manifestURL)
      if damage == "corrupt" {
        try Data("not json".utf8).write(to: world.layout.manifestURL)
      } else {
        try world.makeUnreadable(world.layout.manifestURL)
      }

      #expect(throws: InstallError.self, "\(damage): a manifest that cannot be read is an error") {
        _ = try world.installer.install()
      }

      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: world.layout.manifestURL.path)
      let kept = try String(contentsOf: world.layout.manifestURL, encoding: .utf8)
      #expect(
        damage == "corrupt" ? kept == "not json" : kept.contains(command.path),
        "\(damage): the manifest was not rewritten without the command entry")
    }
  }
}

import CommunicationLineInstall
import Foundation
import Testing

struct InstallEndToEndTests {
  @Test func test_installAddWaitReadAcknowledgeUpgradeUninstallInstall() throws {
    let world = try InstalledWorld()

    // 1. Install: programs, store, owner token.
    let first = try world.install()
    #expect(!first.upgraded, "a first install")
    #expect(first.ownerTokenIssued, "the owner credential is issued once")
    let bundled = FileManager.default.enumerator(atPath: world.layout.binFolder.path)?
      .compactMap { $0 as? String }.contains { $0.hasSuffix("settings-defaults.json") }
    #expect(bundled == true, "the installed service has its defaults next to it")
    let ownerToken = try String(contentsOf: world.layout.ownerTokenURL, encoding: .utf8)

    // 2. Two agents of one family.
    let alice = try world.addAgent(family: "ops", name: "alice")
    let bob = try world.addAgent(family: "ops", name: "bob")

    // 3. Bob's waiter parks; Alice sends; it wakes.
    let waiter = try world.spawn(["wait", "--until-mail"], tokenFile: bob.tokenFile)
    Thread.sleep(forTimeInterval: 0.7)
    #expect(waiter.isRunning, "the waiter is parked")
    let sent = try world.run(
      ["send", "--to", bob.principalID, "--subject", "hello", "--body", "text"],
      tokenFile: alice.tokenFile)
    #expect(sent.status == 0, "send: \(sent.err)")
    #expect(waiter.waitForExit(seconds: 10) == 0, "the waiter woke")
    #expect(waiter.standardOutput == "mail\n", "and said why")

    // 4. Read and acknowledge.
    let inbox = try world.inboxIDs(tokenFile: bob.tokenFile)
    #expect(inbox == [sent.out], "bob has the one message")
    let read = try world.run(["read", sent.out], tokenFile: bob.tokenFile)
    #expect(read.out.contains("Subject: hello"), "the subject")
    #expect(try world.run(["acknowledge", sent.out], tokenFile: bob.tokenFile).status == 0, "ack")
    #expect(try world.inboxIDs(tokenFile: bob.tokenFile).isEmpty, "the inbox is empty again")

    // 5. A message stays pending across an upgrade.
    let pending = try world.run(
      ["send", "--to", bob.principalID, "--subject", "later", "--body", "text"],
      tokenFile: alice.tokenFile)
    let upgrade = try world.install()
    #expect(upgrade.upgraded, "the second install is an upgrade")
    #expect(!upgrade.ownerTokenIssued, "no second owner credential")
    #expect(
      try world.inboxIDs(tokenFile: bob.tokenFile) == [pending.out], "pending mail survived")
    #expect(
      throws: UninstallError.pendingMail(count: 1, storeFolder: world.layout.storeFolder.path)
    ) {
      _ = try world.uninstall(deleteData: true)
    }
    #expect(
      FileManager.default.fileExists(atPath: world.layout.databaseURL.path),
      "deleting the data was refused and the database is there")

    // 6. Uninstall leaves the store, and nothing else.
    let removed = try world.uninstall(deleteData: false)
    #expect(!removed.storeDeleted, "the data was kept")
    #expect(world.filesOutsideTheStore().isEmpty, "\(world.filesOutsideTheStore())")
    #expect(
      !FileManager.default.fileExists(atPath: world.layout.binFolder.path), "no programs left")

    // 7. Install on the kept store: the old owner token still works.
    let again = try world.install()
    #expect(!again.ownerTokenIssued, "the kept owner credential is reused")
    #expect(
      try String(contentsOf: world.layout.ownerTokenURL, encoding: .utf8) == ownerToken,
      "the token file is the same")
    let rules = try world.run(["rule", "list"], tokenFile: world.layout.ownerTokenURL.path)
    #expect(rules.status == 0, "the old owner token works: \(rules.err)")
    #expect(
      try world.inboxIDs(tokenFile: bob.tokenFile) == [pending.out], "and the mail is still there")
  }

  @Test func test_aCleanInstallAndUninstallWithData_leavesNoFileInTheHome() throws {
    let world = try InstalledWorld()
    _ = try world.install()
    _ = try world.addAgent(family: "ops", name: "alice")

    let removed = try world.uninstall(deleteData: true)

    #expect(removed.storeDeleted, "the store went with it")
    #expect(world.filesOutsideTheStore().isEmpty, "\(world.filesOutsideTheStore())")
    #expect(
      !FileManager.default.fileExists(atPath: world.layout.supportFolder.path),
      "no install folder is left")
    #expect(world.launchd.calls.last == "bootout", "the service was stopped")
  }

  @Test func test_aLostOwnerToken_isRecoveredWithoutLosingMail_andTheOldTokenStopsWorking() throws {
    let world = try InstalledWorld()
    _ = try world.install()
    let alice = try world.addAgent(family: "ops", name: "alice")
    let bob = try world.addAgent(family: "ops", name: "bob")
    let sent = try world.run(
      ["send", "--to", bob.principalID, "--subject", "keep", "--body", "text"],
      tokenFile: alice.tokenFile)
    let oldToken = try String(contentsOf: world.layout.ownerTokenURL, encoding: .utf8)
    try FileManager.default.removeItem(at: world.layout.ownerTokenURL)

    let report = try world.recoverOwner()

    #expect(report.ownerTokenPath == world.layout.ownerTokenURL.path, "the new file is reported")
    let fresh = try world.run(["rule", "list"], tokenFile: world.layout.ownerTokenURL.path)
    #expect(fresh.status == 0, "the new owner token works: \(fresh.err)")
    let oldFile = world.home.url.appendingPathComponent("old.token").path
    FileManager.default.createFile(
      atPath: oldFile, contents: Data(oldToken.utf8), attributes: [.posixPermissions: 0o600])
    #expect(
      try world.run(["rule", "list"], tokenFile: oldFile).status != 0,
      "the old owner token no longer works")
    #expect(try world.inboxIDs(tokenFile: bob.tokenFile) == [sent.out], "pending mail survived")
  }

  @Test func test_aRegistrationThatNeverStartsTheService_failsTheInstallAndDoesNotHang() throws {
    let world = try InstalledWorld(startsService: false, readinessSeconds: 1)
    let started = Date()

    var failure: InstallError?
    do {
      _ = try world.install()
    } catch let error as InstallError {
      failure = error
    }

    guard case .serviceNotReady? = failure else {
      Issue.record("expected the service-not-ready error, got \(String(describing: failure))")
      return
    }
    #expect(Date().timeIntervalSince(started) < 10, "the wait is bounded")
    #expect(
      !FileManager.default.fileExists(atPath: world.layout.ownerTokenURL.path),
      "no owner token for a service that never started")
  }
}

import Foundation
import Testing

struct EndToEndTests {
  @Test func test_twoFamilies_sendInboxReadAcknowledge_throughSeparateProcesses() throws {
    let world = try EndToEndWorld()
    let alice = try world.enrol(family: "A", name: "alice")
    let bob = try world.enrol(family: "A", name: "bob")
    let carol = try world.enrol(family: "B", name: "carol")

    let refused = try world.run(
      ["send", "--to", carol.id, "--subject", "s", "--body", "b"], token: alice.token)
    #expect(refused.status == 5, "no rule yet: permission, not success (\(refused.err))")
    try world.require(world.asOwner(["rule", "add", "A", "B"]), "rule add")
    let toCarol = try world.send(from: alice, to: carol, subject: "across")
    let back = try world.run(
      ["send", "--to", alice.id, "--subject", "s", "--body", "b"], token: carol.token)
    #expect(back.status == 5, "the rule opens one direction only")

    let hello = try world.send(from: alice, to: bob, subject: "hello")
    #expect(try world.inboxIDs(of: bob) == [hello], "bob has the one message")
    #expect(try world.inboxIDs(of: carol) == [toCarol], "carol has hers")
    let read = try world.run(["read", hello], token: bob.token)
    #expect(read.out.contains("Subject: hello"), "subject")
    #expect(read.out.hasSuffix("body of hello"), "body")
    let stranger = try world.run(["read", hello], token: carol.token)
    #expect(stranger.status == 6, "another pair's message is not found (\(stranger.err))")

    #expect(try world.run(["acknowledge", hello], token: bob.token).status == 0, "acknowledge")
    #expect(try world.inboxIDs(of: bob) == [], "an acknowledged message leaves the inbox")
  }

  @Test func test_wait_wakesWhenAnotherProcessSends_andTimesOutOtherwise() throws {
    let world = try EndToEndWorld()
    let alice = try world.enrol(family: "A", name: "alice")
    let bob = try world.enrol(family: "A", name: "bob")

    let quiet = try world.run(["wait", "--timeout", "1"], token: bob.token)
    #expect(quiet.status == 9, "no mail: timed out, status 9 (\(quiet.err))")

    let waiter = try world.spawn(["wait", "--timeout", "25"], token: bob.token)
    Thread.sleep(forTimeInterval: 0.7)
    #expect(waiter.isRunning, "the waiter is parked")
    _ = try world.send(from: alice, to: bob, subject: "wake up")

    #expect(waiter.waitForExit(seconds: 8) == 0, "it woke long before its 25 s timeout")
    #expect(waiter.standardOutput == "mail\n", "and said why")
  }

  @Test func test_manyProcessesSendAtOnce_andFourWaitAtOnce() throws {
    let world = try EndToEndWorld()
    let target = try world.enrol(family: "A", name: "target")
    let senders = try (1...8).map { try world.enrol(family: "A", name: "sender\($0)") }
    let waiters = try (1...4).map { try world.enrol(family: "A", name: "waiter\($0)") }
    let poster = try world.enrol(family: "A", name: "poster")

    let parked = try waiters.map { try world.spawn(["wait", "--timeout", "6"], token: $0.token) }
    Thread.sleep(forTimeInterval: 1)
    _ = try world.send(from: poster, to: waiters[0], subject: "for waiter 1")
    _ = try world.send(from: poster, to: waiters[2], subject: "for waiter 3")

    #expect(parked[0].waitForExit(seconds: 4) == 0, "waiter 1 woke for its own mail")
    #expect(parked[2].waitForExit(seconds: 4) == 0, "waiter 3 woke for its own mail")
    #expect(parked[1].isRunning && parked[3].isRunning, "the others are still parked")

    let sends = try senders.enumerated().map { index, sender in
      try world.spawn(
        ["send", "--to", target.id, "--subject", "burst-\(index)", "--body", "b"],
        token: sender.token)
    }
    for (index, send) in sends.enumerated() {
      #expect(send.waitForExit(seconds: 30) == 0, "send \(index) succeeded: \(send.standardError)")
    }
    #expect(parked[1].waitForExit(seconds: 12) == 9, "waiter 2 timed out: nothing was for it")
    #expect(parked[3].waitForExit(seconds: 12) == 9, "waiter 4 timed out: nothing was for it")

    let ids = try world.inboxIDs(of: target)
    #expect(ids.count == 8, "all eight messages arrived, none lost")
    #expect(Set(ids).count == 8, "and none twice")
    let page = try world.run(["inbox"], token: target.token).out
    for index in 0..<8 {
      #expect(page.contains("burst-\(index)"), "the message of sender \(index) is there")
    }
  }

  @Test func test_afterARestart_pendingMailAndTokensSurvive() throws {
    let world = try EndToEndWorld()
    let alice = try world.enrol(family: "A", name: "alice")
    let bob = try world.enrol(family: "A", name: "bob")
    let sent = try (1...3).map { try world.send(from: alice, to: bob, subject: "keep-\($0)") }

    #expect(world.stopService() == 0, "SIGTERM is a clean stop")
    #expect(!FileManager.default.fileExists(atPath: world.socketPath), "the socket is gone")
    let down = try world.run(["inbox"], token: bob.token)
    #expect(down.status == 3, "with no service the command says so (\(down.err))")
    try world.startService()

    #expect(try world.inboxIDs(of: bob) == sent, "the same mail, in order, with the same token")
  }

  @Test func test_aSecondServiceOnTheSameStore_exitsAtOnce_andTheFirstKeepsServing() throws {
    let world = try EndToEndWorld()
    let alice = try world.enrol(family: "A", name: "alice")

    let second = try world.startSecondInstance()

    #expect(second.waitForExit(seconds: 10) == 3, "it refused to start: \(second.standardError)")
    #expect(second.standardError.contains("already running"), "and said why")
    #expect(try world.inboxIDs(of: alice) == [], "the first instance still answers")
  }

  @Test func test_aTokenNeverAppearsInTheCommandLineOrTheEnvironmentOfAProcess() throws {
    let world = try EndToEndWorld()
    let bob = try world.enrol(family: "A", name: "bob")
    let parked = try world.spawn(["wait", "--timeout", "5"], token: bob.token)
    Thread.sleep(forTimeInterval: 0.5)

    let listing = try Child(
      URL(fileURLWithPath: "/bin/ps"), ["-wwE", "-o", "command=", "-p", String(parked.identifier)])
    #expect(listing.waitForExit(seconds: 5) == 0, "ps ran")

    #expect(parked.isRunning, "the process was alive when it was inspected")
    #expect(!listing.standardOutput.isEmpty, "ps listed the process")
    #expect(
      !listing.standardOutput.contains(bob.token),
      "the token is in neither the arguments nor the environment")
    parked.terminate()
  }

  @Test func test_unsafeTokenInput_isRefusedByTheRealProcess() throws {
    let world = try EndToEndWorld()
    let bob = try world.enrol(family: "A", name: "bob")
    let loose = world.tokenFile(holding: bob.token)
    chmod(loose, 0o644)

    let open = try world.run(["--token-file", loose, "inbox"])
    let argument = try world.run(["--token", bob.token, "inbox"])
    let piped = try Child(
      try builtExecutable("commline"), ["--store", world.store.path, "inbox"],
      input: bob.token + "\n")

    #expect(open.status == 10, "a 0644 token file is refused: \(open.err)")
    #expect(argument.status == 2, "a token argument is refused: \(argument.err)")
    #expect(!argument.err.contains(bob.token), "and never echoed")
    #expect(piped.waitForExit(seconds: 20) == 0, "a token on standard input works")
  }
}

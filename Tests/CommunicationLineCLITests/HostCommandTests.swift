import CommunicationLineCLI
import CommunicationLineInstall
import Foundation
import Testing

struct HostCommandTests {
  private struct Refused: Error, CustomStringConvertible {
    var description: String { "refused for a reason" }
  }

  @Test func test_install_runsTheInstallerAndPrintsWhatItReports() {
    let harness = CLIHarness(
      host: FakeHost(result: .success(["installed", "owner token file: /p"])))

    let status = harness.run(["install"])

    #expect(status == 0, "a finished install exits 0")
    #expect(harness.host.installs == [nil], "no --home means the caller's own home")
    #expect(
      harness.standardOutput == "installed\nowner token file: /p\n", "the report, line by line")
    #expect(harness.connectedSockets.isEmpty, "install needs no running service to reach")
  }

  @Test func test_install_passesTheGivenHome() {
    let harness = CLIHarness()

    _ = harness.run(["install", "--home", "/tmp/elsewhere"])

    #expect(harness.host.installs == ["/tmp/elsewhere"], "the home folder as given")
  }

  @Test func test_aFailedInstall_exitsNonZeroAndSaysWhy() {
    let harness = CLIHarness(host: FakeHost(result: .failure(Refused())))

    let status = harness.run(["install"])

    #expect(status == CommandExitStatus.failure.rawValue, "a failed install is a failure")
    #expect(harness.standardOutput.isEmpty, "nothing is printed as a result")
    #expect(harness.standardError.contains("refused for a reason"), "the reason is on stderr")
  }

  @Test func test_install_takesNoPositionalsAndNoTokenOptions() {
    for arguments in [
      ["install", "extra"], ["install", "--token-file", "/x"], ["install", "--store", "/s"],
    ] {
      let harness = CLIHarness()

      let status = harness.run(arguments)

      #expect(
        status == CommandExitStatus.usage.rawValue, "\(arguments) is a usage error")
      #expect(harness.host.installs.isEmpty, "\(arguments) installed nothing")
    }
  }

  // MARK: - owner recover

  @Test func test_ownerRecover_runsTheRecoveryOnTheHostWithoutAnyToken() {
    let harness = CLIHarness(host: FakeHost(result: .success(["owner token file: /p"])))

    let status = harness.run(["owner", "recover", "--home", "/tmp/elsewhere"])

    #expect(status == 0, "a finished recovery exits 0")
    #expect(harness.host.recoveries == ["/tmp/elsewhere"], "the home folder as given")
    #expect(harness.standardOutput == "owner token file: /p\n", "the path, never the token")
    #expect(harness.connectedSockets.isEmpty, "the service is not asked: it is stopped meanwhile")
  }

  @Test func test_ownerRecover_takesNoTokenAndNoStoreOption() {
    for arguments in [
      ["owner", "recover", "--token-file", "/x"], ["owner", "recover", "--store", "/s"],
      ["owner", "recover", "extra"],
    ] {
      let harness = CLIHarness()

      let status = harness.run(arguments)

      #expect(status == CommandExitStatus.usage.rawValue, "\(arguments) is a usage error")
      #expect(harness.host.recoveries.isEmpty, "\(arguments) recovered nothing")
    }
  }

  // MARK: - uninstall

  @Test func test_uninstall_runsTheUninstallerAndPrintsWhatItReports() {
    let harness = CLIHarness(host: FakeHost(result: .success(["uninstalled", "store kept: /s"])))

    let status = harness.run(["uninstall"])

    #expect(status == 0, "a finished uninstall exits 0")
    #expect(
      harness.host.uninstalls == [FakeHost.UninstallCall(home: nil, deleteData: false)],
      "the caller's own home, and the data is kept")
    #expect(harness.standardOutput == "uninstalled\nstore kept: /s\n", "the report, line by line")
    #expect(harness.connectedSockets.isEmpty, "uninstall does not ask the service for anything")
  }

  @Test func test_uninstall_passesTheHomeAndTheDeleteDataFlag() {
    let harness = CLIHarness()

    _ = harness.run(["uninstall", "--home", "/tmp/elsewhere", "--delete-data"])

    #expect(
      harness.host.uninstalls == [FakeHost.UninstallCall(home: "/tmp/elsewhere", deleteData: true)],
      "the home folder as given, and the explicit request to delete the data")
  }

  @Test func test_aRefusedUninstall_exitsNonZeroAndSaysWhy() {
    let harness = CLIHarness(host: FakeHost(result: .failure(Refused())))

    let status = harness.run(["uninstall", "--delete-data"])

    #expect(status == CommandExitStatus.failure.rawValue, "a refusal is a failure")
    #expect(harness.standardOutput.isEmpty, "nothing is printed as a result")
    #expect(harness.standardError.contains("refused for a reason"), "the reason is on stderr")
  }

  @Test func test_uninstall_takesNoPositionalsAndNoTokenOptions() {
    for arguments in [
      ["uninstall", "extra"], ["uninstall", "--token-file", "/x"], ["uninstall", "--store", "/s"],
    ] {
      let harness = CLIHarness()

      let status = harness.run(arguments)

      #expect(status == CommandExitStatus.usage.rawValue, "\(arguments) is a usage error")
      #expect(harness.host.uninstalls.isEmpty, "\(arguments) uninstalled nothing")
    }
  }

  // MARK: - agent add

  private func addAgent(
    _ extra: [String], file: TokenFileFixture = TokenFileFixture(), host: FakeHost = FakeHost()
  ) -> (status: Int32, harness: CLIHarness) {
    defer { file.remove() }
    let harness = CLIHarness(host: host)
    let status = harness.run(
      ["--store", "/tmp/cl-store", "--token-file", file.path, "agent", "add"] + extra)
    return (status, harness)
  }

  @Test func test_agentAdd_refusesNamesWithControlCharactersOrBackticks() {
    for bad in ["al\nice", "al`ice", "al\u{1b}ice"] {
      for field in ["--name", "--family"] {
        var arguments = ["--family", "ops", "--role", "agent", "--name", "alice"]
        if let position = arguments.firstIndex(of: field) { arguments[position + 1] = bad }
        let outcome = addAgent(arguments)

        #expect(
          outcome.status == CommandExitStatus.usage.rawValue, "\(field) \(bad.debugDescription)")
        #expect(outcome.harness.host.agents.isEmpty, "nothing was created")
      }
    }
  }

  @Test func test_agentAdd_handsTheOwnerTokenAndTheRequestToTheHost() {
    let outcome = addAgent(["--family", "ops", "--role", "agent", "--name", "alice"])

    #expect(outcome.status == 0, "the agent is added")
    #expect(
      outcome.harness.host.agents == [
        FakeHost.AgentCall(
          store: "/tmp/cl-store", home: nil, ownerToken: "tok-0123456789",
          request: AgentRequest(family: "ops", role: "agent", name: "alice", client: nil))
      ], "the store, the owner token read from the file, and what was asked for")
    #expect(outcome.harness.standardOutput == "installed\n", "the host's lines are printed")
  }

  @Test func test_agentAdd_withAClientAndAHome() {
    let outcome = addAgent([
      "--family", "ops", "--role", "head", "--name", "lead", "--client", "claude-code",
      "--home", "/tmp/h",
    ])

    #expect(outcome.harness.host.agents.first?.request.client == .claudeCode, "the client")
    #expect(outcome.harness.host.agents.first?.home == "/tmp/h", "the home folder")
  }

  @Test func test_agentAdd_badArguments_areUsageErrors_andAddNothing() {
    let bad: [[String]] = [
      ["--role", "agent", "--name", "a"],
      ["--family", "f", "--name", "a"],
      ["--family", "f", "--role", "agent"],
      ["--family", "f", "--role", "boss", "--name", "a"],
      ["--family", "f", "--role", "agent", "--name", "a", "--client", "vim"],
    ]
    for arguments in bad {
      let outcome = addAgent(arguments)

      #expect(
        outcome.status == CommandExitStatus.usage.rawValue, "\(arguments) is a usage error")
      #expect(outcome.harness.host.agents.isEmpty, "\(arguments) added nothing")
    }
  }

  @Test func test_agentAdd_needsTheStoreFolder_notJustASocket() {
    let file = TokenFileFixture()
    defer { file.remove() }
    let harness = CLIHarness()

    let status = harness.run([
      "--socket", "/tmp/x.sock", "--token-file", file.path, "agent", "add", "--family", "f",
      "--role", "agent", "--name", "a",
    ])

    #expect(status == CommandExitStatus.usage.rawValue, "the agent files go inside the store")
    #expect(harness.host.agents.isEmpty, "nothing was added")
  }

  @Test func test_agentAdd_aFailure_exitsNonZero_andSaysWhy() {
    let outcome = addAgent(
      ["--family", "f", "--role", "agent", "--name", "a"],
      host: FakeHost(result: .failure(Refused())))

    #expect(outcome.status == CommandExitStatus.failure.rawValue, "failure")
    #expect(outcome.harness.standardError.contains("refused for a reason"), "the reason")
    #expect(outcome.harness.standardOutput.isEmpty, "no result lines")
  }
}

import CommunicationLineCLI
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
}

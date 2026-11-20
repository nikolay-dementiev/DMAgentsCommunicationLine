import CommunicationLineCLI
import CommunicationLineWire
import Darwin
import Foundation
import Testing

/// `observer issue` hands out the read-only token the way every credential command does: to a
/// private file, never to the terminal. `observer revoke` takes it back.
struct ObserverCommandTests {
  private static let secret = "the-observer-token-0123456789"
  private let store = ["--store", "/tmp/cl-store"]

  private func freshPath() -> String {
    "/tmp/clob-" + UUID().uuidString.prefix(8).lowercased()
  }

  private func run(_ arguments: [String], answer: WireValue? = nil) -> (
    status: Int32, harness: CLIHarness
  ) {
    let reply = answer ?? .object(["token": .string(Self.secret)])
    let harness = CLIHarness(stdin: "tok-0123456789\n", answer: { _ in .success(reply) })
    return (harness.run(store + arguments), harness)
  }

  @Test func test_observerIssue_sendsObserverIssue_andWritesThePrivateTokenFile() throws {
    let target = freshPath()
    defer { unlink(target) }

    let outcome = run(["observer", "issue", "--token-out", target])

    #expect(outcome.status == 0, "it succeeds: \(outcome.harness.standardError)")
    #expect(
      outcome.harness.connection.requests.map(\.operation) == ["observer.issue"],
      "one observer.issue request")
    #expect(
      try String(contentsOfFile: target, encoding: .utf8) == Self.secret + "\n",
      "the file holds the token")
    var info = stat()
    #expect(stat(target, &info) == 0, "the file can be inspected")
    #expect(info.st_mode & 0o777 == 0o600, "only the owner can read it")
    #expect(outcome.harness.standardOutput == "token file: \(target)\n", "the path only")
  }

  @Test func test_observerIssue_withoutTokenOut_isAUsageError_andSendsNothing() {
    let outcome = run(["observer", "issue"])

    #expect(outcome.status == CommandExitStatus.usage.rawValue, "a usage error")
    #expect(outcome.harness.connection.requests.isEmpty, "nothing is sent")
    #expect(outcome.harness.standardError.contains("--token-out"), "it names the option")
    #expect(!outcome.harness.standardOutput.contains(Self.secret), "no token is printed")
  }

  @Test func test_observerRevoke_sendsObserverRevoke_withNoArguments() {
    let outcome = run(["observer", "revoke"], answer: .object(["outcome": .string("ok")]))

    #expect(outcome.status == 0, "it succeeds: \(outcome.harness.standardError)")
    #expect(
      outcome.harness.connection.requests.map(\.operation) == ["observer.revoke"],
      "one observer.revoke request")
    #expect(outcome.harness.connection.requests.first?.arguments.isEmpty == true, "no arguments")
  }

  @Test func test_observerCommands_rejectAnythingElse() {
    for arguments in [["observer"], ["observer", "list"], ["observer", "revoke", "extra"]] {
      let outcome = run(arguments)

      #expect(
        outcome.status == CommandExitStatus.usage.rawValue, "\(arguments) is a usage error")
      #expect(outcome.harness.connection.requests.isEmpty, "\(arguments) sends nothing")
    }
  }
}

import CommunicationLineCLI
import CommunicationLineWire
import Foundation
import Testing

/// With no service listening, `health --json` answers at once and says so as a document, because
/// a dashboard calls it in a loop and must not wait on, or parse, a human sentence.
struct HealthUnreachableTests {
  private func run(_ arguments: [String]) -> (status: Int32, harness: CLIHarness) {
    let harness = CLIHarness(
      stdin: "tok-0123456789\n",
      answer: { _ in throw ServiceConnectionError.unreachable("no socket") })
    return (harness.run(["--store", "/tmp/cl-store"] + arguments), harness)
  }

  @Test func test_healthJSON_withNoService_failsAtOnceWithAnErrorDocument() throws {
    let outcome = run(["health", "--json"])
    let body = try JSONDecoder().decode(
      WireValue.self, from: Data(outcome.harness.standardError.utf8))

    #expect(outcome.status == CommandExitStatus.unreachable.rawValue, "exit status 3")
    #expect(outcome.harness.connectedSockets.count == 1, "one attempt, no retry")
    #expect(outcome.harness.pauses.isEmpty, "no pause between attempts: it returns at once")
    #expect(outcome.harness.standardOutput.isEmpty, "nothing on standard output")
    guard case .object(let fields) = body, case .object(let error)? = fields["error"] else {
      Issue.record("standard error is a document with an error object: \(body)")
      return
    }
    #expect(error["code"] == .string("service_unreachable"), "the code names the case")
    guard case .string(let message)? = error["message"] else {
      Issue.record("the error has a message")
      return
    }
    #expect(message.contains("no socket"), "the reason is in the message")
  }

  @Test func test_health_withoutJSON_keepsThePlainSentence() {
    let outcome = run(["health"])

    #expect(outcome.status == CommandExitStatus.unreachable.rawValue, "exit status 3")
    #expect(
      outcome.harness.standardError.hasPrefix("commline: the service is not reachable"),
      "a person still reads a sentence")
  }
}

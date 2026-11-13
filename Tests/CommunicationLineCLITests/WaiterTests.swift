import CommunicationLineCLI
import CommunicationLineWire
import Foundation
import Testing

struct WaiterTests {
  private typealias Step = Result<WireResponse, any Error>

  private static let mail = Step.success(.success(.object(["outcome": .string("mail")])))
  private static let timeout = Step.success(.success(.object(["outcome": .string("timeout")])))
  private static let down = Step.failure(ServiceConnectionError.unreachable("no socket"))
  private static let garbled = Step.failure(ServiceConnectionError.invalidResponse)

  /// Runs `commline wait --until-mail` against a service that answers from `script`, one step per
  /// request. Past the end of the script the test fails instead of looping forever.
  private func waiter(
    _ script: [Step], extra: [String] = [], missing: Set<String> = []
  ) -> (status: Int32, harness: CLIHarness, requests: () -> Int) {
    let file = TokenFileFixture()
    defer { file.remove() }
    let queue = ScriptQueue(script)
    let harness = CLIHarness(answer: { _ in try queue.next().get() })
    harness.missingFolders = missing
    let status = harness.run(
      ["--store", "/tmp/cl-store", "--token-file", file.path, "wait", "--until-mail"] + extra)
    return (status, harness, { queue.taken })
  }

  @Test func test_untilMail_exitsZeroPrintingMail_whenMailIsWaiting() {
    let outcome = waiter([Self.mail])

    #expect(outcome.status == 0, "mail ends the wait")
    #expect(outcome.harness.standardOutput == "mail\n", "and says so")
  }

  @Test func test_untilMail_doesNotStopAtTheEndOfATimeoutCycle() {
    let outcome = waiter([Self.timeout, Self.timeout, Self.timeout, Self.mail])

    #expect(outcome.status == 0, "it kept waiting until mail came")
    #expect(outcome.requests() == 4, "one wait request per cycle")
    #expect(outcome.harness.standardOutput == "mail\n", "no timeout line is printed on the way")
    #expect(
      outcome.harness.connection.requests.allSatisfy {
        $0.operation == "wait" && $0.arguments.isEmpty
      }, "every cycle uses the service's own wait time")
  }

  @Test func test_untilMail_aSocketPathThatIsTooLong_isFinalAndNotRetried() {
    let outcome = waiter([.failure(ServiceConnectionError.pathTooLong("/long")), Self.mail])

    #expect(outcome.status == CommandExitStatus.failure.rawValue, "it ends with an error")
    #expect(outcome.requests() == 1, "it asked once and did not try again")
    #expect(outcome.harness.pauses.isEmpty, "and did not pause to try again")
  }

  @Test func test_untilMail_survivesAServiceRestart() {
    let outcome = waiter([Self.timeout, Self.down, Self.garbled, Self.down, Self.mail])

    #expect(outcome.status == 0, "after the restart the waiter woke up with the mail")
    #expect(outcome.requests() == 5, "it reconnected for every attempt")
    #expect(outcome.harness.pauses.count == 3, "it paused before each reconnect")
    #expect(outcome.harness.pauses.allSatisfy { $0 > 0 }, "and never spun")
  }

  @Test func test_untilMail_aRefusedToken_endsItAtOnceWithTheAuthenticationStatus() {
    let refused = Step.success(.failure(code: .tokenRevoked, message: "the token was revoked"))

    let outcome = waiter([refused])

    #expect(outcome.status == CommandExitStatus.authentication.rawValue, "refused token")
    #expect(outcome.requests() == 1, "it does not retry a refusal")
    #expect(outcome.harness.standardError.contains("token_revoked"), "the reason is shown")
  }

  @Test func test_untilMail_whenTheStoreIsGone_saysNotInstalledInsteadOfWaitingForever() {
    let outcome = waiter([Self.down, Self.down, Self.down], missing: ["/tmp/cl-store"])

    #expect(outcome.status == CommandExitStatus.notInstalled.rawValue, "its own status")
    #expect(outcome.requests() == 1, "it looked once and gave up")
    #expect(outcome.harness.standardError.contains("/tmp/cl-store"), "it names the folder")
  }

  @Test func test_untilMail_takesNoTimeout() {
    let outcome = waiter([Self.mail], extra: ["--timeout", "5"])

    #expect(outcome.status == CommandExitStatus.usage.rawValue, "the waiter has no time limit")
    #expect(outcome.requests() == 0, "nothing was sent")
  }
}

/// Hands out scripted steps and counts them.
private final class ScriptQueue: @unchecked Sendable {
  private let lock = NSLock()
  private var steps: [Result<WireResponse, any Error>]
  private(set) var taken = 0

  init(_ steps: [Result<WireResponse, any Error>]) { self.steps = steps }

  func next() -> Result<WireResponse, any Error> {
    lock.withLock {
      taken += 1
      guard !steps.isEmpty else {
        return .success(.failure(code: .internal, message: "the script ran out"))
      }
      return steps.removeFirst()
    }
  }
}

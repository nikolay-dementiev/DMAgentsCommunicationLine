import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineService
import CommunicationLineWire
import Foundation
import Testing

private final class RecordingReporter: FailureReporter, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []

  var operations: [String] { lock.withLock { recorded } }

  func report(_ error: any Error, operation: String) {
    lock.withLock { recorded.append("\(operation): \(error)") }
  }
}

private struct SecretDetailError: Error, CustomStringConvertible {
  var description: String { "the secret path /private/example/db" }
}

struct ErrorMappingTests {
  @Test func test_unexpectedError_isAnsweredWithoutItsDetailAndReported() {
    let reporter = RecordingReporter()

    let response = ErrorMapping.response(
      for: SecretDetailError(), operation: "send", reporter: reporter)

    #expect(response.failure?.code == .internal, "an unexpected error is internal")
    #expect(
      response.failure?.message.contains("secret") == false,
      "the detail never reaches the caller")
    #expect(
      reporter.operations == ["send: the secret path /private/example/db"],
      "the detail reaches the reporter once")
  }

  @Test func test_expectedError_isTypedAndNotReported() {
    let reporter = RecordingReporter()

    let response = ErrorMapping.response(
      for: MessagingError.recipientRefused(PrincipalID("p1")), operation: "send",
      reporter: reporter)

    #expect(response.failure?.code == .recipientRefused, "a known error keeps its code")
    #expect(reporter.operations.isEmpty, "a known error is the caller's business, not a fault")
  }
}

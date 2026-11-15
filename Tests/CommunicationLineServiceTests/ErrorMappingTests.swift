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

  @Test func test_anUnusableSetting_isTypedWithItsOwnKeyAndNotReported() {
    let reporter = RecordingReporter()

    let response = ErrorMapping.response(
      for: CleanupError.invalidSetting("health.threshold"), operation: "health",
      reporter: reporter)

    #expect(response.failure?.code == .invalidSetting, "a setting the service cannot use")
    #expect(
      response.failure?.message.contains("health.threshold") == true, "the message names the key")
    #expect(reporter.operations.isEmpty, "it is an expected failure, not an internal one")
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

struct LimitErrorMappingTests {
  @Test func test_theLimitErrors_haveTheirOwnCodes() {
    let reporter = RecordingReporter()
    let cases: [(any Error, WireErrorCode)] = [
      (MessageError.tooManyRecipients(limit: 2, actual: 3), .tooManyRecipients),
      (MessagingError.recipientInboxFull(PrincipalID("p1"), limit: 5), .recipientInboxFull),
      (MessagingError.tooManyWaiters, .tooManyWaiters),
      (MessagingError.storageFull, .storageFull),
    ]
    for (error, expected) in cases {
      let response = ErrorMapping.response(for: error, operation: "send", reporter: reporter)

      #expect(response.failure?.code == expected, "\(error) is \(expected.rawValue)")
    }
    #expect(reporter.operations.isEmpty, "a limit is the caller's business, not a fault")
  }
}

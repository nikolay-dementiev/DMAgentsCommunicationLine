import CommunicationLineDomain
import Testing

@Suite struct MessageLimitsTests {
  private let limits = MessageLimits(maxSubjectBytes: 8, maxBodyBytes: 16, maxRecipients: 2)

  @Test func test_validate_exactlyAtTheLimits_accepts() throws {
    try limits.validate(
      recipientCount: 1, subject: String(repeating: "s", count: 8),
      body: String(repeating: "b", count: 16))
  }

  @Test func test_validate_recipientsOverTheLimit_areRefused() throws {
    try limits.validate(recipientCount: 2, subject: "s", body: "b")

    #expect(throws: MessageError.tooManyRecipients(limit: 2, actual: 3)) {
      try limits.validate(recipientCount: 3, subject: "s", body: "b")
    }
  }

  @Test func test_validate_bodyOverTheLimit_isRefused() {
    #expect(throws: MessageError.bodyTooLarge(limit: 16, actual: 17)) {
      try limits.validate(
        recipientCount: 1, subject: "s", body: String(repeating: "b", count: 17))
    }
  }

  @Test func test_validate_subjectOverTheLimit_isRefused() {
    #expect(throws: MessageError.subjectTooLarge(limit: 8, actual: 9)) {
      try limits.validate(
        recipientCount: 1, subject: String(repeating: "s", count: 9), body: "b")
    }
  }

  @Test func test_validate_countsBytesNotCharacters() {
    // Nine two-byte characters are nine characters but eighteen bytes.
    #expect(throws: MessageError.bodyTooLarge(limit: 16, actual: 18)) {
      try limits.validate(
        recipientCount: 1, subject: "s", body: String(repeating: "\u{E9}", count: 9))
    }
  }

  @Test func test_validate_withoutRecipients_isRefused() {
    #expect(throws: MessageError.noRecipients) {
      try limits.validate(recipientCount: 0, subject: "s", body: "b")
    }
  }
}

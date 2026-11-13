import Foundation

/// The identity of a message. It is random and never reused.
public struct MessageID: Hashable, Sendable {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

/// Why a message is refused before anything is stored.
public enum MessageError: Error, Equatable {
  case noRecipients
  case tooManyRecipients(limit: Int, actual: Int)
  case subjectTooLarge(limit: Int, actual: Int)
  case bodyTooLarge(limit: Int, actual: Int)
}

/// The size limits of a message, in UTF-8 bytes. They come from the settings catalog.
public struct MessageLimits: Equatable, Sendable {
  public let maxSubjectBytes: Int
  public let maxBodyBytes: Int
  public let maxRecipients: Int

  public init(maxSubjectBytes: Int, maxBodyBytes: Int, maxRecipients: Int) {
    self.maxSubjectBytes = maxSubjectBytes
    self.maxBodyBytes = maxBodyBytes
    self.maxRecipients = maxRecipients
  }

  /// A message needs at least one recipient, no more than the recipient limit, and must fit both size limits. Nothing is stored when this throws.
  public func validate(recipientCount: Int, subject: String, body: String) throws {
    guard recipientCount > 0 else { throw MessageError.noRecipients }
    guard recipientCount <= maxRecipients else {
      throw MessageError.tooManyRecipients(limit: maxRecipients, actual: recipientCount)
    }
    let subjectBytes = subject.utf8.count
    guard subjectBytes <= maxSubjectBytes else {
      throw MessageError.subjectTooLarge(limit: maxSubjectBytes, actual: subjectBytes)
    }
    let bodyBytes = body.utf8.count
    guard bodyBytes <= maxBodyBytes else {
      throw MessageError.bodyTooLarge(limit: maxBodyBytes, actual: bodyBytes)
    }
  }
}

/// Whether a recipient has acknowledged a message. Reading never changes it.
public enum DeliveryState: String, Sendable {
  case pending
  case acknowledged
}

/// A message as stored. Its recipients are the original ones; they never change.
public struct StoredMessage: Equatable, Sendable {
  public let id: MessageID
  public let sender: PrincipalID
  /// The sender's family.
  public let family: String
  public let recipients: [PrincipalID]
  public let subject: String
  public let body: String
  public let createdAt: Date

  public init(
    id: MessageID, sender: PrincipalID, family: String, recipients: [PrincipalID],
    subject: String, body: String, createdAt: Date
  ) {
    self.id = id
    self.sender = sender
    self.family = family
    self.recipients = recipients
    self.subject = subject
    self.body = body
    self.createdAt = createdAt
  }
}

import CommunicationLineDomain
import Foundation

/// Why a message operation was refused. Nothing is stored or changed when one of these is thrown.
public enum MessagingError: Error, Equatable {
  /// A recipient id that names no principal.
  case unknownRecipient(PrincipalID)
  /// The send policy refuses this recipient: another family without a rule, or a disabled principal.
  case recipientRefused(PrincipalID)
  /// The message does not exist, or the caller may not see it. The two look the same on purpose.
  case messageUnavailable(MessageID)
  /// A messaging setting holds a value the service cannot use.
  case invalidSetting(key: String)
}

/// A message ready to be stored. The sender is the authenticated caller, never a request field.
public struct OutgoingMessage: Equatable, Sendable {
  public let id: MessageID
  public let sender: PrincipalID
  /// Distinct, in the order the caller gave them.
  public let recipients: [PrincipalID]
  public let subject: String
  public let body: String
  public let createdAt: Date

  public init(
    id: MessageID, sender: PrincipalID, recipients: [PrincipalID], subject: String, body: String,
    createdAt: Date
  ) {
    self.id = id
    self.sender = sender
    self.recipients = recipients
    self.subject = subject
    self.body = body
    self.createdAt = createdAt
  }
}

/// What the store read inside the transaction of a send, for the policy to decide on.
public struct SendContext: Sendable {
  /// `nil` when the sender no longer exists.
  public let sender: Principal?
  /// Only the recipients that exist.
  public let recipients: [PrincipalID: Principal]
  public let rules: [SendRule]

  public init(sender: Principal?, recipients: [PrincipalID: Principal], rules: [SendRule]) {
    self.sender = sender
    self.recipients = recipients
    self.rules = rules
  }
}

/// Where the next inbox page starts. It is a position in the delivery order, not a saved read state.
public struct InboxCursor: Equatable, Sendable {
  public let sequence: Int64

  public init(sequence: Int64) {
    self.sequence = sequence
  }
}

/// One pending delivery as the inbox lists it: who wrote it and what it is about, not its body.
public struct InboxEntry: Equatable, Sendable {
  public let messageID: MessageID
  public let sender: PrincipalID
  public let subject: String
  public let createdAt: Date

  public init(messageID: MessageID, sender: PrincipalID, subject: String, createdAt: Date) {
    self.messageID = messageID
    self.sender = sender
    self.subject = subject
    self.createdAt = createdAt
  }
}

/// A page of pending deliveries, oldest first. `next` is `nil` after the last page.
public struct InboxPage: Equatable, Sendable {
  public let entries: [InboxEntry]
  public let next: InboxCursor?

  public init(entries: [InboxEntry], next: InboxCursor?) {
    self.entries = entries
    self.next = next
  }
}

/// What an acknowledgement found.
public enum AcknowledgeOutcome: Equatable, Sendable {
  case acknowledged
  case alreadyAcknowledged
  /// The principal has no delivery of that message, or the message does not exist.
  case notRecipient
}

/// What the messaging use cases need from persistence.
public protocol MessageStore {
  /// In one transaction: reads the sender, the recipients and the send rules, calls `authorize`, and
  /// only if it returns stores the message with one pending delivery per recipient. When `authorize`
  /// throws, nothing is stored and that error propagates.
  func send(_ message: OutgoingMessage, authorize: (SendContext) throws -> Void) throws

  func message(id: MessageID) throws -> StoredMessage?

  /// The recipient's pending deliveries after `cursor`, oldest first, at most `limit`.
  func inbox(for recipient: PrincipalID, after cursor: InboxCursor?, limit: Int) throws
    -> InboxPage

  /// Marks the recipient's own delivery acknowledged, once. It never touches another recipient's.
  func acknowledge(messageID: MessageID, recipient: PrincipalID, at instant: Date) throws
    -> AcknowledgeOutcome
}

/// Tells waiting recipients that mail has been committed for them.
public protocol MailArrival {
  /// Called after the transaction that stored the mail has committed.
  func signal(recipients: Set<PrincipalID>)
}

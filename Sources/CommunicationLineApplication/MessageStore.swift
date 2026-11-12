import CommunicationLineDomain
import Foundation

/// Why a message operation was refused. Nothing is stored or changed when one of these is thrown.
public enum MessagingError: Error, Equatable {
  /// A recipient id that names no principal.
  case unknownRecipient(PrincipalID)
  /// The send policy refuses this recipient: another family without a rule, or a disabled principal.
  case recipientRefused(PrincipalID)
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

/// What the messaging use cases need from persistence.
public protocol MessageStore {
  /// In one transaction: reads the sender, the recipients and the send rules, calls `authorize`, and
  /// only if it returns stores the message with one pending delivery per recipient. When `authorize`
  /// throws, nothing is stored and that error propagates.
  func send(_ message: OutgoingMessage, authorize: (SendContext) throws -> Void) throws

  func message(id: MessageID) throws -> StoredMessage?
}

/// Tells waiting recipients that mail has been committed for them.
public protocol MailArrival {
  /// Called after the transaction that stored the mail has committed.
  func signal(recipients: Set<PrincipalID>)
}

import CommunicationLineDomain
import Foundation

/// Who made a request, as far as the service could tell.
public enum ActivityActor: Equatable, Sendable {
  case owner
  case principal(PrincipalID)
  case unauthenticated
}

/// What the service writes about one request. It never holds a token, a subject or a body.
public struct NewActivity: Equatable, Sendable {
  public let at: Date
  public let actor: ActivityActor
  public let operation: String
  /// `ok`, or the error code of the refusal or failure.
  public let outcome: String
  /// Ids of the things the request touched, in order.
  public let targets: [String]

  public init(
    at: Date, actor: ActivityActor, operation: String, outcome: String, targets: [String]
  ) {
    self.at = at
    self.actor = actor
    self.operation = operation
    self.outcome = outcome
    self.targets = targets
  }
}

public struct ActivityRecord: Equatable, Sendable {
  public let id: Int64
  public let at: Date
  public let actor: ActivityActor
  public let operation: String
  public let outcome: String
  public let targets: [String]

  public init(
    id: Int64, at: Date, actor: ActivityActor, operation: String, outcome: String,
    targets: [String]
  ) {
    self.id = id
    self.at = at
    self.actor = actor
    self.operation = operation
    self.outcome = outcome
    self.targets = targets
  }
}

public struct ActivityPage: Equatable, Sendable {
  public let records: [ActivityRecord]
  /// Pass it as `after` to get the next page; nil after the last one.
  public let next: Int64?

  public init(records: [ActivityRecord], next: Int64?) {
    self.records = records
    self.next = next
  }
}

/// The append-only list of what the service did.
public protocol ActivityStore {
  func append(_ activity: NewActivity) throws
  func page(after cursor: Int64?, limit: Int) throws -> ActivityPage
}

/// Runs work as one unit: all of it commits together or none of it does. Work started inside a unit
/// joins it.
public protocol TransactionRunner {
  func atomically<Result>(_ body: () throws -> Result) throws -> Result
}

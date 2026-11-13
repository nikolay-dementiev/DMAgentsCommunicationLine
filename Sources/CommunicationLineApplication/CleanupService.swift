import CommunicationLineDomain
import Foundation

/// How many rows one cleanup run deleted.
public struct CleanupResult: Equatable, Sendable {
  public let deliveries: Int
  public let messages: Int
  public let activity: Int

  public init(deliveries: Int, messages: Int, activity: Int) {
    self.deliveries = deliveries
    self.messages = messages
    self.activity = activity
  }
}

/// The deletions retention needs. Pending mail is never among them.
public protocol RetentionStore {
  /// Deletes the deliveries of every message whose deliveries are all acknowledged, the newest
  /// of them before `cutoff`. A message with a pending delivery keeps all of its deliveries.
  func deleteAcknowledgedDeliveries(before cutoff: Date) throws -> Int
  /// Deletes messages that have no delivery left.
  func deleteMessagesWithoutDeliveries() throws -> Int
  /// Deletes activity records older than `cutoff`.
  func deleteActivity(before cutoff: Date) throws -> Int
}

/// What the most recent cleanup run did, for the health report.
public struct CleanupReport: Equatable, Sendable {
  public let at: Date
  /// The deletions, or the reason the run failed.
  public let outcome: Result<CleanupResult, CleanupFailure>

  public init(at: Date, outcome: Result<CleanupResult, CleanupFailure>) {
    self.at = at
    self.outcome = outcome
  }
}

public struct CleanupFailure: Error, Equatable, Sendable {
  public let description: String

  public init(description: String) { self.description = description }
}

public enum CleanupError: Error, Equatable {
  case invalidSetting(String)
}

/// Deletes mail and activity that are past their retention, in one transaction.
public struct CleanupService {
  private let store: any RetentionStore
  private let settings: SettingsService
  private let transactions: any TransactionRunner
  private let clock: any WallClock

  public init(
    store: any RetentionStore, settings: SettingsService, transactions: any TransactionRunner,
    clock: any WallClock
  ) {
    self.store = store
    self.settings = settings
    self.transactions = transactions
    self.clock = clock
  }

  public func run() throws -> CleanupResult {
    let now = clock.now()
    let messageCutoff = try cutoff(now: now, key: "retention.messages.live")
    let activityCutoff = try cutoff(now: now, key: "retention.activity.live")
    return try transactions.atomically {
      let deliveries = try store.deleteAcknowledgedDeliveries(before: messageCutoff)
      let messages = try store.deleteMessagesWithoutDeliveries()
      let activity = try store.deleteActivity(before: activityCutoff)
      return CleanupResult(deliveries: deliveries, messages: messages, activity: activity)
    }
  }

  private func cutoff(now: Date, key: String) throws -> Date {
    guard case .integer(let days) = try settings.serviceValue(of: key), days >= 1 else {
      throw CleanupError.invalidSetting(key)
    }
    return now.addingTimeInterval(-Double(days) * 86_400)
  }
}

import CommunicationLineDomain
import Foundation

public struct PendingCount: Equatable, Sendable {
  public let principal: PrincipalID
  public let count: Int

  public init(principal: PrincipalID, count: Int) {
    self.principal = principal
    self.count = count
  }
}

/// A delivery as the health report reads it from the store.
public struct PendingDelivery: Equatable, Sendable {
  public let message: MessageID
  public let recipient: PrincipalID
  public let recipientFamily: String
  public let createdAt: Date

  public init(
    message: MessageID, recipient: PrincipalID, recipientFamily: String, createdAt: Date
  ) {
    self.message = message
    self.recipient = recipient
    self.recipientFamily = recipientFamily
    self.createdAt = createdAt
  }
}

/// A delivery that has waited longer than its threshold.
public struct OverdueDelivery: Equatable, Sendable {
  public let message: MessageID
  public let recipient: PrincipalID
  /// Whole seconds since the message was sent.
  public let age: Int

  public init(message: MessageID, recipient: PrincipalID, age: Int) {
    self.message = message
    self.recipient = recipient
    self.age = age
  }
}

public enum HealthWarning: String, Equatable, Sendable {
  /// The database passed `storage.warning_percent` of `storage.budget`.
  case storageBudget = "storage_budget"
}

public struct HealthReport: Equatable, Sendable {
  public let startedAt: Date
  public let pending: [PendingCount]
  /// Every overdue delivery, though `overdue` lists only the oldest page of them.
  public let overdueCount: Int
  public let overdue: [OverdueDelivery]
  public let storage: StorageStatus
  public let warnings: [HealthWarning]
  public let lastCleanup: CleanupReport?
}

public protocol HealthStore {
  /// Pending deliveries per recipient.
  func pendingCounts() throws -> [PendingCount]
  /// Pending deliveries of messages created before `cutoff`, oldest first.
  func pendingDeliveries(createdBefore cutoff: Date) throws -> [PendingDelivery]
}

/// What the owner sees of the service: who has mail waiting, what is overdue, how full the database
/// is, and what cleanup last did. It needs no agent session.
public struct HealthService {
  private let store: any HealthStore
  private let settings: SettingsService
  private let storage: StorageService
  private let cleanup: CleanupRunner
  private let identity: IdentityService
  private let clock: any WallClock
  private let startedAt: Date

  public init(
    store: any HealthStore, settings: SettingsService, storage: StorageService,
    cleanup: CleanupRunner, identity: IdentityService, clock: any WallClock, startedAt: Date
  ) {
    self.store = store
    self.settings = settings
    self.storage = storage
    self.cleanup = cleanup
    self.identity = identity
    self.clock = clock
    self.startedAt = startedAt
  }

  public func report(ownerToken: CredentialToken) throws -> HealthReport {
    try identity.authenticateOwner(ownerToken)
    let now = clock.now()
    let overdue = try overdueDeliveries(now: now)
    let page = try pageSize()
    let status = try storage.status()
    return HealthReport(
      startedAt: startedAt, pending: try store.pendingCounts(), overdueCount: overdue.count,
      overdue: Array(overdue.prefix(page)), storage: status,
      warnings: status.isWarning ? [.storageBudget] : [], lastCleanup: cleanup.latest)
  }

  private func overdueDeliveries(now: Date) throws -> [OverdueDelivery] {
    var thresholds: [PrincipalID: Int64] = [:]
    var found: [OverdueDelivery] = []
    for delivery in try store.pendingDeliveries(createdBefore: now) {
      let threshold = try thresholds[delivery.recipient] ?? threshold(for: delivery)
      thresholds[delivery.recipient] = threshold
      let age = Int(now.timeIntervalSince(delivery.createdAt))
      if Int64(age) > threshold {
        found.append(
          OverdueDelivery(message: delivery.message, recipient: delivery.recipient, age: age))
      }
    }
    return found
  }

  private func threshold(for delivery: PendingDelivery) throws -> Int64 {
    guard
      case .integer(let seconds) = try settings.value(
        of: "health.threshold", family: delivery.recipientFamily, principal: delivery.recipient)
    else { throw CleanupError.invalidSetting("health.threshold") }
    return seconds
  }

  private func pageSize() throws -> Int {
    guard case .integer(let size) = try settings.serviceValue(of: "messaging.page_size"),
      let count = Int(exactly: size), count >= 1
    else { throw CleanupError.invalidSetting("messaging.page_size") }
    return count
  }
}

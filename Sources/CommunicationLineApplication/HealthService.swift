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

/// A principal that has mail waiting, with its family, which decides the overdue threshold.
public struct PendingRecipient: Equatable, Sendable {
  public let principal: PrincipalID
  public let family: String
  public let count: Int

  public init(principal: PrincipalID, family: String, count: Int) {
    self.principal = principal
    self.family = family
    self.count = count
  }
}

/// A pending delivery as the health report reads it from the store.
public struct PendingDelivery: Equatable, Sendable {
  public let message: MessageID
  public let recipient: PrincipalID
  public let createdAt: Date
  /// The order in which deliveries were stored, to order deliveries sent in the same instant.
  public let sequence: Int64

  public init(message: MessageID, recipient: PrincipalID, createdAt: Date, sequence: Int64) {
    self.message = message
    self.recipient = recipient
    self.createdAt = createdAt
    self.sequence = sequence
  }
}

/// How many deliveries of one recipient are past a cutoff, and the oldest few of them.
public struct OverdueSlice: Equatable, Sendable {
  public let total: Int
  public let oldest: [PendingDelivery]

  public init(total: Int, oldest: [PendingDelivery]) {
    self.total = total
    self.oldest = oldest
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
  /// The database passed `storage.refusal_percent` of `storage.budget`, so `send` is refused.
  case storageFull = "storage_full"
  /// The last cleanup deleted what it should, but the record of that run could not be written.
  case cleanupNotRecorded = "cleanup_not_recorded"
}

public struct HealthReport: Equatable, Sendable {
  public let startedAt: Date
  public let pending: [PendingCount]
  /// The principals with pending mail and no `wait` parked for them.
  public let notListeningWithPending: Int
  /// Every overdue delivery, though `overdue` lists only the oldest page of them.
  public let overdueCount: Int
  public let overdue: [OverdueDelivery]
  public let storage: StorageStatus
  /// Every principal with its mail and presence, as `principal.list` shows them.
  public let principals: [PrincipalListing]
  public let warnings: [HealthWarning]
  public let lastCleanup: CleanupReport?
}

public protocol HealthStore {
  /// Every principal with pending mail, with how much.
  func pendingRecipients() throws -> [PendingRecipient]
  /// Whether at least one principal belongs to `family`.
  func hasPrincipals(inFamily family: String) throws -> Bool
  /// The pending deliveries of `recipient` created at or before `cutoff`: their number, and the
  /// oldest `limit` of them.
  func overdue(of recipient: PrincipalID, createdAtOrBefore cutoff: Date, limit: Int) throws
    -> OverdueSlice
}

/// What the owner sees of the service: who has mail waiting, what is overdue, how full the database
/// is, and what cleanup last did. It needs no agent session.
public struct HealthService {
  private let store: any HealthStore
  private let settings: SettingsService
  private let storage: StorageService
  private let cleanup: CleanupRunner
  private let identity: IdentityService
  private let directory: DirectoryService
  private let listening: any ListeningRegistry
  private let clock: any WallClock
  private let startedAt: Date

  public init(
    store: any HealthStore, settings: SettingsService, storage: StorageService,
    cleanup: CleanupRunner, identity: IdentityService, directory: DirectoryService,
    listening: any ListeningRegistry, clock: any WallClock, startedAt: Date
  ) {
    self.directory = directory
    self.listening = listening
    self.store = store
    self.settings = settings
    self.storage = storage
    self.cleanup = cleanup
    self.identity = identity
    self.clock = clock
    self.startedAt = startedAt
  }

  /// With `family`, `pending`, `overdue` and the not-listening count keep only the recipients of
  /// that family; storage, warnings, the start and the last cleanup stay global.
  ///
  /// - Throws: ``IdentityError/unknownFamily(_:)`` when `family` has no principal.
  public func report(ownerToken: CredentialToken, family: String? = nil) throws -> HealthReport {
    try identity.authenticateOwner(ownerToken)
    if let family, try !store.hasPrincipals(inFamily: family) {
      throw IdentityError.unknownFamily(family)
    }
    let now = clock.now()
    let page = try pageSize()
    let recipients = try store.pendingRecipients().filter { family == nil || $0.family == family }
    let overdue = try overdueDeliveries(of: recipients, now: now, page: page)
    let status = try storage.status()
    let listeners = listening.listeningPrincipals()
    let lastCleanup = cleanup.latest
    // The same read as `principal.list`, so the two never disagree about who is listening.
    let principals = try directory.principals(family: family, ownerToken: ownerToken)
    return HealthReport(
      startedAt: startedAt,
      pending: recipients.map { PendingCount(principal: $0.principal, count: $0.count) },
      notListeningWithPending: recipients.filter { !listeners.contains($0.principal) }.count,
      overdueCount: overdue.count,
      overdue: overdue.oldest.map { entry in
        OverdueDelivery(
          message: entry.message, recipient: entry.recipient,
          age: Int(now.timeIntervalSince(entry.createdAt)))
      }, storage: status, principals: principals,
      warnings: (status.isWarning ? [.storageBudget] : [])
        + (status.isRefusing ? [.storageFull] : [])
        + (lastCleanup?.isRecorded == false ? [.cleanupNotRecorded] : []),
      lastCleanup: lastCleanup)
  }

  /// A delivery is overdue when its age in whole seconds is more than the threshold of its
  /// recipient, so it must have been created at least `threshold + 1` seconds ago. Each recipient
  /// is asked for one page at most, and the pages are merged.
  private func overdueDeliveries(of recipients: [PendingRecipient], now: Date, page: Int) throws
    -> (count: Int, oldest: [PendingDelivery])
  {
    var count = 0
    var candidates: [PendingDelivery] = []
    for recipient in recipients {
      let seconds = try threshold(for: recipient)
      let cutoff = now.addingTimeInterval(-Double(seconds) - 1)
      let slice = try store.overdue(
        of: recipient.principal, createdAtOrBefore: cutoff, limit: page)
      count += slice.total
      candidates += slice.oldest
    }
    candidates.sort {
      ($0.createdAt, $0.sequence) < ($1.createdAt, $1.sequence)
    }
    return (count, Array(candidates.prefix(page)))
  }

  private func threshold(for recipient: PendingRecipient) throws -> Int64 {
    guard
      case .integer(let seconds) = try settings.value(
        of: "health.threshold", family: recipient.family, principal: recipient.principal),
      seconds >= 0, seconds < Int64(Int32.max)
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

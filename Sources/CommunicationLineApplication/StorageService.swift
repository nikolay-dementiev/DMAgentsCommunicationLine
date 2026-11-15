import Foundation

/// Where the database stands against its budget.
public struct StorageStatus: Equatable, Sendable {
  public let usedBytes: Int64
  public let budgetBytes: Int64
  public let warningPercent: Int
  /// True while the use is at or past `warningPercent` of the budget. It follows the current use,
  /// so it clears by itself once space is freed.
  public let isWarning: Bool
  public let refusalPercent: Int
  /// True while the use is at or past `refusalPercent` of the budget: `send` is refused. Like the
  /// warning, it follows the current use.
  public let isRefusing: Bool

  public init(
    usedBytes: Int64, budgetBytes: Int64, warningPercent: Int, isWarning: Bool,
    refusalPercent: Int, isRefusing: Bool
  ) {
    self.usedBytes = usedBytes
    self.budgetBytes = budgetBytes
    self.warningPercent = warningPercent
    self.isWarning = isWarning
    self.refusalPercent = refusalPercent
    self.isRefusing = isRefusing
  }
}

/// What the message service asks before it accepts new mail.
public protocol StorageGating {
  /// True while the store is past its refusal level.
  func refusesNewMail() throws -> Bool
}

public protocol StorageStore {
  /// Bytes of the database that hold data: pages in use, without the free ones.
  func usedBytes() throws -> Int64
}

public struct StorageService: StorageGating {
  private let store: any StorageStore
  private let settings: SettingsService

  public init(store: any StorageStore, settings: SettingsService) {
    self.store = store
    self.settings = settings
  }

  public func status() throws -> StorageStatus {
    let used = try store.usedBytes()
    guard case .integer(let budget) = try settings.serviceValue(of: "storage.budget"), budget >= 1
    else { throw CleanupError.invalidSetting("storage.budget") }
    guard case .integer(let percent) = try settings.serviceValue(of: "storage.warning_percent"),
      let warningPercent = Int(exactly: percent), warningPercent >= 1
    else { throw CleanupError.invalidSetting("storage.warning_percent") }
    guard case .integer(let refusal) = try settings.serviceValue(of: "storage.refusal_percent"),
      let refusalPercent = Int(exactly: refusal), refusalPercent >= 1
    else { throw CleanupError.invalidSetting("storage.refusal_percent") }
    return StorageStatus(
      usedBytes: used, budgetBytes: budget, warningPercent: warningPercent,
      isWarning: Self.reaches(used: used, budget: budget, percent: warningPercent),
      refusalPercent: refusalPercent,
      isRefusing: Self.reaches(used: used, budget: budget, percent: refusalPercent))
  }

  public func refusesNewMail() throws -> Bool {
    try status().isRefusing
  }

  /// True when `used` is at or past `percent` of `budget`. Products beyond Int64 are far past any
  /// real file: a huge use reaches the level, a huge budget does not.
  private static func reaches(used: Int64, budget: Int64, percent: Int) -> Bool {
    let (usedScaled, usedOverflow) = used.multipliedReportingOverflow(by: 100)
    let (budgetScaled, budgetOverflow) = budget.multipliedReportingOverflow(by: Int64(percent))
    return usedOverflow || (!budgetOverflow && usedScaled >= budgetScaled)
  }
}

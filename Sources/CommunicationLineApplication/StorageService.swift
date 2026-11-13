import Foundation

/// Where the database stands against its budget.
public struct StorageStatus: Equatable, Sendable {
  public let usedBytes: Int64
  public let budgetBytes: Int64
  public let warningPercent: Int
  /// True while the use is at or past `warningPercent` of the budget. It follows the current use,
  /// so it clears by itself once space is freed.
  public let isWarning: Bool

  public init(usedBytes: Int64, budgetBytes: Int64, warningPercent: Int, isWarning: Bool) {
    self.usedBytes = usedBytes
    self.budgetBytes = budgetBytes
    self.warningPercent = warningPercent
    self.isWarning = isWarning
  }
}

public protocol StorageStore {
  /// Bytes of the database that hold data: pages in use, without the free ones.
  func usedBytes() throws -> Int64
}

public struct StorageService {
  private let store: any StorageStore
  private let settings: SettingsService

  public init(store: any StorageStore, settings: SettingsService) {
    self.store = store
    self.settings = settings
  }

  public func status() throws -> StorageStatus {
    let used = try store.usedBytes()
    guard case .integer(let budget) = try settings.serviceValue(of: "storage.budget"), budget >= 1,
      case .integer(let percent) = try settings.serviceValue(of: "storage.warning_percent"),
      let warningPercent = Int(exactly: percent), warningPercent >= 1
    else { throw CleanupError.invalidSetting("storage.budget") }
    // Products beyond Int64 are far past any real file: a huge use warns, a huge budget does not.
    let (usedScaled, usedOverflow) = used.multipliedReportingOverflow(by: 100)
    let (budgetScaled, budgetOverflow) = budget.multipliedReportingOverflow(
      by: Int64(warningPercent))
    let warning = usedOverflow || (!budgetOverflow && usedScaled >= budgetScaled)
    return StorageStatus(
      usedBytes: used, budgetBytes: budget, warningPercent: warningPercent, isWarning: warning)
  }
}

import CommunicationLineApplication
import CommunicationLineDomain
import Foundation

/// Keeps the activity records in the SQLite database. A table trigger refuses updates and deletes.
public final class SQLiteActivityStore: ActivityStore {
  private let store: SQLiteStore

  public init(store: SQLiteStore) {
    self.store = store
  }

  public func append(_ activity: NewActivity) throws {
    try store.database.execute(
      """
      INSERT INTO activity (at_ms, actor, operation, outcome, targets)
      VALUES (?1, ?2, ?3, ?4, ?5)
      """,
      [
        .integer(try StoreTime.milliseconds(of: activity.at)),
        .text(Self.encode(activity.actor)), .text(activity.operation), .text(activity.outcome),
        .text(try Self.encode(targets: activity.targets)),
      ])
  }

  public func page(after cursor: Int64?, limit: Int) throws -> ActivityPage {
    guard limit > 0 else { return ActivityPage(records: [], next: nil) }
    let rows = try store.database.rows(
      """
      SELECT id, at_ms, actor, operation, outcome, targets FROM activity
      WHERE id > ?1 ORDER BY id LIMIT ?2
      """,
      [.integer(cursor ?? 0), .integer(Int64(limit) + 1)])
    let records = try rows.prefix(limit).map(Self.record)
    let next = rows.count > limit ? records.last?.id : nil
    return ActivityPage(records: records, next: next)
  }

  // MARK: - Encoding

  private static func encode(_ actor: ActivityActor) -> String {
    switch actor {
    case .owner: return "owner"
    case .unauthenticated: return "unauthenticated"
    case .principal(let id): return "principal:" + id.rawValue
    }
  }

  private static func decode(actor text: String) throws -> ActivityActor {
    switch text {
    case "owner": return .owner
    case "unauthenticated": return .unauthenticated
    default:
      guard text.hasPrefix("principal:") else { throw StoreError.invalidStoredActivity }
      return .principal(PrincipalID(String(text.dropFirst("principal:".count))))
    }
  }

  private static func encode(targets: [String]) throws -> String {
    String(decoding: try JSONEncoder().encode(targets), as: UTF8.self)
  }

  private static func record(_ row: [SQLiteValue]) throws -> ActivityRecord {
    guard row.count == 6, case .integer(let id) = row[0], case .integer(let milliseconds) = row[1],
      case .text(let actor) = row[2], case .text(let operation) = row[3],
      case .text(let outcome) = row[4], case .text(let targets) = row[5],
      let list = try? JSONDecoder().decode([String].self, from: Data(targets.utf8))
    else { throw StoreError.invalidStoredActivity }
    return ActivityRecord(
      id: id, at: Date(timeIntervalSince1970: Double(milliseconds) / 1000),
      actor: try decode(actor: actor), operation: operation, outcome: outcome, targets: list)
  }
}

/// Makes the services' transactions one unit by running them inside a single database transaction.
public struct SQLiteTransactionRunner: TransactionRunner {
  private let store: SQLiteStore

  public init(store: SQLiteStore) {
    self.store = store
  }

  public func atomically<Result>(_ body: () throws -> Result) throws -> Result {
    try store.database.transaction(body)
  }
}

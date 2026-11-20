import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineWire
import Foundation

/// How domain values look on the wire. Instants are whole milliseconds since 1970.
enum WireMapping {
  static func milliseconds(_ date: Date) -> WireValue {
    .integer(Int64((date.timeIntervalSince1970 * 1000).rounded()))
  }

  static func principal(_ principal: Principal) -> WireValue {
    .object([
      "id": .string(principal.id.rawValue), "family": .string(principal.family),
      "role": .string(principal.role.rawValue), "name": .string(principal.displayName),
      "enabled": .bool(principal.isEnabled),
    ])
  }

  static func listing(_ listing: PrincipalListing) -> WireValue {
    let principal = listing.principal
    return .object([
      "id": .string(principal.id.rawValue), "family": .string(principal.family),
      "role": .string(principal.role.rawValue), "name": .string(principal.displayName),
      "enabled": .bool(principal.isEnabled), "pending": .integer(Int64(listing.pending)),
      "listening_since_ms": listing.listeningSince.map(milliseconds) ?? .null,
    ])
  }

  static func inboxPage(_ page: InboxPage) -> WireValue {
    .object([
      "entries": .array(
        page.entries.map { entry in
          .object([
            "id": .string(entry.messageID.rawValue), "sender": .string(entry.sender.rawValue),
            "subject": .string(entry.subject), "created_at_ms": milliseconds(entry.createdAt),
          ])
        }),
      "next": page.next.map { .integer($0.sequence) } ?? .null,
    ])
  }

  static func message(_ message: StoredMessage) -> WireValue {
    .object([
      "id": .string(message.id.rawValue), "sender": .string(message.sender.rawValue),
      "family": .string(message.family),
      "recipients": .array(message.recipients.map { .string($0.rawValue) }),
      "subject": .string(message.subject), "body": .string(message.body),
      "created_at_ms": milliseconds(message.createdAt),
    ])
  }

  static func grant(_ stored: StoredReadGrant) -> WireValue {
    let reader: (String, String)
    switch stored.grant.reader {
    case .principal(let id): reader = ("principal", id.rawValue)
    case .family(let name): reader = ("family", name)
    }
    let target: (String, WireValue)
    switch stored.grant.target {
    case .principal(let id): target = ("principal", .string(id.rawValue))
    case .family(let name): target = ("family", .string(name))
    case .global: target = ("global", .null)
    }
    return .object([
      "id": .integer(stored.id), "reader_kind": .string(reader.0), "reader": .string(reader.1),
      "target_kind": .string(target.0), "target": target.1,
      "expires_at_ms": stored.grant.expiresAt.map(milliseconds) ?? .null,
      "revoked": .bool(stored.grant.isRevoked),
    ])
  }

  static func rule(_ rule: SendRule) -> WireValue {
    .object(["from": .string(rule.fromFamily), "to": .string(rule.toFamily)])
  }

  static func settingValue(_ value: SettingValue) -> WireValue {
    switch value {
    case .integer(let number): return .integer(number)
    case .boolean(let flag): return .bool(flag)
    case .text(let text): return .string(text)
    }
  }

  static func settingValue(from wire: WireValue?) throws -> SettingValue {
    switch wire {
    case .integer(let number)?: return .integer(number)
    case .bool(let flag)?: return .boolean(flag)
    case .string(let text)?: return .text(text)
    default: throw RequestError.badRequest("argument value must be an integer, bool or string")
    }
  }

  static func activity(_ record: ActivityRecord) -> WireValue {
    let actor: String
    switch record.actor {
    case .owner: actor = "owner"
    case .unauthenticated: actor = "unauthenticated"
    case .principal(let id): actor = "principal:" + id.rawValue
    }
    return .object([
      "id": .integer(record.id), "at_ms": milliseconds(record.at), "actor": .string(actor),
      "operation": .string(record.operation), "outcome": .string(record.outcome),
      "targets": .array(record.targets.map { .string($0) }),
    ])
  }

  /// The version of the health document, described in docs/health.md. Within a version fields are
  /// only added; renaming, removing or retyping one needs the next version.
  static let healthDocumentVersion: Int64 = 1

  static func health(_ report: HealthReport) -> WireValue {
    .object([
      "version": .integer(healthDocumentVersion),
      "started_at_ms": milliseconds(report.startedAt),
      "pending": .array(
        report.pending.map {
          .object(["principal": .string($0.principal.rawValue), "count": .integer(Int64($0.count))])
        }),
      "not_listening_with_pending": .integer(Int64(report.notListeningWithPending)),
      "overdue_count": .integer(Int64(report.overdueCount)),
      "overdue": .array(
        report.overdue.map {
          .object([
            "message": .string($0.message.rawValue), "recipient": .string($0.recipient.rawValue),
            "age_seconds": .integer(Int64($0.age)),
          ])
        }),
      "storage": .object([
        "used_bytes": .integer(report.storage.usedBytes),
        "budget_bytes": .integer(report.storage.budgetBytes),
        "warning_percent": .integer(Int64(report.storage.warningPercent)),
        "refusal_percent": .integer(Int64(report.storage.refusalPercent)),
      ]),
      "warnings": .array(report.warnings.map { .string($0.rawValue) }),
      "last_cleanup": report.lastCleanup.map(cleanup) ?? .null,
    ])
  }

  private static func cleanup(_ report: CleanupReport) -> WireValue {
    var fields: [String: WireValue] = ["at_ms": milliseconds(report.at)]
    switch report.outcome {
    case .success(let result):
      fields["ok"] = .bool(true)
      fields["deliveries"] = .integer(Int64(result.deliveries))
      fields["messages"] = .integer(Int64(result.messages))
      fields["activity"] = .integer(Int64(result.activity))
    case .failure:
      // The reason went to the service's own log; the report says only that the run failed.
      fields["ok"] = .bool(false)
    }
    return .object(fields)
  }
}

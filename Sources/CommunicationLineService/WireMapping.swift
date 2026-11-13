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
}

import CommunicationLineWire
import Foundation

/// Turns an answer into the text a person or a script reads.
enum Renderer {
  static func json(_ value: WireValue) -> String {
    guard let data = try? WireCoding.encode(value) else { return "null" }
    return String(decoding: data, as: UTF8.self)
  }

  static func failureJSON(_ failure: WireFailure) -> String {
    let body = WireValue.object([
      "error": .object([
        "code": .string(failure.code.rawValue), "message": .string(failure.message),
      ])
    ])
    return json(body)
  }

  /// The lines to print for a successful result.
  static func text(_ result: WireValue, as presentation: Presentation) -> [String] {
    let fields: [String: WireValue]
    if case .object(let object) = result { fields = object } else { fields = [:] }
    switch presentation {
    case .acknowledged: return ["ok"]
    case .messageID: return [string(fields["id"])]
    case .token: return [string(fields["token"])]
    case .outcome: return [string(fields["outcome"])]
    case .setting: return [scalar(fields["value"])]
    case .grantID: return [scalar(fields["id"])]
    case .principal:
      return [
        [fields["id"], fields["family"], fields["role"], fields["name"]].map(string).joined(
          separator: "\t")
      ]
    case .inbox: return inbox(fields)
    case .message: return message(fields)
    case .rules:
      return array(fields["rules"]).map {
        [$0["from"], $0["to"]].map(string).joined(separator: "\t")
      }
    case .grants: return array(fields["grants"]).map(grant)
    case .activity: return activity(fields)
    }
  }

  private static func inbox(_ fields: [String: WireValue]) -> [String] {
    var lines = array(fields["entries"]).map {
      [$0["id"], $0["sender"], $0["created_at_ms"], $0["subject"]].map(scalarOrEmpty).joined(
        separator: "\t")
    }
    if case .integer(let next)? = fields["next"] { lines.append("next: \(next)") }
    return lines
  }

  private static func activity(_ fields: [String: WireValue]) -> [String] {
    var lines = array(fields["records"]).map { record -> String in
      var targets: [String] = []
      if case .array(let items)? = record["targets"] { targets = items.map { string($0) } }
      return [
        scalar(record["id"]), scalar(record["at_ms"]), string(record["actor"]),
        string(record["operation"]), string(record["outcome"]), targets.joined(separator: ","),
      ].joined(separator: "\t")
    }
    if case .integer(let next)? = fields["next"] { lines.append("next: \(next)") }
    return lines
  }

  private static func message(_ fields: [String: WireValue]) -> [String] {
    var recipients: [String] = []
    if case .array(let items)? = fields["recipients"] { recipients = items.map { string($0) } }
    return [
      "From: \(string(fields["sender"]))", "To: \(recipients.joined(separator: ", "))",
      "Subject: \(string(fields["subject"]))", "", string(fields["body"]),
    ]
  }

  private static func grant(_ entry: [String: WireValue]) -> String {
    let target = entry["target"].map(scalar).flatMap { $0.isEmpty ? nil : $0 }
    return [
      scalar(entry["id"]), "\(string(entry["reader_kind"])):\(string(entry["reader"]))",
      string(entry["target_kind"]) + (target.map { ":\($0)" } ?? ""),
      entry["expires_at_ms"].map(scalarOrEmpty) ?? "", scalar(entry["revoked"]),
    ].joined(separator: "\t")
  }

  // MARK: - Value helpers

  private static func array(_ value: WireValue?) -> [[String: WireValue]] {
    guard case .array(let items)? = value else { return [] }
    return items.compactMap { item in
      if case .object(let fields) = item { return fields }
      return nil
    }
  }

  private static func string(_ value: WireValue?) -> String {
    if case .string(let text)? = value { return text }
    return scalar(value)
  }

  private static func scalarOrEmpty(_ value: WireValue?) -> String { scalar(value) }

  private static func scalar(_ value: WireValue?) -> String {
    switch value {
    case .string(let text)?: return text
    case .integer(let number)?: return String(number)
    case .bool(let flag)?: return flag ? "true" : "false"
    default: return ""
    }
  }
}

import CommunicationLineWire
import Foundation

/// Turns an answer into the text a person or a script reads.
enum Renderer {
  /// The exact JSON of a result. An encoding failure is thrown, never printed as `null`.
  static func json(_ value: WireValue, encode: (WireValue) throws -> Data) throws -> String {
    String(decoding: try encode(value), as: UTF8.self)
  }

  /// The JSON of a failure for standard error. When even that cannot be encoded the plain text
  /// form is used, so the failure is never lost.
  static func failureJSON(_ failure: WireFailure, encode: (WireValue) throws -> Data) -> String {
    let body = WireValue.object([
      "error": .object([
        "code": .string(failure.code.rawValue), "message": .string(failure.message),
      ])
    ])
    return (try? json(body, encode: encode))
      ?? "commline: \(failure.code.rawValue): \(failure.message)"
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
    case .principals: return array(fields["principals"]).map(listedPrincipal)
    case .inbox: return inbox(fields)
    case .message: return message(fields)
    case .rules:
      return array(fields["rules"]).map {
        [$0["from"], $0["to"]].map(string).joined(separator: "\t")
      }
    case .grants: return array(fields["grants"]).map(grant)
    case .activity: return activity(fields)
    case .health: return health(fields)
    case .cleanup:
      return ["deliveries", "messages", "activity"].map { "\($0): \(scalar(fields[$0]))" }
    }
  }

  /// What `--json` prints for a successful result. The owner listing is an array of objects, so a
  /// script reads it without the wrapper that the wire needs.
  static func jsonBody(_ result: WireValue, as presentation: Presentation) -> WireValue {
    guard presentation == .principals, case .object(let fields) = result,
      let principals = fields["principals"]
    else { return result }
    return principals
  }

  private static func listedPrincipal(_ entry: [String: WireValue]) -> String {
    var listening = "not listening"
    if case .integer(let since)? = entry["listening_since_ms"] {
      listening = "listening since \(since)"
    }
    return [
      string(entry["id"]), string(entry["family"]), string(entry["role"]), string(entry["name"]),
      entry["enabled"] == .bool(true) ? "enabled" : "disabled",
      "pending \(scalar(entry["pending"]))", listening,
    ].joined(separator: "\t")
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

  private static func health(_ fields: [String: WireValue]) -> [String] {
    var lines = ["started: \(scalar(fields["started_at_ms"]))"]
    if case .object(let storage)? = fields["storage"] {
      lines.append(
        "storage: \(scalar(storage["used_bytes"])) of \(scalar(storage["budget_bytes"])) bytes, "
          + "warning at \(scalar(storage["warning_percent"]))%, "
          + "refusing sends at \(scalar(storage["refusal_percent"]))%")
    }
    if case .array(let warnings)? = fields["warnings"] {
      lines += warnings.map { "warning: \(string($0))" }
    }
    lines += array(fields["pending"]).map {
      "pending: \(string($0["principal"]))\t\(scalar($0["count"]))"
    }
    lines.append("not listening with pending: \(scalar(fields["not_listening_with_pending"]))")
    lines.append("overdue: \(scalar(fields["overdue_count"]))")
    lines += array(fields["overdue"]).map {
      "\(string($0["message"]))\t\(string($0["recipient"]))\t\(scalar($0["age_seconds"]))s"
    }
    lines.append(lastCleanup(fields["last_cleanup"]))
    return lines
  }

  private static func lastCleanup(_ value: WireValue?) -> String {
    guard case .object(let fields)? = value else { return "last cleanup: none" }
    guard case .bool(true)? = fields["ok"] else {
      return "last cleanup: \(scalar(fields["at_ms"])) failed"
    }
    return "last cleanup: \(scalar(fields["at_ms"])) deliveries=\(scalar(fields["deliveries"])) "
      + "messages=\(scalar(fields["messages"])) activity=\(scalar(fields["activity"]))"
  }

  private static func message(_ fields: [String: WireValue]) -> [String] {
    var recipients: [String] = []
    if case .array(let items)? = fields["recipients"] { recipients = items.map { string($0) } }
    return [
      "From: \(string(fields["sender"]))", "To: \(recipients.joined(separator: ", "))",
      "Subject: \(string(fields["subject"]))", "", body(fields["body"]),
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
    scalar(value)
  }

  /// A message body keeps its line breaks and tabs so that it stays readable; every other control
  /// character is escaped like in any other field.
  private static func body(_ value: WireValue?) -> String {
    guard case .string(let text)? = value else { return "" }
    return escaped(text, keepingLayout: true)
  }

  /// Text chosen by an agent can carry terminal control sequences. Printing it raw would let one
  /// agent drive the terminal of the person reading it, so control characters are written as
  /// `\u{1b}`. Bidirectional controls and the Unicode line and paragraph separators are escaped
  /// too: they can reorder or hide text on screen. `--json` is not affected: it prints the text
  /// exactly.
  static func escaped(_ text: String, keepingLayout: Bool = false) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
      let value = scalar.value
      let isControl =
        value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value)
        || (0x202A...0x202E).contains(value) || (0x2066...0x2069).contains(value)
        || value == 0x2028 || value == 0x2029
      let isLayout = keepingLayout && (value == 0x0A || value == 0x09)
      if isControl && !isLayout {
        result += "\\u{" + String(value, radix: 16) + "}"
      } else {
        result.unicodeScalars.append(scalar)
      }
    }
    return result
  }

  private static func scalarOrEmpty(_ value: WireValue?) -> String { scalar(value) }

  private static func scalar(_ value: WireValue?) -> String {
    switch value {
    case .string(let text)?: return escaped(text)
    case .integer(let number)?: return String(number)
    case .bool(let flag)?: return flag ? "true" : "false"
    default: return ""
    }
  }
}

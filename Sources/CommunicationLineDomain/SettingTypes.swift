/// The kinds of value a setting can hold. Durations and sizes are integers in the unit the definition names.
public enum SettingType: String, Sendable {
  case integer
  case duration
  case bytes
  case boolean
  case enumeration = "enum"
}

/// Where a stored value applies: everywhere, to one immutable family, or to one principal.
public enum SettingScope: String, Sendable, CaseIterable {
  case global
  case family
  case principal
}

/// A setting value as stored and as exchanged with callers.
public enum SettingValue: Equatable, Sendable, Codable {
  case integer(Int64)
  case boolean(Bool)
  case text(String)

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    // Probe the JSON kinds in turn; when none fits, the final throw reports the problem.
    if let flag = try? container.decode(Bool.self) {
      self = .boolean(flag)
    } else if let number = try? container.decode(Int64.self) {
      self = .integer(number)
    } else if let text = try? container.decode(String.self) {
      self = .text(text)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "a setting value is an integer, a boolean or a string")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .integer(let number): try container.encode(number)
    case .boolean(let flag): try container.encode(flag)
    case .text(let text): try container.encode(text)
    }
  }
}

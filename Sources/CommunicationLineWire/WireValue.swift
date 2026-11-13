import Foundation

/// A JSON value as exchanged on the socket. Numbers are integers only: no fractions cross the wire.
public enum WireValue: Equatable, Sendable, Codable {
  case null
  case bool(Bool)
  case integer(Int64)
  case string(String)
  case array([WireValue])
  case object([String: WireValue])

  public init(from decoder: any Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([WireValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: WireValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "a value that is not null, bool, integer, string, array or object")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .integer(let value): try container.encode(value)
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }
}

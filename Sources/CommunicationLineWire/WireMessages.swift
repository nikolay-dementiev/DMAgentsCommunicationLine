import Foundation

public enum WireError: Error, Equatable {
  /// The bytes are not a request or a response of this protocol.
  case malformed
}

/// One request: the token travels in the body, never in anything else.
public struct WireRequest: Equatable, Sendable, Codable {
  public let token: String?
  public let operation: String
  public let arguments: [String: WireValue]

  public init(token: String?, operation: String, arguments: [String: WireValue] = [:]) {
    self.token = token
    self.operation = operation
    self.arguments = arguments
  }

  private enum CodingKeys: String, CodingKey {
    case token
    case operation = "op"
    case arguments = "args"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    token = try container.decodeIfPresent(String.self, forKey: .token)
    operation = try container.decode(String.self, forKey: .operation)
    arguments = try container.decodeIfPresent([String: WireValue].self, forKey: .arguments) ?? [:]
  }
}

public struct WireFailure: Equatable, Sendable, Codable {
  public let code: WireErrorCode
  public let message: String

  public init(code: WireErrorCode, message: String) {
    self.code = code
    self.message = message
  }
}

/// One response: a result or a typed failure, never both and never neither.
public struct WireResponse: Equatable, Sendable, Codable {
  public let isSuccess: Bool
  public let result: WireValue?
  public let failure: WireFailure?

  private init(isSuccess: Bool, result: WireValue?, failure: WireFailure?) {
    self.isSuccess = isSuccess
    self.result = result
    self.failure = failure
  }

  public static func success(_ result: WireValue = .object([:])) -> WireResponse {
    WireResponse(isSuccess: true, result: result, failure: nil)
  }

  public static func failure(code: WireErrorCode, message: String) -> WireResponse {
    WireResponse(isSuccess: false, result: nil, failure: WireFailure(code: code, message: message))
  }

  private enum CodingKeys: String, CodingKey {
    case isSuccess = "ok"
    case result
    case failure = "error"
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let isSuccess = try container.decode(Bool.self, forKey: .isSuccess)
    let result = try container.decodeIfPresent(WireValue.self, forKey: .result)
    let failure = try container.decodeIfPresent(WireFailure.self, forKey: .failure)
    let consistent = isSuccess ? (failure == nil) : (failure != nil && result == nil)
    guard consistent else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: [], debugDescription: "ok contradicts result and error"))
    }
    self.init(isSuccess: isSuccess, result: result, failure: failure)
  }
}

/// JSON encoding of requests and responses. Failures to decode are reported as ``WireError/malformed``.
public enum WireCoding {
  public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
  }

  /// Real requests nest a few levels. The decoder recurses on the stack of a connection thread, so
  /// a hostile frame of brackets must be refused before it is decoded.
  public static let maximumDepth = 32

  public static func decodeRequest(_ data: Data) throws -> WireRequest {
    guard isWithinDepthLimit(data) else { throw WireError.malformed }
    do { return try JSONDecoder().decode(WireRequest.self, from: data) } catch {
      throw WireError.malformed
    }
  }

  public static func decodeResponse(_ data: Data) throws -> WireResponse {
    guard isWithinDepthLimit(data) else { throw WireError.malformed }
    do { return try JSONDecoder().decode(WireResponse.self, from: data) } catch {
      throw WireError.malformed
    }
  }

  /// Counts bracket nesting outside strings without recursing.
  private static func isWithinDepthLimit(_ data: Data) -> Bool {
    var depth = 0
    var inString = false
    var escaped = false
    for byte in data {
      if inString {
        if escaped {
          escaped = false
        } else if byte == UInt8(ascii: "\\") {
          escaped = true
        } else if byte == UInt8(ascii: "\"") {
          inString = false
        }
        continue
      }
      switch byte {
      case UInt8(ascii: "\""): inString = true
      case UInt8(ascii: "["), UInt8(ascii: "{"):
        depth += 1
        if depth > maximumDepth { return false }
      case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
      default: break
      }
    }
    return true
  }
}

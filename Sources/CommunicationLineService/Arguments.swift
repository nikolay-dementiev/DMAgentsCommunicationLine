import CommunicationLineWire

/// Typed access to the arguments of one request. A missing or mistyped argument is a bad request.
struct Arguments {
  let values: [String: WireValue]

  func string(_ key: String) throws -> String {
    guard let value = try optionalString(key) else {
      throw RequestError.badRequest("argument \(key) is required")
    }
    return value
  }

  func optionalString(_ key: String) throws -> String? {
    switch values[key] {
    case nil, .null?: return nil
    case .string(let value)?: return value
    default: throw RequestError.badRequest("argument \(key) must be a string")
    }
  }

  func integer(_ key: String) throws -> Int64 {
    guard let value = try optionalInteger(key) else {
      throw RequestError.badRequest("argument \(key) is required")
    }
    return value
  }

  func optionalInteger(_ key: String) throws -> Int64? {
    switch values[key] {
    case nil, .null?: return nil
    case .integer(let value)?: return value
    default: throw RequestError.badRequest("argument \(key) must be an integer")
    }
  }

  func strings(_ key: String) throws -> [String] {
    guard case .array(let items)? = values[key] else {
      throw RequestError.badRequest("argument \(key) must be a list of strings")
    }
    return try items.map { item in
      guard case .string(let text) = item else {
        throw RequestError.badRequest("argument \(key) must be a list of strings")
      }
      return text
    }
  }
}

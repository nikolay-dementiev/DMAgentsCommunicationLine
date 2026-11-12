import Foundation

/// Why a catalog resource was refused at load.
public enum SettingsCatalogError: Error, Equatable {
  case malformed(String)
  case unknownType(key: String, type: String)
  case unknownScope(key: String, scope: String)
  case duplicateKey(String)
  case defaultInvalid(key: String, reason: SettingValueError)
  case minimumAboveMaximum(key: String)
  case noScopes(key: String)
  case enumWithoutValues(key: String)
  case rangeOnNonNumericType(key: String)
  case valuesOnNonEnumType(key: String)
}

/// The validated set of settings. A catalog that loads has no duplicate key and every default is
/// valid for its own definition.
public struct SettingsCatalog: Equatable, Sendable {
  /// The definitions, sorted by key.
  public let definitions: [SettingDefinition]

  public var keys: [String] { definitions.map(\.key) }

  public init(definitions: [SettingDefinition]) throws {
    var seen: Set<String> = []
    for definition in definitions {
      guard seen.insert(definition.key).inserted else {
        throw SettingsCatalogError.duplicateKey(definition.key)
      }
      try Self.checkShape(of: definition)
      do {
        try definition.validate(definition.defaultValue)
      } catch let reason as SettingValueError {
        throw SettingsCatalogError.defaultInvalid(key: definition.key, reason: reason)
      }
    }
    self.definitions = definitions.sorted { $0.key < $1.key }
  }

  /// Refuses a definition that cannot describe a real setting, before its default is checked.
  private static func checkShape(of definition: SettingDefinition) throws {
    let key = definition.key
    guard !definition.scopes.isEmpty else { throw SettingsCatalogError.noScopes(key: key) }
    let numeric =
      definition.type == .integer || definition.type == .duration
      || definition.type == .bytes
    if let range = definition.range {
      guard numeric else { throw SettingsCatalogError.rangeOnNonNumericType(key: key) }
      if let low = range.minimum, let high = range.maximum, low > high {
        throw SettingsCatalogError.minimumAboveMaximum(key: key)
      }
    }
    if definition.type == .enumeration {
      guard let values = definition.allowedValues, !values.isEmpty else {
        throw SettingsCatalogError.enumWithoutValues(key: key)
      }
    } else if definition.allowedValues != nil {
      throw SettingsCatalogError.valuesOnNonEnumType(key: key)
    }
  }

  public func definition(for key: String) -> SettingDefinition? {
    definitions.first { $0.key == key }
  }

  /// Reads the defaults resource: `{"settings":[{key, type, unit?, default, range?, values?, scopes, description}]}`.
  public static func decode(from data: Data) throws -> SettingsCatalog {
    let raw: RawCatalog
    do {
      raw = try JSONDecoder().decode(RawCatalog.self, from: data)
    } catch {
      throw SettingsCatalogError.malformed("\(error)")
    }
    return try SettingsCatalog(definitions: raw.settings.map { try $0.definition() })
  }
}

private struct RawCatalog: Decodable {
  let settings: [RawDefinition]
}

private struct RawDefinition: Decodable {
  struct Range: Decodable {
    let min: Int64?
    let max: Int64?
  }

  let key: String
  let type: String
  let unit: String?
  let defaultValue: SettingValue
  let range: Range?
  let values: [String]?
  let scopes: [String]
  let description: String

  enum CodingKeys: String, CodingKey {
    case key, type, unit, range, values, scopes, description
    case defaultValue = "default"
  }

  func definition() throws -> SettingDefinition {
    guard let settingType = SettingType(rawValue: type) else {
      throw SettingsCatalogError.unknownType(key: key, type: type)
    }
    let parsedScopes = try scopes.map { name -> SettingScope in
      guard let scope = SettingScope(rawValue: name) else {
        throw SettingsCatalogError.unknownScope(key: key, scope: name)
      }
      return scope
    }
    return SettingDefinition(
      key: key, type: settingType, unit: unit, defaultValue: defaultValue,
      range: range.map { SettingRange(minimum: $0.min, maximum: $0.max) },
      allowedValues: values, scopes: Set(parsedScopes), description: description)
  }
}

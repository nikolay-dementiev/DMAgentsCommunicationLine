/// Why a value is not acceptable for a setting.
public enum SettingValueError: Error, Equatable {
  case typeMismatch(expected: SettingType)
  case belowMinimum(Int64)
  case aboveMaximum(Int64)
  case notAllowed([String])
}

/// The inclusive bounds of a numeric setting; a missing bound is open.
public struct SettingRange: Equatable, Sendable {
  public let minimum: Int64?
  public let maximum: Int64?

  public init(minimum: Int64?, maximum: Int64?) {
    self.minimum = minimum
    self.maximum = maximum
  }
}

/// One entry of the settings catalog: its type, default, allowed values and scopes.
public struct SettingDefinition: Equatable, Sendable {
  public let key: String
  public let type: SettingType
  public let unit: String?
  public let defaultValue: SettingValue
  public let range: SettingRange?
  public let allowedValues: [String]?
  public let scopes: Set<SettingScope>
  public let description: String

  public init(
    key: String, type: SettingType, unit: String?, defaultValue: SettingValue,
    range: SettingRange?, allowedValues: [String]?, scopes: Set<SettingScope>, description: String
  ) {
    self.key = key
    self.type = type
    self.unit = unit
    self.defaultValue = defaultValue
    self.range = range
    self.allowedValues = allowedValues
    self.scopes = scopes
    self.description = description
  }

  /// Checks `value` against the type, the range and the allowed values of this setting.
  public func validate(_ value: SettingValue) throws {
    switch (type, value) {
    case (.integer, .integer(let number)), (.duration, .integer(let number)),
      (.bytes, .integer(let number)):
      if let minimum = range?.minimum, number < minimum {
        throw SettingValueError.belowMinimum(minimum)
      }
      if let maximum = range?.maximum, number > maximum {
        throw SettingValueError.aboveMaximum(maximum)
      }
    case (.boolean, .boolean):
      break
    case (.enumeration, .text(let text)):
      let allowed = allowedValues ?? []
      if !allowed.contains(text) { throw SettingValueError.notAllowed(allowed) }
    default:
      throw SettingValueError.typeMismatch(expected: type)
    }
  }

  /// The value that applies for a caller: principal, then family, then global, then the default.
  /// A stored value in a scope the key does not allow is ignored.
  public func effectiveValue(
    principal: SettingValue?, family: SettingValue?, global: SettingValue?
  ) -> SettingValue {
    if scopes.contains(.principal), let value = principal { return value }
    if scopes.contains(.family), let value = family { return value }
    if scopes.contains(.global), let value = global { return value }
    return defaultValue
  }
}

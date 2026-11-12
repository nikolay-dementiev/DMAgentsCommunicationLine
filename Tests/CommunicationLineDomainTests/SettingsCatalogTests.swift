import CommunicationLineDomain
import Foundation
import Testing

@Suite struct SettingsCatalogTests {
  @Test func test_decode_validCatalog_exposesEveryDefinitionField() throws {
    let catalog = try SettingsCatalog.decode(
      from: catalogData(
        integerSetting(),
        #"{"key":"demo.mode","type":"enum","default":"fast","values":["fast","slow"],"scopes":["global"],"description":"A mode."}"#,
        #"{"key":"demo.wait","type":"duration","unit":"seconds","default":900,"range":{"min":0,"max":900},"scopes":["global"],"description":"A wait."}"#
      ))

    let limit = try #require(catalog.definition(for: "demo.limit"))
    #expect(limit.type == .integer, "the type is read")
    #expect(limit.defaultValue == .integer(5), "the default is read")
    #expect(limit.range == SettingRange(minimum: 1, maximum: 10), "the range is read")
    #expect(limit.scopes == [.global, .family, .principal], "the scopes are read")
    #expect(catalog.definition(for: "demo.mode")?.allowedValues == ["fast", "slow"], "enum values")
    #expect(catalog.definition(for: "demo.wait")?.unit == "seconds", "the unit is read")
    #expect(catalog.keys == ["demo.limit", "demo.mode", "demo.wait"], "keys are sorted")
  }

  @Test func test_decode_defaultAboveItsRange_failsAtLoad() {
    #expect(
      throws: SettingsCatalogError.defaultInvalid(key: "demo.limit", reason: .aboveMaximum(10))
    ) {
      _ = try SettingsCatalog.decode(from: catalogData(integerSetting(defaultValue: 11)))
    }
  }

  @Test func test_decode_defaultBelowItsRange_failsAtLoad() {
    #expect(
      throws: SettingsCatalogError.defaultInvalid(key: "demo.limit", reason: .belowMinimum(1))
    ) {
      _ = try SettingsCatalog.decode(from: catalogData(integerSetting(defaultValue: 0)))
    }
  }

  @Test func test_decode_unknownType_failsAtLoad() {
    let data = catalogData(
      #"{"key":"demo.ratio","type":"float","default":1,"scopes":["global"],"description":"x"}"#)

    #expect(throws: SettingsCatalogError.unknownType(key: "demo.ratio", type: "float")) {
      _ = try SettingsCatalog.decode(from: data)
    }
  }

  @Test func test_decode_duplicateKey_failsAtLoad() {
    #expect(throws: SettingsCatalogError.duplicateKey("demo.limit")) {
      _ = try SettingsCatalog.decode(from: catalogData(integerSetting(), integerSetting()))
    }
  }

  @Test func test_decode_enumDefaultNotInItsValues_failsAtLoad() {
    let data = catalogData(
      #"{"key":"demo.mode","type":"enum","default":"idle","values":["fast","slow"],"scopes":["global"],"description":"x"}"#
    )

    #expect(
      throws: SettingsCatalogError.defaultInvalid(
        key: "demo.mode", reason: .notAllowed(["fast", "slow"]))
    ) {
      _ = try SettingsCatalog.decode(from: data)
    }
  }

  @Test func test_decode_booleanDefaultOfWrongType_failsAtLoad() {
    let data = catalogData(
      #"{"key":"demo.flag","type":"boolean","default":1,"scopes":["global"],"description":"x"}"#)

    #expect(
      throws: SettingsCatalogError.defaultInvalid(
        key: "demo.flag", reason: .typeMismatch(expected: .boolean))
    ) {
      _ = try SettingsCatalog.decode(from: data)
    }
  }

  @Test func test_decode_unknownScope_failsAtLoad() {
    #expect(throws: SettingsCatalogError.unknownScope(key: "demo.limit", scope: "session")) {
      _ = try SettingsCatalog.decode(
        from: catalogData(integerSetting(scopes: #"["global","session"]"#)))
    }
  }

  @Test func test_decode_malformedJson_failsAtLoad() {
    #expect(throws: SettingsCatalogError.self) {
      _ = try SettingsCatalog.decode(from: Data("not json".utf8))
    }
  }
}

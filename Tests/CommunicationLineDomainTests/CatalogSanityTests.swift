import CommunicationLineDomain
import Foundation
import Testing

/// A catalog that loads must describe settings that can exist: bounds that leave room, at least one
/// scope, values for an enum, and no field that does not belong to the type.
@Suite struct CatalogSanityTests {
  @Test func test_decode_minimumAboveMaximum_failsAtLoad() {
    let data = catalogData(integerSetting(defaultValue: 5, range: #""range":{"min":10,"max":1},"#))

    #expect(throws: SettingsCatalogError.minimumAboveMaximum(key: "demo.limit")) {
      _ = try SettingsCatalog.decode(from: data)
    }
  }

  @Test func test_decode_emptyScopeList_failsAtLoad() {
    let data = catalogData(integerSetting(scopes: "[]"))

    #expect(throws: SettingsCatalogError.noScopes(key: "demo.limit")) {
      _ = try SettingsCatalog.decode(from: data)
    }
  }

  @Test func test_decode_enumWithoutValues_failsAtLoad() {
    let data = catalogData(
      #"{"key":"demo.mode","type":"enum","default":"fast","values":[],"scopes":["global"],"description":"x"}"#
    )

    #expect(throws: SettingsCatalogError.enumWithoutValues(key: "demo.mode")) {
      _ = try SettingsCatalog.decode(from: data)
    }
  }

  @Test func test_decode_enumWithMissingValuesField_failsAtLoad() {
    let data = catalogData(
      #"{"key":"demo.mode","type":"enum","default":"fast","scopes":["global"],"description":"x"}"#)

    #expect(throws: SettingsCatalogError.enumWithoutValues(key: "demo.mode")) {
      _ = try SettingsCatalog.decode(from: data)
    }
  }

  @Test func test_decode_rangeOnABoolean_failsAtLoad() {
    let data = catalogData(
      #"{"key":"demo.flag","type":"boolean","default":true,"range":{"min":0,"max":1},"scopes":["global"],"description":"x"}"#
    )

    #expect(throws: SettingsCatalogError.rangeOnNonNumericType(key: "demo.flag")) {
      _ = try SettingsCatalog.decode(from: data)
    }
  }

  @Test func test_decode_valuesOnAnInteger_failsAtLoad() {
    let data = catalogData(
      #"{"key":"demo.limit","type":"integer","default":5,"values":["a"],"scopes":["global"],"description":"x"}"#
    )

    #expect(throws: SettingsCatalogError.valuesOnNonEnumType(key: "demo.limit")) {
      _ = try SettingsCatalog.decode(from: data)
    }
  }
}

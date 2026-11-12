import CommunicationLineDomain
import Foundation
import Testing

@Suite struct SettingValueValidationTests {
  private func definition(_ setting: String) throws -> SettingDefinition {
    let catalog = try SettingsCatalog.decode(from: catalogData(setting))
    return try #require(catalog.definitions.first)
  }

  @Test func test_validate_integerInsideRange_isAccepted() throws {
    let limit = try definition(integerSetting())

    try limit.validate(.integer(1))
    try limit.validate(.integer(10))
  }

  @Test func test_validate_integerOutsideRange_isRejectedWithTheBound() throws {
    let limit = try definition(integerSetting())

    #expect(throws: SettingValueError.belowMinimum(1)) { try limit.validate(.integer(0)) }
    #expect(throws: SettingValueError.aboveMaximum(10)) { try limit.validate(.integer(11)) }
  }

  @Test func test_validate_wrongType_isRejected() throws {
    let limit = try definition(integerSetting())

    #expect(throws: SettingValueError.typeMismatch(expected: .integer)) {
      try limit.validate(.boolean(true))
    }
    #expect(throws: SettingValueError.typeMismatch(expected: .integer)) {
      try limit.validate(.text("5"))
    }
  }

  @Test func test_validate_enumValue_mustBeListed() throws {
    let mode = try definition(
      #"{"key":"demo.mode","type":"enum","default":"fast","values":["fast","slow"],"scopes":["global"],"description":"x"}"#
    )

    try mode.validate(.text("slow"))
    #expect(throws: SettingValueError.notAllowed(["fast", "slow"])) {
      try mode.validate(.text("idle"))
    }
  }

  @Test func test_validate_openEndedRange_checksOnlyTheGivenBound() throws {
    let budget = try definition(
      #"{"key":"demo.bytes","type":"bytes","default":100,"range":{"min":1},"scopes":["global"],"description":"x"}"#
    )

    try budget.validate(.integer(Int64.max))
    #expect(throws: SettingValueError.belowMinimum(1)) { try budget.validate(.integer(0)) }
  }
}

import CommunicationLineDomain
import Testing

@Suite struct SettingResolutionTests {
  private func limit(scopes: String = #"["global","family","principal"]"#) throws
    -> SettingDefinition
  {
    let catalog = try SettingsCatalog.decode(from: catalogData(integerSetting(scopes: scopes)))
    return try #require(catalog.definitions.first)
  }

  @Test func test_effectiveValue_principalBeatsFamilyBeatsGlobalBeatsDefault() throws {
    let definition = try limit()

    #expect(
      definition.effectiveValue(principal: .integer(1), family: .integer(2), global: .integer(3))
        == .integer(1), "principal wins")
    #expect(
      definition.effectiveValue(principal: nil, family: .integer(2), global: .integer(3))
        == .integer(2), "family wins when there is no principal value")
    #expect(
      definition.effectiveValue(principal: nil, family: nil, global: .integer(3)) == .integer(3),
      "global wins when there is no narrower value")
    #expect(
      definition.effectiveValue(principal: nil, family: nil, global: nil) == .integer(5),
      "the default applies when nothing is set")
  }

  @Test func test_effectiveValue_ignoresScopesTheKeyDoesNotAllow() throws {
    let definition = try limit(scopes: #"["global"]"#)

    #expect(
      definition.effectiveValue(principal: .integer(1), family: .integer(2), global: .integer(3))
        == .integer(3), "a stored principal or family value is ignored for a global-only key")
  }
}

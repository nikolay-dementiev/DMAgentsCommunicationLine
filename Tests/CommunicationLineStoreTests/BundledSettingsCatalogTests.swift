import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct BundledSettingsCatalogTests {
  @Test func test_shippedCatalog_holdsTheV01KeysWithTheSpecifiedDefaults() throws {
    let catalog = try BundledSettingsCatalogSource.shipped.load()
    let defaults = Dictionary(
      uniqueKeysWithValues: catalog.definitions.map { ($0.key, $0.defaultValue) })

    #expect(
      defaults == [
        "store.busy_timeout": .integer(5000),
        "retention.messages.live": .integer(90),
        "storage.budget": .integer(5_000_000_000),
        "storage.warning_percent": .integer(80),
        "health.threshold": .integer(1800),
        "messaging.wait": .integer(900),
        "messaging.subject_max": .integer(512),
        "messaging.body_max": .integer(262_144),
        "messaging.page_size": .integer(100),
      ], "the shipped keys and defaults")
  }

  @Test func test_shippedCatalog_rangesFollowTheSpecification() throws {
    let catalog = try BundledSettingsCatalogSource.shipped.load()

    #expect(
      catalog.definition(for: "storage.warning_percent")?.range
        == SettingRange(minimum: 1, maximum: 98), "warning percent is 1..98")
    #expect(
      catalog.definition(for: "health.threshold")?.range
        == SettingRange(minimum: 60, maximum: 86400), "threshold is 60..86400")
    #expect(
      catalog.definition(for: "messaging.wait")?.range
        == SettingRange(minimum: 0, maximum: 900), "wait is 0..900")
    #expect(
      catalog.definition(for: "messaging.page_size")?.range
        == SettingRange(minimum: 1, maximum: 100), "page size is 1..100")
    #expect(
      catalog.definition(for: "messaging.subject_max")?.range
        == SettingRange(minimum: 1, maximum: 512), "subject limit is capped at 512")
    #expect(
      catalog.definition(for: "messaging.body_max")?.range
        == SettingRange(minimum: 1, maximum: 262_144), "body limit is capped at 262144")
    #expect(
      catalog.definition(for: "health.threshold")?.scopes == [.global, .family, .principal],
      "the overdue threshold is settable per family and per principal")
  }

  @Test func test_load_missingResource_isReported() {
    let source = BundledSettingsCatalogSource(bundle: .main, resourceName: "no-such-defaults")

    #expect(throws: StoreError.missingResource("no-such-defaults.json")) {
      _ = try source.load()
    }
  }
}

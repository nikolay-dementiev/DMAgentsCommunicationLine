import CommunicationLineDomain
import Foundation

/// Reads the settings catalog from the defaults resource shipped in this package.
public struct BundledSettingsCatalogSource {
  private let bundle: Bundle
  private let resourceName: String

  public init(bundle: Bundle, resourceName: String) {
    self.bundle = bundle
    self.resourceName = resourceName
  }

  /// The defaults resource of this package, the only place a shipped tunable number is written.
  public static var shipped: BundledSettingsCatalogSource {
    BundledSettingsCatalogSource(bundle: .module, resourceName: "settings-defaults")
  }

  public func load() throws -> SettingsCatalog {
    guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
      throw StoreError.missingResource("\(resourceName).json")
    }
    return try SettingsCatalog.decode(from: try Data(contentsOf: url))
  }
}

import Foundation

/// What the install wrote on the host, so that uninstall removes that and nothing else.
public struct Manifest: Codable, Equatable, Sendable {
  public enum Registration: Codable, Equatable, Sendable {
    case launchAgent(label: String, userID: UInt32)
  }

  public var version = 1
  /// Absolute paths of the files to remove. The store folder is never listed: it holds the data.
  public var files: [String]
  public var registrations: [Registration]
  public var storeFolder: String

  public init(files: [String], registrations: [Registration], storeFolder: String) {
    self.files = files
    self.registrations = registrations
    self.storeFolder = storeFolder
  }

  public static func read(from url: URL) throws -> Manifest {
    try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
}

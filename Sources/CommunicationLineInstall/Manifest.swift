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

  /// Replaces the manifest file in one step. It holds paths only, so it is private to the owner.
  public func write(to url: URL) throws {
    try HostFiles.replace(try encoded(), at: url, mode: 0o600)
  }

  func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return try encoder.encode(self)
  }
}

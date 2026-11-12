/// One numbered schema step. The statements of a migration run in a single transaction together with
/// the update of the schema version.
public struct Migration: Equatable, Sendable {
  public let version: Int
  public let statements: [String]

  public init(version: Int, statements: [String]) {
    self.version = version
    self.statements = statements
  }
}

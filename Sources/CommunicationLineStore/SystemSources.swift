import CommunicationLineApplication
import CommunicationLineDomain
import Foundation
import Security

/// Random bytes from the system's secure generator.
public struct SecureRandomSource: RandomSource {
  public init() {}

  public func randomBytes(count: Int) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    guard status == errSecSuccess else { throw StoreError.randomUnavailable(status: status) }
    return bytes
  }
}

/// Principal ids that are random UUIDs.
public struct UUIDIdentifierSource: IdentifierSource {
  public init() {}

  public func newPrincipalID() -> PrincipalID {
    PrincipalID(UUID().uuidString.lowercased())
  }
}

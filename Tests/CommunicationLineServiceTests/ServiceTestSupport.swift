import CommunicationLineService
import CommunicationLineWire
import Foundation

/// A service runtime on a real store in a short folder under /tmp: a socket path is limited to about
/// a hundred bytes, which the usual per-test temporary folders exceed.
final class ServiceFixture: @unchecked Sendable {
  let folder: URL
  let runtime: ServiceRuntime

  init() throws {
    let name = "cl-" + UUID().uuidString.prefix(8).lowercased()
    folder = URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true)
    runtime = try ServiceRuntime.open(storeFolder: folder)
  }

  deinit {
    try? FileManager.default.removeItem(at: folder)
  }

  func call(_ operation: String, token: String? = nil, _ arguments: [String: WireValue] = [:])
    -> WireResponse
  {
    runtime.dispatcher.handle(
      WireRequest(token: token, operation: operation, arguments: arguments))
  }

  /// The owner token of a fresh store.
  func bootstrapOwner() throws -> String {
    try string(call("owner.credential"), "token")
  }

  /// Creates a principal and issues its credential; returns its id and token.
  func enrol(owner: String, family: String, name: String, role: String = "agent") throws
    -> (id: String, token: String)
  {
    let created = call(
      "principal.create", token: owner,
      ["family": .string(family), "role": .string(role), "name": .string(name)])
    let id = try string(created, "id")
    let issued = call("credential.issue", token: owner, ["principal": .string(id)])
    return (id, try string(issued, "token"))
  }

  func string(_ response: WireResponse, _ key: String) throws -> String {
    guard case .object(let fields)? = response.result, case .string(let value)? = fields[key]
    else { throw FixtureError.missing(key, response) }
    return value
  }

  func field(_ response: WireResponse, _ key: String) throws -> WireValue {
    guard case .object(let fields)? = response.result, let value = fields[key] else {
      throw FixtureError.missing(key, response)
    }
    return value
  }
}

enum FixtureError: Error {
  case missing(String, WireResponse)
}

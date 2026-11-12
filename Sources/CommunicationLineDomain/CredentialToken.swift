import CryptoKit
import Foundation

/// A 256-bit secret that authenticates a caller. The product shows it once, when it is issued, and
/// keeps only its digest.
public struct CredentialToken: Sendable {
  public static let byteCount = 32
  private let bytes: [UInt8]

  public init?(bytes: [UInt8]) {
    guard bytes.count == Self.byteCount else { return nil }
    self.bytes = bytes
  }

  /// Parses the base64url form without padding that `encoded` produces.
  public init?(encoded: String) {
    var text = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
      of: "_", with: "/")
    guard encoded.count == 43, !encoded.contains("="), !encoded.contains("+"),
      !encoded.contains("/")
    else { return nil }
    text += "="
    guard let data = Data(base64Encoded: text) else { return nil }
    self.init(bytes: [UInt8](data))
  }

  /// Base64url without padding: 43 characters.
  public var encoded: String {
    Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  public var digest: TokenDigest {
    TokenDigest(SHA256.hash(data: bytes))
  }
}

extension CredentialToken: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { "CredentialToken(redacted)" }
  public var debugDescription: String { description }
}

/// The SHA-256 digest of a token; what the store keeps. Comparison takes the same time wherever
/// two digests differ.
public struct TokenDigest: Equatable, Sendable {
  public static let byteCount = 32
  public let bytes: [UInt8]

  public init?(bytes: [UInt8]) {
    guard bytes.count == Self.byteCount else { return nil }
    self.bytes = bytes
  }

  init(_ digest: SHA256.Digest) {
    bytes = Array(digest)
  }

  public init?(hex: String) {
    guard hex.count == Self.byteCount * 2, hex.allSatisfy(\.isHexDigit) else { return nil }
    var parsed: [UInt8] = []
    var index = hex.startIndex
    while index < hex.endIndex {
      let next = hex.index(index, offsetBy: 2)
      guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
      parsed.append(byte)
      index = next
    }
    self.init(bytes: parsed)
  }

  public var hex: String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  public static func == (left: TokenDigest, right: TokenDigest) -> Bool {
    guard left.bytes.count == right.bytes.count else { return false }
    var difference: UInt8 = 0
    for position in 0..<left.bytes.count {
      difference |= left.bytes[position] ^ right.bytes[position]
    }
    return difference == 0
  }
}

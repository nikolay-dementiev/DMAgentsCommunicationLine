import CommunicationLineDomain
import Foundation
import Testing

@Suite struct CredentialTokenTests {
  private let zeros = [UInt8](repeating: 0, count: 32)

  @Test(arguments: [0, 31, 33, 64])
  func test_init_wrongByteCount_isRejected(count: Int) {
    #expect(
      CredentialToken(bytes: [UInt8](repeating: 7, count: count)) == nil,
      "a token is exactly 256 bits, not \(count * 8)")
  }

  @Test func test_encoded_roundTripsAndHasNoPadding() throws {
    let bytes = (0..<32).map { UInt8($0 * 8) }
    let token = try #require(CredentialToken(bytes: bytes), "32 bytes make a token")

    #expect(token.encoded.count == 43, "32 bytes in base64url without padding are 43 characters")
    #expect(!token.encoded.contains("="), "no padding")
    #expect(
      CredentialToken(encoded: token.encoded)?.encoded == token.encoded,
      "the encoded form parses back to the same token")
  }

  @Test(arguments: ["", "short", "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!", "AAAA"])
  func test_initEncoded_invalidText_isRejected(text: String) {
    #expect(CredentialToken(encoded: text) == nil, "'\(text)' is not an encoded token")
  }

  @Test func test_digest_isSHA256OfTheTokenBytes() throws {
    let token = try #require(CredentialToken(bytes: zeros))

    #expect(
      token.digest.hex == "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925",
      "the digest is the SHA-256 of the 32 token bytes")
  }

  @Test func test_description_neverShowsTheToken() throws {
    let token = try #require(CredentialToken(bytes: zeros))

    #expect(!"\(token)".contains(token.encoded), "description hides the token")
    #expect(!String(reflecting: token).contains(token.encoded), "debug description hides it too")
  }

  @Test func test_digestEquality_detectsADifferenceAtEveryPosition() throws {
    let base = try #require(CredentialToken(bytes: zeros)).digest

    #expect(base == base, "a digest equals itself")
    for position in 0..<32 {
      var bytes = base.bytes
      bytes[position] ^= 0x01
      let changed = try #require(TokenDigest(bytes: bytes))
      #expect(base != changed, "a difference in byte \(position) is detected")
    }
  }

  @Test func test_digestHex_roundTripsAndRejectsBadText() throws {
    let digest = try #require(CredentialToken(bytes: zeros)).digest

    #expect(TokenDigest(hex: digest.hex) == digest, "hex round trip")
    #expect(TokenDigest(hex: "zz") == nil, "not hex")
    #expect(
      TokenDigest(hex: "+" + String(repeating: "a", count: 63)) == nil,
      "a sign is not a hex digit")
    #expect(TokenDigest(hex: String(digest.hex.dropLast(2))) == nil, "too short")
    #expect(TokenDigest(bytes: [1, 2, 3]) == nil, "wrong length")
  }
}

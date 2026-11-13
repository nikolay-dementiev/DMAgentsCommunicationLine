import CommunicationLineWire
import Foundation
import Testing

struct WireMessageTests {
  @Test func test_request_roundTripsWithNestedArguments() throws {
    let request = WireRequest(
      token: "abc", operation: "send",
      arguments: [
        "to": .array([.string("p1"), .string("p2")]), "limit": .integer(7),
        "flag": .bool(true), "none": .null, "nested": .object(["k": .string("v")]),
      ])

    let decoded = try WireCoding.decodeRequest(try WireCoding.encode(request))

    #expect(decoded == request, "every value kind survives a round trip")
  }

  @Test func test_request_withoutAToken_decodesWithNoToken() throws {
    let decoded = try WireCoding.decodeRequest(Data(#"{"op":"inbox"}"#.utf8))

    #expect(decoded.token == nil, "a missing token is nil, not an empty string")
    #expect(decoded.arguments.isEmpty, "missing arguments are empty")
    #expect(decoded.operation == "inbox", "the operation name is read from the key op")
  }

  @Test func test_request_withoutAnOperation_isRefused() {
    #expect(throws: WireError.malformed) {
      _ = try WireCoding.decodeRequest(Data(#"{"token":"t"}"#.utf8))
    }
  }

  @Test func test_request_withAFractionalNumber_isRefused() {
    #expect(throws: WireError.malformed) {
      _ = try WireCoding.decodeRequest(Data(#"{"op":"x","args":{"n":1.5}}"#.utf8))
    }
  }

  @Test func test_request_thatIsNotJson_isRefused() {
    #expect(throws: WireError.malformed) {
      _ = try WireCoding.decodeRequest(Data("not json".utf8))
    }
  }

  @Test func test_response_success_roundTrips() throws {
    let response = WireResponse.success(.object(["id": .string("m1")]))

    let decoded = try WireCoding.decodeResponse(try WireCoding.encode(response))

    #expect(decoded == response, "a success carries its result")
    #expect(decoded.isSuccess, "ok is true")
  }

  @Test func test_response_failure_roundTripsWithItsCode() throws {
    let response = WireResponse.failure(code: .recipientRefused, message: "no")

    let decoded = try WireCoding.decodeResponse(try WireCoding.encode(response))

    #expect(decoded == response, "a failure carries its code and message")
    #expect(!decoded.isSuccess, "ok is false")
  }

  @Test func test_response_thatContradictsItself_isRefused() {
    for json in [
      #"{"ok":true,"error":{"code":"internal","message":"m"}}"#,
      #"{"ok":false}"#,
      #"{"ok":true}"#,
      #"{"ok":false,"result":{},"error":{"code":"internal","message":"m"}}"#,
    ] {
      #expect(throws: WireError.malformed, "refused: \(json)") {
        _ = try WireCoding.decodeResponse(Data(json.utf8))
      }
    }
  }

  @Test func test_errorCodes_haveTheDocumentedStableNames() {
    let names = WireErrorCode.allCases.map(\.rawValue)

    #expect(
      names == [
        "bad_request", "frame_too_large", "token_required", "unknown_token", "token_revoked",
        "principal_disabled", "owner_required", "agent_required", "unknown_principal",
        "unknown_recipient", "recipient_refused", "message_unavailable", "unknown_grant",
        "unknown_key", "invalid_name", "invalid_rule", "invalid_page_limit", "invalid_setting",
        "no_recipients", "too_many_recipients", "recipient_inbox_full", "too_many_waiters",
        "subject_too_large", "body_too_large", "expiry_in_the_past",
        "scope_not_allowed", "subject_required", "subject_not_allowed", "invalid_value",
        "internal",
      ], "the code names are a contract: they change only with a protocol change")
  }

  @Test func test_everyErrorCode_belongsToOneClass() {
    #expect(
      WireErrorCode.unknownToken.errorClass == .authentication, "a bad token is authentication")
    #expect(WireErrorCode.ownerRequired.errorClass == .permission, "owner only is permission")
    #expect(
      WireErrorCode.recipientRefused.errorClass == .permission, "a refused send is permission")
    #expect(
      WireErrorCode.unknownPrincipal.errorClass == .notFound, "unknown principal is not found")
    #expect(WireErrorCode.bodyTooLarge.errorClass == .invalidInput, "a limit is invalid input")
    #expect(WireErrorCode.badRequest.errorClass == .request, "a malformed request is request")
    #expect(
      WireErrorCode.tooManyRecipients.errorClass == .invalidInput, "a message that is too wide")
    #expect(
      WireErrorCode.recipientInboxFull.errorClass == .request,
      "a full inbox is not the caller's input")
    #expect(WireErrorCode.tooManyWaiters.errorClass == .request, "parking is busy")
    #expect(WireErrorCode.internal.errorClass == .internal, "internal is internal")
  }

  @Test func test_deeplyNestedFrames_areMalformedAndNeverOverflowTheStack() {
    let depth = 200_000
    let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    let request = Data("{\"op\":\"x\",\"args\":{\"a\":\(nested)}}".utf8)
    let response = Data("{\"ok\":true,\"result\":\(nested)}".utf8)

    #expect(throws: WireError.malformed, "a request nested far past any real one is refused") {
      _ = try WireCoding.decodeRequest(request)
    }
    #expect(throws: WireError.malformed, "a response nested far past any real one is refused") {
      _ = try WireCoding.decodeResponse(response)
    }
  }

  @Test func test_nestingInsideAString_doesNotCountAsDepth() throws {
    let brackets = String(repeating: "[", count: 500)
    let request = Data("{\"op\":\"x\",\"args\":{\"a\":\"\(brackets)\"}}".utf8)

    let decoded = try WireCoding.decodeRequest(request)

    #expect(decoded.operation == "x", "brackets inside a string are text, not structure")
  }

  @Test func test_nestingBeyondTheLimit_isRefusedWhileRealNestingStillPasses() throws {
    func request(depth: Int) -> Data {
      let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
      return Data("{\"op\":\"x\",\"args\":{\"a\":\(nested)}}".utf8)
    }

    #expect(throws: WireError.malformed, "64 levels is past the nesting limit") {
      _ = try WireCoding.decodeRequest(request(depth: 64))
    }
    let allowed = try WireCoding.decodeRequest(request(depth: 8))
    #expect(allowed.operation == "x", "a few levels of nesting are ordinary")
  }

  @Test func test_nestingAtExactlyTheLimit_isAccepted_andOneLevelMoreIsRefused() throws {
    // The request object is level 1 and its arguments object is level 2; the arrays add the rest.
    func request(totalDepth: Int) -> Data {
      let arrays = totalDepth - 2
      let nested = String(repeating: "[", count: arrays) + String(repeating: "]", count: arrays)
      return Data("{\"op\":\"x\",\"args\":{\"a\":\(nested)}}".utf8)
    }
    let limit = WireCoding.maximumDepth

    let atLimit = try WireCoding.decodeRequest(request(totalDepth: limit))
    #expect(atLimit.operation == "x", "a request nested exactly \(limit) levels deep is accepted")
    #expect(throws: WireError.malformed, "one level past the limit is refused") {
      _ = try WireCoding.decodeRequest(request(totalDepth: limit + 1))
    }
  }
}

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
        "no_recipients", "subject_too_large", "body_too_large", "expiry_in_the_past",
        "scope_not_allowed", "subject_required", "subject_not_allowed", "invalid_value",
        "internal",
      ], "the code names are a contract: they change only with a protocol change")
  }

  @Test func test_everyErrorCode_belongsToOneClass() {
    #expect(WireErrorCode.unknownToken.errorClass == .authentication, "a bad token is authentication")
    #expect(WireErrorCode.ownerRequired.errorClass == .permission, "owner only is permission")
    #expect(WireErrorCode.recipientRefused.errorClass == .permission, "a refused send is permission")
    #expect(WireErrorCode.unknownPrincipal.errorClass == .notFound, "unknown principal is not found")
    #expect(WireErrorCode.bodyTooLarge.errorClass == .invalidInput, "a limit is invalid input")
    #expect(WireErrorCode.badRequest.errorClass == .request, "a malformed request is request")
    #expect(WireErrorCode.internal.errorClass == .internal, "internal is internal")
  }
}

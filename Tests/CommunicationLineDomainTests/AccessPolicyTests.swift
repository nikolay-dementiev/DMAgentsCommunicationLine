import CommunicationLineDomain
import Foundation
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let past = now.addingTimeInterval(-60)
private let future = now.addingTimeInterval(3600)

private func make(
  _ id: String, _ family: String, _ role: RoleKind = .agent, enabled: Bool = true
) -> Principal {
  Principal(
    id: PrincipalID(id), family: family, role: role, displayName: id, isEnabled: enabled)
}

private let alpha = make("alpha", "A")
private let alphaPeer = make("alpha-peer", "A")
private let alphaHead = make("alpha-head", "A", .head)
private let beta = make("beta", "B")
private let betaHead = make("beta-head", "B", .head)
private let stranger = make("stranger", "C")

/// A message sent by `alpha` to `beta`, so it belongs to family A.
private let meta = MessageMeta(
  sender: alpha.id, recipients: [beta.id], family: "A")

struct SendCase: CustomTestStringConvertible, Sendable {
  let name: String
  let from: Principal
  let to: Principal
  let rules: [SendRule]
  let allowed: Bool
  var testDescription: String { name }
}

struct ReadCase: CustomTestStringConvertible, Sendable {
  let name: String
  let reader: Principal
  let grants: [ReadGrant]
  let allowed: Bool
  var testDescription: String { name }
}

private let sendCases: [SendCase] = [
  SendCase(name: "same family", from: alpha, to: alphaPeer, rules: [], allowed: true),
  SendCase(name: "other family, no rule", from: alpha, to: beta, rules: [], allowed: false),
  SendCase(
    name: "other family, rule in that direction", from: alpha, to: beta,
    rules: [SendRule(fromFamily: "A", toFamily: "B")], allowed: true),
  SendCase(
    name: "other family, rule only in the other direction", from: beta, to: alpha,
    rules: [SendRule(fromFamily: "A", toFamily: "B")], allowed: false),
  SendCase(
    name: "rule for an unrelated family pair", from: alpha, to: beta,
    rules: [SendRule(fromFamily: "A", toFamily: "C")], allowed: false),
  SendCase(
    name: "same family but the recipient is disabled", from: alpha,
    to: make("off", "A", enabled: false), rules: [], allowed: false),
  SendCase(
    name: "a read grant alone never allows sending", from: stranger, to: alpha, rules: [],
    allowed: false),
]

private let readCases: [ReadCase] = [
  ReadCase(name: "sender", reader: alpha, grants: [], allowed: true),
  ReadCase(name: "original recipient", reader: beta, grants: [], allowed: true),
  ReadCase(name: "head of the sender's family", reader: alphaHead, grants: [], allowed: true),
  ReadCase(name: "head of another family", reader: betaHead, grants: [], allowed: false),
  ReadCase(name: "agent of the sender's family", reader: alphaPeer, grants: [], allowed: false),
  ReadCase(name: "unrelated principal", reader: stranger, grants: [], allowed: false),
  ReadCase(
    name: "disabled sender", reader: make("alpha", "A", enabled: false), grants: [],
    allowed: false),
  ReadCase(
    name: "named grant", reader: stranger,
    grants: [
      ReadGrant(reader: .principal(stranger.id), target: .global, expiresAt: nil, isRevoked: false)
    ],
    allowed: true),
  ReadCase(
    name: "family grant", reader: stranger,
    grants: [ReadGrant(reader: .family("C"), target: .global, expiresAt: nil, isRevoked: false)],
    allowed: true),
  ReadCase(
    name: "grant for another principal", reader: stranger,
    grants: [
      ReadGrant(reader: .principal(alphaPeer.id), target: .global, expiresAt: nil, isRevoked: false)
    ],
    allowed: false),
  ReadCase(
    name: "grant for another family", reader: stranger,
    grants: [ReadGrant(reader: .family("A"), target: .global, expiresAt: nil, isRevoked: false)],
    allowed: false),
  ReadCase(
    name: "grant not yet expired", reader: stranger,
    grants: [
      ReadGrant(
        reader: .principal(stranger.id), target: .global, expiresAt: future, isRevoked: false)
    ],
    allowed: true),
  ReadCase(
    name: "expired grant", reader: stranger,
    grants: [
      ReadGrant(reader: .principal(stranger.id), target: .global, expiresAt: past, isRevoked: false)
    ],
    allowed: false),
  ReadCase(
    name: "grant expiring exactly now", reader: stranger,
    grants: [
      ReadGrant(reader: .principal(stranger.id), target: .global, expiresAt: now, isRevoked: false)
    ],
    allowed: false),
  ReadCase(
    name: "revoked grant", reader: stranger,
    grants: [
      ReadGrant(reader: .principal(stranger.id), target: .global, expiresAt: nil, isRevoked: true)
    ],
    allowed: false),
  ReadCase(
    name: "family target: the sender's family", reader: stranger,
    grants: [
      ReadGrant(
        reader: .principal(stranger.id), target: .family("A"), expiresAt: nil, isRevoked: false)
    ], allowed: true),
  ReadCase(
    name: "family target: the recipient's family is not the sender's family", reader: stranger,
    grants: [
      ReadGrant(
        reader: .principal(stranger.id), target: .family("B"), expiresAt: nil, isRevoked: false)
    ], allowed: false),
  ReadCase(
    name: "family target: an unrelated family", reader: stranger,
    grants: [
      ReadGrant(
        reader: .principal(stranger.id), target: .family("C"), expiresAt: nil, isRevoked: false)
    ], allowed: false),
  ReadCase(
    name: "principal target: the sender", reader: stranger,
    grants: [
      ReadGrant(
        reader: .principal(stranger.id), target: .principal(alpha.id), expiresAt: nil,
        isRevoked: false)
    ], allowed: true),
  ReadCase(
    name: "principal target: a recipient", reader: stranger,
    grants: [
      ReadGrant(
        reader: .principal(stranger.id), target: .principal(beta.id), expiresAt: nil,
        isRevoked: false)
    ], allowed: true),
  ReadCase(
    name: "principal target: someone the message does not concern", reader: stranger,
    grants: [
      ReadGrant(
        reader: .principal(stranger.id), target: .principal(alphaPeer.id), expiresAt: nil,
        isRevoked: false)
    ], allowed: false),
  ReadCase(
    name: "a family reader with a family target of another family", reader: stranger,
    grants: [
      ReadGrant(reader: .family("C"), target: .family("B"), expiresAt: nil, isRevoked: false)
    ], allowed: false),
  ReadCase(
    name: "revoked grant next to a valid one", reader: stranger,
    grants: [
      ReadGrant(reader: .principal(stranger.id), target: .global, expiresAt: nil, isRevoked: true),
      ReadGrant(reader: .family("C"), target: .global, expiresAt: nil, isRevoked: false),
    ], allowed: true),
]

@Suite struct AccessPolicyTests {
  @Test(arguments: sendCases)
  func test_canSend_matrix(_ scenario: SendCase) {
    #expect(
      AccessPolicy.canSend(from: scenario.from, to: scenario.to, rules: scenario.rules)
        == scenario.allowed,
      "\(scenario.name)")
  }

  @Test(arguments: readCases)
  func test_canRead_matrix(_ scenario: ReadCase) {
    #expect(
      AccessPolicy.canRead(
        principal: scenario.reader, meta: meta, grants: scenario.grants, now: now)
        == scenario.allowed,
      "\(scenario.name)")
  }

  @Test func test_familyTargetGrant_doesNotOpenAMessageOfAnotherFamily() {
    let otherFamilyMessage = MessageMeta(
      sender: stranger.id, recipients: [stranger.id], family: "C")
    let grants = [
      ReadGrant(
        reader: .principal(alpha.id), target: .family("B"), expiresAt: nil, isRevoked: false)
    ]

    #expect(
      !AccessPolicy.canRead(
        principal: alpha, meta: otherFamilyMessage, grants: grants, now: now),
      "a grant whose target is family B gives nothing on a message of family C")
  }

  @Test func test_readGrant_neverChangesWhoMaySend() {
    let grants = [
      ReadGrant(reader: .principal(stranger.id), target: .global, expiresAt: nil, isRevoked: false)
    ]

    #expect(
      AccessPolicy.canRead(principal: stranger, meta: meta, grants: grants, now: now),
      "the grant lets the stranger read")
    #expect(
      !AccessPolicy.canSend(from: stranger, to: alpha, rules: []),
      "the same grant gives no right to send")
  }
}

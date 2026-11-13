import CommunicationLineWire
import Foundation
import Testing

struct DispatcherAgentTests {
  private struct World {
    let fixture: ServiceFixture
    let owner: String
    let alice: (id: String, token: String)
    let bob: (id: String, token: String)
    let carol: (id: String, token: String)
  }

  /// alice and bob share a family; carol is in another one.
  private func makeWorld() throws -> World {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    return World(
      fixture: fixture, owner: owner,
      alice: try fixture.enrol(owner: owner, family: "A", name: "alice"),
      bob: try fixture.enrol(owner: owner, family: "A", name: "bob"),
      carol: try fixture.enrol(owner: owner, family: "B", name: "carol"))
  }

  private func send(_ world: World, from token: String, to ids: [String], _ subject: String = "s")
    -> WireResponse
  {
    world.fixture.call(
      "send", token: token,
      ["to": .array(ids.map { .string($0) }), "subject": .string(subject), "body": .string("b")])
  }

  @Test func test_sendInboxReadAcknowledge_followTheLifeOfOneMessage() throws {
    let world = try makeWorld()
    let fixture = world.fixture

    let sent = send(world, from: world.alice.token, to: [world.bob.id], "hello")
    let messageID = try fixture.string(sent, "id")

    let inbox = fixture.call("inbox", token: world.bob.token)
    guard case .array(let entries) = try fixture.field(inbox, "entries"),
      case .object(let entry)? = entries.first
    else {
      Issue.record("the inbox lists one entry")
      return
    }
    #expect(entry["id"] == .string(messageID), "the entry names the message")
    #expect(entry["sender"] == .string(world.alice.id), "the entry names the sender")
    #expect(entry["subject"] == .string("hello"), "the entry carries the subject")
    #expect(try fixture.field(inbox, "next") == .null, "one short page has no next cursor")

    let read = fixture.call("read", token: world.bob.token, ["id": .string(messageID)])
    #expect(try fixture.string(read, "body") == "b", "read returns the body")
    #expect(try fixture.string(read, "family") == "A", "read names the sender's family")
    #expect(
      fixture.call("inbox", token: world.bob.token).result != nil
        && (try fixture.field(fixture.call("inbox", token: world.bob.token), "entries"))
          != .array([]),
      "read does not acknowledge")

    let acknowledged = fixture.call(
      "acknowledge", token: world.bob.token, ["id": .string(messageID)])
    #expect(acknowledged.isSuccess, "acknowledge succeeds")
    #expect(
      try fixture.field(fixture.call("inbox", token: world.bob.token), "entries") == .array([]),
      "an acknowledged message leaves the inbox")
  }

  @Test func test_send_acrossFamiliesNeedsARule_andARefusalIsAnError() throws {
    let world = try makeWorld()

    let refused = send(world, from: world.alice.token, to: [world.carol.id])
    #expect(!refused.isSuccess, "a refused send is not a success")
    #expect(refused.failure?.code == .recipientRefused, "it names the reason")
    #expect(refused.result == nil, "a failure carries no result")

    _ = world.fixture.call(
      "rule.add", token: world.owner, ["from": .string("A"), "to": .string("B")])
    #expect(
      send(world, from: world.alice.token, to: [world.carol.id]).isSuccess, "the rule opens it")
  }

  @Test func test_send_toAnUnknownPrincipalOrWithoutRecipientsOrTooMuchText_isRefused() throws {
    let world = try makeWorld()

    #expect(
      send(world, from: world.alice.token, to: ["ghost"]).failure?.code == .unknownRecipient,
      "unknown recipient")
    #expect(
      send(world, from: world.alice.token, to: []).failure?.code == .noRecipients,
      "no recipients")
    _ = world.fixture.call(
      "setting.set", token: world.owner,
      ["key": .string("messaging.subject_max"), "value": .integer(3)])
    #expect(
      send(world, from: world.alice.token, to: [world.bob.id], "four").failure?.code
        == .subjectTooLarge, "subject over the limit")
  }

  @Test func test_read_ofAnotherPairsMessage_isUnavailable() throws {
    let world = try makeWorld()
    let sent = send(world, from: world.alice.token, to: [world.bob.id])
    let messageID = try world.fixture.string(sent, "id")

    let response = world.fixture.call(
      "read", token: world.carol.token, ["id": .string(messageID)])

    #expect(response.failure?.code == .messageUnavailable, "a stranger cannot read it")
  }

  @Test func test_inbox_pagesByTheCatalogPageSize() throws {
    let world = try makeWorld()
    _ = world.fixture.call(
      "setting.set", token: world.owner,
      ["key": .string("messaging.page_size"), "value": .integer(2)])
    for index in 0..<3 {
      _ = send(world, from: world.alice.token, to: [world.bob.id], "m\(index)")
    }

    let first = world.fixture.call("inbox", token: world.bob.token)
    guard case .array(let firstEntries) = try world.fixture.field(first, "entries"),
      case .integer(let cursor) = try world.fixture.field(first, "next")
    else {
      Issue.record("a full page has a next cursor")
      return
    }
    #expect(firstEntries.count == 2, "the page holds the catalog page size")
    let second = world.fixture.call("inbox", token: world.bob.token, ["after": .integer(cursor)])
    guard case .array(let secondEntries) = try world.fixture.field(second, "entries") else {
      Issue.record("the second page lists entries")
      return
    }
    #expect(secondEntries.count == 1, "the rest follows the cursor")
  }

  @Test func test_wait_reportsPendingMailAtOnce_andTimesOutWhenThereIsNone() throws {
    let world = try makeWorld()

    let empty = world.fixture.call("wait", token: world.bob.token, ["timeout": .integer(0)])
    #expect(try world.fixture.string(empty, "outcome") == "timeout", "nothing pending")

    _ = send(world, from: world.alice.token, to: [world.bob.id])
    let pending = world.fixture.call("wait", token: world.bob.token, ["timeout": .integer(0)])
    #expect(try world.fixture.string(pending, "outcome") == "mail", "pending mail ends the wait")
  }

  @Test func test_wait_isWokenByASendFromAnotherThread() throws {
    let world = try makeWorld()
    nonisolated(unsafe) var outcome = ""
    let finished = DispatchSemaphore(value: 0)
    let fixture = world.fixture
    let bobToken = world.bob.token
    Thread.detachNewThread {
      let response = fixture.call("wait", token: bobToken, ["timeout": .integer(30)])
      outcome = (try? fixture.string(response, "outcome")) ?? "error"
      finished.signal()
    }
    Thread.sleep(forTimeInterval: 0.3)

    _ = send(world, from: world.alice.token, to: [world.bob.id])

    #expect(finished.wait(timeout: .now() + 10) == .success, "the waiter woke well before 30 s")
    #expect(outcome == "mail", "it woke because mail arrived")
  }

  @Test func test_token_isTakenFromTheRequestBodyOnly() throws {
    let world = try makeWorld()

    let response = world.fixture.call(
      "inbox", token: nil, ["token": .string(world.bob.token)])

    #expect(response.failure?.code == .tokenRequired, "a token in the arguments is not a token")
  }

  @Test func test_badRequests_areReportedAsBadRequest() throws {
    let world = try makeWorld()
    let token = world.alice.token

    #expect(
      world.fixture.call("no.such.op", token: token).failure?.code == .badRequest,
      "unknown operation")
    #expect(
      world.fixture.call("send", token: token, ["subject": .string("s")]).failure?.code
        == .badRequest, "missing argument")
    #expect(
      world.fixture.call("read", token: token, ["id": .integer(3)]).failure?.code == .badRequest,
      "wrong argument type")
    #expect(
      world.fixture.call("inbox", token: "garbage").failure?.code == .unknownToken,
      "a token that is not a token")
  }
}

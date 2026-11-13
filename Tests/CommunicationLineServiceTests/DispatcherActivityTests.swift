import CommunicationLineService
import CommunicationLineWire
import Foundation
import Testing

struct DispatcherActivityTests {
  private struct Record {
    let actor: String
    let operation: String
    let outcome: String
    let targets: [String]
  }

  private struct World {
    let fixture: ServiceFixture
    let owner: String
    let alice: (id: String, token: String)
    let bob: (id: String, token: String)
  }

  private func makeWorld() throws -> World {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    return World(
      fixture: fixture, owner: owner,
      alice: try fixture.enrol(owner: owner, family: "A", name: "alice"),
      bob: try fixture.enrol(owner: owner, family: "A", name: "bob"))
  }

  /// All records through `activity.list`, in order.
  private func records(_ world: World, owner: String? = nil) throws -> [Record] {
    var found: [Record] = []
    var cursor: Int64?
    repeat {
      var arguments: [String: WireValue] = ["limit": .integer(50)]
      if let cursor { arguments["after"] = .integer(cursor) }
      let page = world.fixture.call("activity.list", token: owner ?? world.owner, arguments)
      guard case .array(let items) = try world.fixture.field(page, "records") else { break }
      for case .object(let item) in items {
        guard case .string(let actor)? = item["actor"],
          case .string(let operation)? = item["operation"],
          case .string(let outcome)? = item["outcome"], case .array(let targets)? = item["targets"]
        else { continue }
        found.append(
          Record(
            actor: actor, operation: operation, outcome: outcome,
            targets: targets.compactMap { if case .string(let text) = $0 { text } else { nil } }))
      }
      if case .integer(let next)? =
        (page.result.flatMap { value -> WireValue? in
          if case .object(let fields) = value { return fields["next"] } else { return nil }
        })
      {
        cursor = next
      } else {
        cursor = nil
      }
    } while cursor != nil
    return found
  }

  private func send(_ world: World, subject: String = "s", body: String = "b") -> WireResponse {
    world.fixture.call(
      "send", token: world.alice.token,
      ["to": .array([.string(world.bob.id)]), "subject": .string(subject), "body": .string(body)])
  }

  @Test func test_everyRequest_leavesOneRecordWithItsActorOperationAndTargets() throws {
    let world = try makeWorld()
    let sent = send(world)
    let messageID = try world.fixture.string(sent, "id")

    let all = try records(world)

    #expect(
      all.map(\.operation) == [
        "owner.credential", "principal.create", "credential.issue", "principal.create",
        "credential.issue", "send",
      ], "one record per request, in order")
    #expect(all[0].actor == "unauthenticated", "the bootstrap has no token yet")
    #expect(all[1].actor == "owner", "owner operations are by the owner")
    #expect(all[1].targets == [world.alice.id], "the created principal is the target")
    #expect(all[2].targets == [world.alice.id], "the credential belongs to the principal")
    #expect(all[5].actor == "principal:" + world.alice.id, "the sender is the actor")
    #expect(all[5].targets == [messageID, world.bob.id], "the message and the recipient")
    #expect(all.allSatisfy { $0.outcome == "ok" }, "every request so far succeeded")
  }

  @Test func test_aRefusedRequest_isRecordedWithItsErrorCode() throws {
    let world = try makeWorld()

    let refused = world.fixture.call(
      "rule.add", token: world.bob.token, ["from": .string("A"), "to": .string("B")])
    let bad = world.fixture.call("inbox", token: String(repeating: "A", count: 43))
    let unknown = world.fixture.call("frobnicate-secret-name")
    let all = try records(world)

    #expect(refused.failure?.code == .ownerRequired, "the request itself is still refused")
    #expect(bad.failure?.code == .unknownToken, "an unknown token is refused")
    let recorded = all.suffix(3).map { "\($0.actor)|\($0.operation)|\($0.outcome)" }
    #expect(
      recorded == [
        "principal:\(world.bob.id)|rule.add|owner_required", "unauthenticated|inbox|unknown_token",
        "unauthenticated|unknown|bad_request",
      ], "refusals leave a record with the error code, and unknown names are not copied")
  }

  @Test func test_theOwnerCredentialReplacement_isRecorded() throws {
    let world = try makeWorld()

    let replaced = world.fixture.call("owner.credential", token: world.owner)
    let stolen = world.fixture.call("owner.credential")
    let all = try records(world, owner: try world.fixture.string(replaced, "token"))

    #expect(replaced.isSuccess, "the owner replaces the credential")
    #expect(stolen.failure?.code == .ownerRequired, "a second bootstrap is refused")
    #expect(
      all.suffix(2).map { "\($0.actor)|\($0.operation)|\($0.outcome)" } == [
        "owner|owner.credential|ok", "unauthenticated|owner.credential|owner_required",
      ], "both the replacement and the refused attempt are on record")
  }

  @Test func test_theLog_neverHoldsATokenASubjectOrABody() throws {
    let world = try makeWorld()
    let sent = send(world, subject: "SECRET-SUBJECT-4711", body: "SECRET-BODY-4711")
    let id = try world.fixture.string(sent, "id")
    _ = world.fixture.call("read", token: world.bob.token, ["id": .string(id)])

    let dump = try RawFile(folder: world.fixture.folder).activityDump()

    #expect(!dump.contains("SECRET-SUBJECT-4711"), "no subject")
    #expect(!dump.contains("SECRET-BODY-4711"), "no body")
    for token in [world.owner, world.alice.token, world.bob.token] {
      #expect(!dump.contains(String(token.prefix(12))), "no token or part of one")
    }
  }

  @Test func test_anEffect_neverCommitsWithoutItsRecord() throws {
    let world = try makeWorld()
    let raw = try RawFile(folder: world.fixture.folder)
    try raw.execute(
      """
      CREATE TRIGGER block_send_records BEFORE INSERT ON activity WHEN NEW.operation = 'send'
      BEGIN SELECT RAISE(ABORT, 'blocked'); END
      """)

    let sent = send(world)
    let inbox = world.fixture.call("inbox", token: world.bob.token)

    #expect(sent.failure?.code == .internal, "the send fails when its record cannot be written")
    guard case .array(let entries) = try world.fixture.field(inbox, "entries") else {
      Issue.record("the inbox answers with a list")
      return
    }
    #expect(entries.isEmpty, "the message was not delivered without its record")
  }

  @Test func test_aWait_isRecordedAfterItEnds() throws {
    let world = try makeWorld()

    _ = world.fixture.call("wait", token: world.bob.token, ["timeout": .integer(0)])

    #expect(try records(world).last?.operation == "wait", "a finished wait is on record")
  }

  @Test func test_activityList_isOwnerOnly_andPaged() throws {
    let world = try makeWorld()
    _ = send(world)

    let refused = world.fixture.call("activity.list", token: world.alice.token)
    let first = world.fixture.call("activity.list", token: world.owner, ["limit": .integer(2)])
    let bad = world.fixture.call("activity.list", token: world.owner, ["limit": .integer(0)])

    #expect(refused.failure?.code == .ownerRequired, "an agent cannot read the log")
    guard case .array(let items) = try world.fixture.field(first, "records") else {
      Issue.record("records is a list")
      return
    }
    #expect(items.count == 2, "the page holds the asked number of records")
    #expect(
      {
        if case .object(let fields)? = first.result {
          return fields["next"] != nil
        } else {
          return false
        }
      }(),
      "more records follow, so there is a cursor")
    #expect(bad.failure?.code == .invalidPageLimit, "a zero limit is refused")
  }
}

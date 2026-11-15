import CommunicationLineService
import CommunicationLineWire
import Foundation
import Testing

struct DispatcherFloodTests {
  private struct World {
    let fixture: ServiceFixture
    let owner: String
    let alice: (id: String, token: String)
    let bob: (id: String, token: String)
    let raw: RawFile
  }

  private func makeWorld() throws -> World {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    return World(
      fixture: fixture, owner: owner,
      alice: try fixture.enrol(owner: owner, family: "A", name: "alice"),
      bob: try fixture.enrol(owner: owner, family: "A", name: "bob"),
      raw: try RawFile(folder: fixture.folder))
  }

  /// The activity lines (`actor|operation|outcome|targets`) of one outcome.
  private func lines(_ world: World, outcome: String) throws -> [String] {
    try world.raw.activityDump().split(separator: "\n").map(String.init).filter {
      $0.split(separator: "|", omittingEmptySubsequences: false)[2] == outcome
    }
  }

  private func refuse(_ world: World, times: Int, token: String = "not-a-token") {
    for _ in 0..<times { _ = world.fixture.call("send", token: token, [:]) }
  }

  @Test func test_manyRefusalsWithTheSameOutcome_leaveOneRecordInsideTheWindow() throws {
    let world = try makeWorld()

    refuse(world, times: 20)

    #expect(
      try lines(world, outcome: "unknown_token").count == 1,
      "twenty refused requests of one outcome write one activity record in the window")
  }

  @Test func test_theFirstRecordAfterTheWindow_carriesTheNumberSuppressed() throws {
    let world = try makeWorld()
    refuse(world, times: 5)
    world.fixture.clock.advance(seconds: 61)

    refuse(world, times: 1)

    let recorded = try lines(world, outcome: "unknown_token")
    #expect(recorded.count == 2, "a second record is written once the window has passed")
    #expect(
      recorded.last?.hasSuffix("|[\"suppressed:4\"]") == true,
      "it says how many were left out: \(recorded.last ?? "none")")
  }

  @Test func test_refusalsWithDifferentOutcomes_areRecordedSeparately() throws {
    let world = try makeWorld()

    refuse(world, times: 3)
    for _ in 0..<3 { _ = world.fixture.call("health", token: world.alice.token) }

    #expect(try lines(world, outcome: "unknown_token").count == 1, "one for the bad token")
    #expect(try lines(world, outcome: "owner_required").count == 1, "one for the wrong role")
  }

  @Test func test_repeatedNotFoundRefusals_leaveOneRecordInsideTheWindow() throws {
    let world = try makeWorld()

    for _ in 0..<6 {
      _ = world.fixture.call(
        "send", token: world.alice.token,
        [
          "to": .array([.string(UUID().uuidString.lowercased())]), "subject": .string("s"),
          "body": .string("b"),
        ])
    }

    #expect(
      try lines(world, outcome: "unknown_recipient").count == 1,
      "a refusal of the not-found class is throttled like the others")
  }

  @Test func test_successfulRequests_areAllRecorded() throws {
    let world = try makeWorld()

    for index in 0..<5 {
      _ = world.fixture.call(
        "send", token: world.alice.token,
        [
          "to": .array([.string(world.bob.id)]), "subject": .string("s\(index)"),
          "body": .string("b"),
        ])
    }

    #expect(try lines(world, outcome: "ok").filter { $0.contains("|send|") }.count == 5)
  }

  @Test func test_aWindowOfZero_recordsEveryRefusalAsBefore() throws {
    let world = try makeWorld()
    let changed = world.fixture.call(
      "setting.set", token: world.owner,
      ["key": .string("limits.activity.refusal_window"), "value": .integer(0)])
    #expect(changed.isSuccess, "the window can be turned off by the owner")

    refuse(world, times: 4)

    #expect(try lines(world, outcome: "unknown_token").count == 4, "no suppression at zero")
  }
}

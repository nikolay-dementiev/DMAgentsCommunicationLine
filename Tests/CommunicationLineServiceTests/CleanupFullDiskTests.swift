import CommunicationLineService
import CommunicationLineWire
import Foundation
import Testing

/// Collects what the service reports to its log.
private final class SpyReporter: FailureReporter, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []

  var operations: [String] { lock.withLock { stored } }

  func report(_ error: any Error, operation: String) {
    lock.withLock { stored.append(operation) }
  }
}

/// Runs a hook at the moment a failure is reported, to put another event inside that moment.
private final class HookedReporter: FailureReporter, @unchecked Sendable {
  private let lock = NSLock()
  private var hook: (@Sendable () -> Void)?

  func onReport(_ hook: @escaping @Sendable () -> Void) { lock.withLock { self.hook = hook } }

  func report(_ error: any Error, operation: String) {
    let pending = lock.withLock { () -> (@Sendable () -> Void)? in
      defer { hook = nil }
      return hook
    }
    pending?()
  }
}

/// A write that fails is injected as a trigger on the activity table of the one record under test.
struct CleanupFullDiskTests {
  private struct World {
    let fixture: ServiceFixture
    let owner: String
    let alice: (id: String, token: String)
    let bob: (id: String, token: String)
    let raw: RawFile
    let reporter: SpyReporter
  }

  private func makeWorld() throws -> World {
    let reporter = SpyReporter()
    let fixture = try ServiceFixture(reporter: reporter)
    let owner = try fixture.bootstrapOwner()
    return World(
      fixture: fixture, owner: owner,
      alice: try fixture.enrol(owner: owner, family: "A", name: "alice"),
      bob: try fixture.enrol(owner: owner, family: "A", name: "bob"),
      raw: try RawFile(folder: fixture.folder), reporter: reporter)
  }

  private func refuseRecords(of operation: String, in world: World) throws {
    try world.raw.execute(
      """
      CREATE TRIGGER no_record BEFORE INSERT ON activity
      WHEN NEW.operation = '\(operation)'
      BEGIN SELECT RAISE(ABORT, 'database or disk is full'); END
      """)
  }

  /// One message from alice to bob, acknowledged by bob and old enough for cleanup to delete.
  private func ageAcknowledgedMail(_ world: World) throws {
    let sent = world.fixture.call(
      "send", token: world.alice.token,
      ["to": .array([.string(world.bob.id)]), "subject": .string("s"), "body": .string("b")])
    _ = world.fixture.call(
      "acknowledge", token: world.bob.token, ["id": .string(try world.fixture.string(sent, "id"))])
    world.fixture.clock.advance(days: 91)
  }

  private func warnings(_ world: World) throws -> [WireValue] {
    let health = world.fixture.call("health", token: world.owner)
    guard case .array(let items) = try world.fixture.field(health, "warnings") else { return [] }
    return items
  }

  @Test func test_aCleanupWhoseOwnRecordCannotBeWritten_stillDeletes() throws {
    let world = try makeWorld()
    try ageAcknowledgedMail(world)
    try refuseRecords(of: "health.cleanup", in: world)

    let response = world.fixture.call("health.cleanup", token: world.owner)

    #expect(response.isSuccess, "the run is reported: its deletions are real")
    #expect(try world.raw.count("messages") == 0, "the deletions are committed")
    #expect(
      world.reporter.operations.contains("record activity"),
      "the lost record is reported to the log: \(world.reporter.operations)")
  }

  @Test func test_aCleanupWhoseOwnRecordCannotBeWritten_isTheLastCleanup_andHealthSaysSo() throws {
    let world = try makeWorld()
    try ageAcknowledgedMail(world)
    try refuseRecords(of: "health.cleanup", in: world)

    _ = world.fixture.call("health.cleanup", token: world.owner)
    let health = world.fixture.call("health", token: world.owner)

    guard case .object(let last) = try world.fixture.field(health, "last_cleanup") else {
      Issue.record("the run that deleted is remembered")
      return
    }
    #expect(last["messages"] == .integer(1), "the report holds what the run deleted")
    #expect(
      try warnings(world).contains(.string("cleanup_not_recorded")),
      "health says that the record of the run is missing")
  }

  @Test func test_theWarning_goesAwayWithTheNextCleanupThatIsRecorded() throws {
    let world = try makeWorld()
    try refuseRecords(of: "health.cleanup", in: world)
    _ = world.fixture.call("health.cleanup", token: world.owner)
    try world.raw.execute("DROP TRIGGER no_record")

    _ = world.fixture.call("health.cleanup", token: world.owner)

    #expect(
      try !warnings(world).contains(.string("cleanup_not_recorded")),
      "a cleanup with its record in the log clears the warning")
  }

  @Test func test_aScheduledRunBetweenTheCleanupAndItsLostRecord_isNotMarkedAsUnrecorded() throws {
    let reporter = HookedReporter()
    let fixture = try ServiceFixture(reporter: reporter)
    let owner = try fixture.bootstrapOwner()
    let raw = try RawFile(folder: fixture.folder)
    try raw.execute(
      """
      CREATE TRIGGER no_record BEFORE INSERT ON activity
      WHEN NEW.operation = 'health.cleanup'
      BEGIN SELECT RAISE(ABORT, 'database or disk is full'); END
      """)
    // The scheduled run lands while the owner's record is being given up.
    reporter.onReport { _ = try? fixture.runtime.cleanup.run() }

    _ = fixture.call("health.cleanup", token: owner)
    let health = fixture.call("health", token: owner)

    guard case .array(let warnings) = try fixture.field(health, "warnings") else {
      Issue.record("health lists its warnings")
      return
    }
    #expect(
      !warnings.contains(.string("cleanup_not_recorded")),
      "the last run is the scheduled one, and its record is not missing")
  }

  @Test func test_aWaitThatFoundMail_isNotTurnedIntoAnErrorByItsRecord() throws {
    let world = try makeWorld()
    _ = world.fixture.call(
      "send", token: world.alice.token,
      ["to": .array([.string(world.bob.id)]), "subject": .string("s"), "body": .string("b")])
    try refuseRecords(of: "wait", in: world)

    let response = world.fixture.call("wait", token: world.bob.token)

    #expect(response.isSuccess, "the mail was found: the wait answers with it")
    #expect(
      try world.fixture.field(response, "outcome") == .string("mail"), "and it says there is mail")
    #expect(
      world.reporter.operations.contains("record activity"),
      "the lost record is reported to the log: \(world.reporter.operations)")
  }
}

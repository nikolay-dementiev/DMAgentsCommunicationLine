import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

/// A listening state the test sets by hand, to describe a principal that has mail and a parked
/// wait at the same time.
private struct FixedListening: ListeningRegistry {
  let principals: Set<PrincipalID>

  func listeningSince(_ principal: PrincipalID) -> Date? {
    principals.contains(principal) ? Date(timeIntervalSince1970: 1_800_000_000) : nil
  }

  func listeningPrincipals() -> Set<PrincipalID> { principals }
}

@Suite struct HealthFamilyTests {
  private struct Fixture {
    let world: MessagingFixture

    init() throws {
      world = try MessagingFixture()
      try world.rights.allowSending(from: "A", to: "B", ownerToken: world.owner)
    }

    func health(listening: Set<PrincipalID> = []) -> HealthService {
      let store = world.identity.store
      let cleanup = CleanupRunner(
        service: CleanupService(
          store: SQLiteRetentionStore(store: store), settings: world.settings,
          transactions: SQLiteTransactionRunner(store: store), clock: world.clock),
        clock: world.clock)
      return HealthService(
        store: SQLiteHealthStore(store: store), settings: world.settings,
        storage: StorageService(store: SQLiteStorageStore(store: store), settings: world.settings),
        cleanup: cleanup, identity: world.identity.service,
        directory: DirectoryService(
          store: SQLiteDirectoryStore(store: store), identity: world.identity.service,
          listening: FixedListening(principals: listening)),
        listening: FixedListening(principals: listening), clock: world.clock,
        startedAt: world.clock.now())
    }

    func report(_ service: HealthService, family: String? = nil) throws -> HealthReport {
      try service.report(ownerToken: world.owner, family: family)
    }

    func advance(seconds: TimeInterval) {
      world.clock.instant = world.clock.instant.addingTimeInterval(seconds)
    }
  }

  // MARK: - The family filter

  @Test func test_withAFamily_pendingAndOverdueKeepOnlyItsRecipients() throws {
    let fixture = try Fixture()
    let world = fixture.world
    try world.mail(from: world.alphaToken, to: world.alphaPeer, "for alpha")
    try world.mail(from: world.alphaToken, to: world.beta, "for beta")
    fixture.advance(seconds: 3600)

    let alpha = try fixture.report(fixture.health(), family: "A")
    let everyone = try fixture.report(fixture.health())

    #expect(alpha.pending.map(\.principal) == [world.alphaPeer.id], "only the family's recipient")
    #expect(alpha.overdueCount == 1, "the overdue delivery of the other family is not counted")
    #expect(alpha.overdue.map(\.recipient) == [world.alphaPeer.id], "nor listed")
    #expect(everyone.overdueCount == 2, "without a family both are counted, as in v0.1")
  }

  @Test func test_withAFamily_storageAndLastCleanupStayGlobal() throws {
    let fixture = try Fixture()
    let service = fixture.health()

    let scoped = try fixture.report(service, family: "A")
    let everyone = try fixture.report(service)

    #expect(scoped.storage == everyone.storage, "the database is one for every family")
    #expect(scoped.startedAt == everyone.startedAt, "so is the start of the service")
    #expect(scoped.warnings == everyone.warnings, "and the warnings")
    #expect(scoped.lastCleanup == everyone.lastCleanup, "and the last cleanup")
  }

  @Test func test_aFamilyWithNoPrincipal_isRefused() throws {
    let fixture = try Fixture()

    #expect(throws: IdentityError.unknownFamily("Nobody")) {
      _ = try fixture.report(fixture.health(), family: "Nobody")
    }
  }

  // MARK: - Not listening with pending

  @Test func test_aRecipientWithMailAndNoParkedWait_isCounted() throws {
    let fixture = try Fixture()
    let world = fixture.world
    try world.mail(from: world.alphaToken, to: world.alphaPeer, "one")
    try world.mail(from: world.alphaToken, to: world.alphaHead, "two")

    let report = try fixture.report(fixture.health())

    #expect(report.notListeningWithPending == 2, "two principals have mail and nobody waits")
  }

  @Test func test_aRecipientThatIsListening_isNotCounted() throws {
    let fixture = try Fixture()
    let world = fixture.world
    try world.mail(from: world.alphaToken, to: world.alphaPeer, "one")
    try world.mail(from: world.alphaToken, to: world.alphaHead, "two")

    let report = try fixture.report(fixture.health(listening: [world.alphaPeer.id]))

    #expect(report.notListeningWithPending == 1, "only the head is deaf to its mail")
  }

  @Test func test_whenTheOnlyRecipientIsListening_theCountIsZero() throws {
    let fixture = try Fixture()
    let world = fixture.world
    try world.mail(from: world.alphaToken, to: world.alphaPeer, "one")

    let report = try fixture.report(fixture.health(listening: [world.alphaPeer.id]))

    #expect(report.notListeningWithPending == 0, "it has mail, but a wait is parked for it")
  }

  @Test func test_aListeningPrincipalWithNoMail_isNotCounted() throws {
    let fixture = try Fixture()
    let world = fixture.world

    let report = try fixture.report(fixture.health(listening: [world.alphaPeer.id]))

    #expect(report.notListeningWithPending == 0, "no mail, nothing to be deaf to")
  }

  @Test func test_withAFamily_theCountKeepsOnlyItsRecipients() throws {
    let fixture = try Fixture()
    let world = fixture.world
    try world.mail(from: world.alphaToken, to: world.alphaPeer, "for alpha")
    try world.mail(from: world.alphaToken, to: world.beta, "for beta")

    let alpha = try fixture.report(fixture.health(), family: "A")
    let everyone = try fixture.report(fixture.health())

    #expect(alpha.notListeningWithPending == 1, "only alpha's recipient")
    #expect(everyone.notListeningWithPending == 2, "both families without the option")
  }
}

import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct ActivityStoreTests {
  private struct Boom: Error {}

  private struct Fixture {
    let identity: IdentityFixture
    let activity: SQLiteActivityStore
    let transactions: SQLiteTransactionRunner

    init() throws {
      identity = try IdentityFixture()
      activity = SQLiteActivityStore(store: identity.store)
      transactions = SQLiteTransactionRunner(store: identity.store)
    }

    func entry(
      _ operation: String, actor: ActivityActor = .owner, outcome: String = "ok",
      targets: [String] = [], at seconds: TimeInterval = 100
    ) -> NewActivity {
      NewActivity(
        at: Date(timeIntervalSince1970: seconds), actor: actor, operation: operation,
        outcome: outcome, targets: targets)
    }
  }

  @Test func test_schema_versionFourCreatesTheActivityTable() throws {
    let fixture = try Fixture()

    #expect(SchemaMigrations.all.map(\.version) == [1, 2, 3, 4], "four numbered steps")
    #expect(try fixture.identity.raw().tableExists("activity"), "the activity table exists")
  }

  @Test func test_appendedRecords_areListedInOrderWithEveryField() throws {
    let fixture = try Fixture()
    try fixture.activity.append(
      fixture.entry("send", actor: .principal(PrincipalID("p1")), targets: ["m1", "p2"], at: 5))
    try fixture.activity.append(
      fixture.entry("rule.add", actor: .unauthenticated, outcome: "owner_required", at: 6))
    try fixture.activity.append(fixture.entry("health", actor: .owner, at: 7))

    let page = try fixture.activity.page(after: nil, limit: 10)

    #expect(page.records.map(\.operation) == ["send", "rule.add", "health"], "oldest first")
    #expect(page.records[0].actor == .principal(PrincipalID("p1")), "a principal actor")
    #expect(page.records[0].targets == ["m1", "p2"], "targets keep their order")
    #expect(page.records[0].at == Date(timeIntervalSince1970: 5), "the time comes from the entry")
    #expect(page.records[1].actor == .unauthenticated, "an unauthenticated actor")
    #expect(page.records[1].outcome == "owner_required", "the outcome is the error code")
    #expect(page.records[2].actor == .owner, "the owner actor")
    #expect(page.next == nil, "everything fit on one page")
  }

  @Test func test_pages_followTheCursorWithoutGapsOrRepeats() throws {
    let fixture = try Fixture()
    for index in 1...5 { try fixture.activity.append(fixture.entry("op\(index)")) }

    let first = try fixture.activity.page(after: nil, limit: 2)
    let second = try fixture.activity.page(after: first.next, limit: 2)
    let third = try fixture.activity.page(after: second.next, limit: 2)

    #expect(first.records.map(\.operation) == ["op1", "op2"], "first page")
    #expect(first.next != nil, "more records follow the first page")
    #expect(second.records.map(\.operation) == ["op3", "op4"], "second page")
    #expect(third.records.map(\.operation) == ["op5"], "last page")
    #expect(third.next == nil, "no cursor after the last page")
  }

  @Test func test_aRecord_cannotBeChangedOrDeleted() throws {
    let fixture = try Fixture()
    try fixture.activity.append(fixture.entry("send"))
    let raw = try fixture.identity.raw()

    #expect(throws: RawDatabaseError.self, "an update is refused") {
      try raw.execute("UPDATE activity SET outcome = 'ok2'")
    }
    #expect(throws: RawDatabaseError.self, "a delete outside retention is refused") {
      try raw.execute("DELETE FROM activity")
    }
    #expect(try raw.integer("SELECT count(*) FROM activity") == 1, "the record is still there")
  }

  @Test func test_aRecord_cannotBeReplacedByAnInsert() throws {
    let fixture = try Fixture()
    try fixture.activity.append(fixture.entry("send"))
    let raw = try fixture.identity.raw()

    #expect(throws: RawDatabaseError.self, "a replacing insert is refused") {
      try raw.execute(
        """
        INSERT OR REPLACE INTO activity (id, at_ms, actor, operation, outcome, targets)
        VALUES (1, 99, 'forged', 'send', 'ok', '[]')
        """)
    }
    #expect(
      try raw.integer("SELECT count(*) FROM activity WHERE actor = 'forged'") == 0,
      "the stored record was not rewritten")
  }

  @Test func test_aFailedTransaction_takesItsRecordsWithIt() throws {
    let fixture = try Fixture()

    #expect(throws: Boom.self) {
      try fixture.transactions.atomically {
        try fixture.activity.append(fixture.entry("send"))
        throw Boom()
      }
    }

    #expect(
      try fixture.activity.page(after: nil, limit: 10).records.isEmpty,
      "the record is rolled back with the transaction")
  }

  @Test func test_aNestedTransaction_joinsTheOuterOne() throws {
    let fixture = try Fixture()

    #expect(throws: Boom.self) {
      try fixture.transactions.atomically {
        try fixture.transactions.atomically { try fixture.activity.append(fixture.entry("inner")) }
        throw Boom()
      }
    }
    try fixture.transactions.atomically {
      try fixture.transactions.atomically { try fixture.activity.append(fixture.entry("kept")) }
    }

    #expect(
      try fixture.activity.page(after: nil, limit: 10).records.map(\.operation) == ["kept"],
      "the inner work rolls back with the outer, and commits with it")
  }

  @Test func test_aFailedInnerTransaction_leavesTheOuterOneUsable() throws {
    let fixture = try Fixture()

    try fixture.transactions.atomically {
      do {
        try fixture.transactions.atomically {
          try fixture.activity.append(fixture.entry("lost"))
          throw Boom()
        }
      } catch is Boom {}
      try fixture.activity.append(fixture.entry("kept"))
    }

    #expect(
      try fixture.activity.page(after: nil, limit: 10).records.map(\.operation) == ["kept"],
      "only the failed inner part is undone")
  }
}

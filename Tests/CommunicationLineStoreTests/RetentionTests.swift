import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct RetentionTests {
  private let day: TimeInterval = 86_400

  private struct Fixture {
    let world: MessagingFixture
    let cleanup: CleanupService
    let activity: SQLiteActivityStore

    init() throws {
      world = try MessagingFixture()
      let store = world.identity.store
      cleanup = CleanupService(
        store: SQLiteRetentionStore(store: store), settings: world.settings,
        transactions: SQLiteTransactionRunner(store: store), clock: world.clock)
      activity = SQLiteActivityStore(store: store)
    }

    func advance(days: Double) {
      world.clock.instant = world.clock.instant.addingTimeInterval(days * 86_400)
    }

    func setting(_ key: String, to value: Int64) throws {
      _ = try world.settings.change(
        SettingAddress(key: key, scope: .global, subject: nil), to: .integer(value),
        ownerToken: world.owner)
    }

    /// Sends one message from alpha to its peer; acknowledges it when asked.
    func mail(acknowledged: Bool) throws -> MessageID {
      let id = try world.mail(from: world.alphaToken, to: world.alphaPeer)
      if acknowledged { try world.messages.acknowledge(token: world.alphaPeerToken, messageID: id) }
      return id
    }
  }

  @Test func test_acknowledgedMail_insideTheRetentionWindow_isKept() throws {
    let fixture = try Fixture()
    _ = try fixture.mail(acknowledged: true)
    fixture.advance(days: 89)

    let result = try fixture.cleanup.run()

    #expect(result == CleanupResult(deliveries: 0, messages: 0, activity: 0), "nothing is due yet")
    #expect(try fixture.world.count("messages") == 1, "the message is still stored")
  }

  @Test func test_acknowledgedMail_pastTheRetentionWindow_isDeletedWithItsMessage() throws {
    let fixture = try Fixture()
    _ = try fixture.mail(acknowledged: true)
    fixture.advance(days: 91)

    let result = try fixture.cleanup.run()

    #expect(result == CleanupResult(deliveries: 1, messages: 1, activity: 0), "what was deleted")
    #expect(try fixture.world.count("deliveries") == 0, "the delivery is gone")
    #expect(try fixture.world.count("messages") == 0, "the message without deliveries is gone")
  }

  @Test func test_acknowledgedMail_atExactlyTheRetentionAge_isKept_andOneMillisecondLaterIsDeleted()
    throws
  {
    let fixture = try Fixture()
    _ = try fixture.mail(acknowledged: true)
    fixture.advance(days: 90)

    let onTheDay = try fixture.cleanup.run()
    fixture.advance(days: 0.001 / 86_400)
    let afterIt = try fixture.cleanup.run()

    #expect(onTheDay.deliveries == 0, "exactly 90 days old is not older than 90 days")
    #expect(afterIt.deliveries == 1, "one millisecond past the window it is due")
  }

  @Test func test_activity_atExactlyTheRetentionAge_isKept_andOneMillisecondLaterIsDeleted() throws
  {
    let fixture = try Fixture()
    let now = fixture.world.clock.instant
    try fixture.activity.append(
      NewActivity(
        at: now.addingTimeInterval(-90 * 86_400), actor: .owner, operation: "edge",
        outcome: "ok", targets: []))

    let onTheDay = try fixture.cleanup.run()
    fixture.advance(days: 0.001 / 86_400)
    let afterIt = try fixture.cleanup.run()

    #expect(onTheDay.activity == 0, "exactly 90 days old is kept")
    #expect(afterIt.activity == 1, "one millisecond later it is deleted")
  }

  @Test func test_pendingMail_isNeverDeleted_howeverOldItIs() throws {
    let fixture = try Fixture()
    _ = try fixture.mail(acknowledged: false)
    fixture.advance(days: 5000)

    let result = try fixture.cleanup.run()

    #expect(result == CleanupResult(deliveries: 0, messages: 0, activity: 0), "nothing deleted")
    #expect(try fixture.world.count("deliveries") == 1, "the pending delivery stays")
    #expect(try fixture.world.count("messages") == 1, "and so does its message")
  }

  @Test func test_aMessageWithOnePendingRecipient_keepsItsMessage() throws {
    let fixture = try Fixture()
    let world = fixture.world
    let id = try world.messages.send(
      token: world.alphaToken, to: [world.alphaPeer.id, world.alphaHead.id], subject: "s",
      body: "b")
    try world.messages.acknowledge(token: world.alphaPeerToken, messageID: id)
    fixture.advance(days: 91)

    let result = try fixture.cleanup.run()

    #expect(
      result == CleanupResult(deliveries: 0, messages: 0, activity: 0),
      "a delivery stays while another delivery of its message is pending")
    #expect(try world.count("deliveries") == 2, "both deliveries are still stored")
    #expect(try world.count("messages") == 1, "the message still has a pending delivery")
  }

  @Test func test_aMessageGoesOnlyWhenEveryDeliveryIsAcknowledgedAndTheNewestAckIsOldEnough()
    throws
  {
    let fixture = try Fixture()
    let world = fixture.world
    let id = try world.messages.send(
      token: world.alphaToken, to: [world.alphaPeer.id, world.alphaHead.id], subject: "s",
      body: "b")
    try world.messages.acknowledge(token: world.alphaPeerToken, messageID: id)
    fixture.advance(days: 60)
    try world.messages.acknowledge(token: world.alphaHeadToken, messageID: id)
    fixture.advance(days: 40)

    let early = try fixture.cleanup.run()
    fixture.advance(days: 51)
    let late = try fixture.cleanup.run()

    #expect(
      early == CleanupResult(deliveries: 0, messages: 0, activity: 0),
      "the first ack is 100 days old but the newest is 40: the whole message waits")
    #expect(
      late == CleanupResult(deliveries: 2, messages: 1, activity: 0),
      "once the newest ack is past the window both deliveries and the message go")
  }

  @Test func test_theRetentionWindow_followsTheCatalog() throws {
    let fixture = try Fixture()
    try fixture.setting("retention.messages.live", to: 10)
    _ = try fixture.mail(acknowledged: true)
    fixture.advance(days: 9)
    #expect(try fixture.cleanup.run().deliveries == 0, "day 9 is inside a ten day window")

    fixture.advance(days: 2)

    #expect(try fixture.cleanup.run().deliveries == 1, "day 11 is past it")
  }

  @Test func test_oldActivity_isDeleted_recentActivityStays() throws {
    let fixture = try Fixture()
    let now = fixture.world.clock.instant
    func entry(_ name: String, daysAgo: Double) -> NewActivity {
      NewActivity(
        at: now.addingTimeInterval(-daysAgo * 86_400), actor: .owner, operation: name,
        outcome: "ok", targets: [])
    }
    try fixture.activity.append(entry("old", daysAgo: 91))
    try fixture.activity.append(entry("recent", daysAgo: 89))

    let result = try fixture.cleanup.run()

    #expect(result.activity == 1, "one record is past the window")
    #expect(
      try fixture.activity.page(after: nil, limit: 10).records.map(\.operation) == ["recent"],
      "the recent record stays")
    #expect(throws: RawDatabaseError.self, "the log is append-only again after cleanup") {
      try fixture.world.identity.raw().execute("DELETE FROM activity")
    }
  }
}

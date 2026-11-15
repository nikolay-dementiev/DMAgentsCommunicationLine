import Foundation
import Testing

struct OperationsEndToEndTests {
  private let minute: TimeInterval = 60
  private let day: TimeInterval = 86_400

  @Test func test_aDeliveryBecomesOverdue_isAcknowledged_andIsCleanedUpWhileItsActivityStays()
    throws
  {
    let clock = EndToEndClock()
    let world = try EndToEndWorld(clock: clock)
    let alice = try world.enrol(family: "A", name: "alice")
    let bob = try world.enrol(family: "A", name: "bob")
    try world.require(
      world.asOwner(["setting", "set", "retention.activity.live", "365"]), "longer activity")
    let sent = try world.send(from: alice, to: bob, subject: "please look")

    let fresh = try world.require(world.asOwner(["health"]), "health").out
    #expect(fresh.contains("pending: \(bob.id)\t1"), "bob has one pending delivery")
    #expect(fresh.contains("overdue: 0"), "nothing is overdue yet")

    clock.advance(seconds: 31 * minute)
    let late = try world.require(world.asOwner(["health"]), "health").out
    #expect(late.contains("overdue: 1"), "31 minutes without an acknowledgement is overdue")
    #expect(late.contains("\(sent)\t\(bob.id)\t1860s"), "the message, its recipient, its age")

    try world.require(world.run(["acknowledge", sent], token: bob.token), "acknowledge")
    let acknowledged = try world.require(world.asOwner(["health"]), "health").out
    #expect(acknowledged.contains("overdue: 0"), "an acknowledged delivery is not overdue")
    #expect(!acknowledged.contains("pending: \(bob.id)"), "and nobody has anything pending")
    #expect(
      acknowledged.contains("not listening with pending: 0\n"), "so nobody is deaf to mail either")

    clock.advance(seconds: 91 * day)
    let cleanup = try world.require(world.asOwner(["health", "cleanup"]), "cleanup").out
    #expect(cleanup.hasPrefix("deliveries: 1\nmessages: 1\n"), "the mail was deleted: \(cleanup)")
    #expect(try world.inboxIDs(of: bob) == [], "bob's inbox is empty")
    #expect(
      try world.run(["read", sent], token: bob.token).status == 6, "the message itself is gone")
    let kept = try world.require(world.asOwner(["activity", "--limit", "100"]), "activity").out
    #expect(kept.contains("send\tok\t\(sent)"), "the activity of the mail remains")
    let health = try world.require(world.asOwner(["health"]), "health").out
    #expect(health.contains("last cleanup: "), "the report names the last cleanup")
    #expect(health.contains("deliveries=1 messages=1"), "and what it deleted: \(health)")

    clock.advance(seconds: 300 * day)
    try world.require(world.asOwner(["health", "cleanup"]), "second cleanup")
    let gone = try world.require(world.asOwner(["activity", "--limit", "100"]), "activity").out
    #expect(!gone.contains(sent), "activity past its own retention is deleted too")
  }
}

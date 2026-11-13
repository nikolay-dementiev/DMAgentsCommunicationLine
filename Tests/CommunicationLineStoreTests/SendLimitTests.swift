import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct SendLimitTests {
  private func set(_ fixture: MessagingFixture, _ key: String, to value: Int64) throws {
    _ = try fixture.settings.change(
      SettingAddress(key: key, scope: .global, subject: nil), to: .integer(value),
      ownerToken: fixture.owner)
  }

  @Test func test_aMessageToTooManyRecipients_isRefusedAndStoresNothing() throws {
    let fixture = try MessagingFixture()
    try set(fixture, "wire.recipients", to: 1)

    #expect(throws: MessageError.tooManyRecipients(limit: 1, actual: 2)) {
      _ = try fixture.messages.send(
        token: fixture.alphaToken, to: [fixture.alphaPeer.id, fixture.alphaHead.id], subject: "s",
        body: "b")
    }
    #expect(try fixture.count("messages") == 0, "nothing is stored for a refused message")
    _ = try fixture.messages.send(
      token: fixture.alphaToken, to: [fixture.alphaPeer.id], subject: "s", body: "b")
    #expect(try fixture.count("messages") == 1, "a message at the limit is stored")
  }

  @Test func test_aFullInbox_refusesTheSend_andDeletesNothing() throws {
    let fixture = try MessagingFixture()
    try set(fixture, "quota.messages.assigned_per_principal", to: 2)
    try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "one")
    try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "two")

    #expect(throws: MessagingError.recipientInboxFull(fixture.alphaPeer.id, limit: 2)) {
      try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "three")
    }
    #expect(try fixture.count("messages") == 2, "the old mail is still there and no new one is")
    #expect(try fixture.count("deliveries") == 2, "no delivery was dropped to make room")
  }

  @Test func test_oneFullInbox_stopsTheWholeSend() throws {
    let fixture = try MessagingFixture()
    try set(fixture, "quota.messages.assigned_per_principal", to: 1)
    try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "one")

    #expect(throws: MessagingError.recipientInboxFull(fixture.alphaPeer.id, limit: 1)) {
      _ = try fixture.messages.send(
        token: fixture.alphaToken, to: [fixture.alphaHead.id, fixture.alphaPeer.id], subject: "s",
        body: "b")
    }
    #expect(try fixture.count("messages") == 1, "the other recipient did not get it either")
  }

  @Test func test_acknowledging_makesRoomAgain() throws {
    let fixture = try MessagingFixture()
    try set(fixture, "quota.messages.assigned_per_principal", to: 1)
    let first = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "one")

    try fixture.messages.acknowledge(token: fixture.alphaPeerToken, messageID: first)

    try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "two")
    #expect(try fixture.count("messages") == 2, "only pending mail counts against the limit")
  }
}

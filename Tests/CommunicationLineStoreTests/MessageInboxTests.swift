import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct MessageInboxTests {
  // MARK: - Inbox

  @Test func test_inbox_listsTheCallersPendingMailOldestFirst_andNobodyElses() throws {
    let fixture = try MessagingFixture()
    let first = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "first")
    try fixture.mail(from: fixture.alphaToken, to: fixture.alpha, "for the sender")
    let second = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "second")

    let page = try fixture.messages.inbox(token: fixture.alphaPeerToken, after: nil)

    #expect(page.entries.map(\.messageID) == [first, second], "oldest first, only its own mail")
    #expect(page.entries.map(\.subject) == ["first", "second"], "the subjects")
    #expect(page.entries.map(\.sender) == [fixture.alpha.id, fixture.alpha.id], "the senders")
    #expect(page.next == nil, "one page is all there is")
    #expect(
      try fixture.messages.inbox(token: fixture.betaToken, after: nil).entries.isEmpty,
      "another principal sees nothing")
  }

  @Test func test_inbox_leavesOutAcknowledgedMail() throws {
    let fixture = try MessagingFixture()
    let kept = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "kept")
    let done = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "done")
    try fixture.messages.acknowledge(token: fixture.alphaPeerToken, messageID: done)

    let page = try fixture.messages.inbox(token: fixture.alphaPeerToken, after: nil)

    #expect(page.entries.map(\.messageID) == [kept], "only the pending delivery is listed")
  }

  @Test func test_inbox_pagesWithTheCatalogPageSizeAndACursor() throws {
    let fixture = try MessagingFixture()
    _ = try fixture.settings.change(
      SettingAddress(key: "messaging.page_size", scope: .global, subject: nil), to: .integer(2),
      ownerToken: fixture.owner)
    let sent = try (1...5).map { number in
      try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "m\(number)")
    }

    let first = try fixture.messages.inbox(token: fixture.alphaPeerToken, after: nil)
    let second = try fixture.messages.inbox(token: fixture.alphaPeerToken, after: first.next)
    let third = try fixture.messages.inbox(token: fixture.alphaPeerToken, after: second.next)

    #expect(first.entries.map(\.messageID) == Array(sent[0..<2]), "the first page")
    #expect(second.entries.map(\.messageID) == Array(sent[2..<4]), "the second page")
    #expect(third.entries.map(\.messageID) == [sent[4]], "the last page is short")
    #expect(first.next != nil && second.next != nil, "more pages follow")
    #expect(third.next == nil, "no cursor after the last page")
  }

  @Test func test_inbox_ownerToken_isRefused() throws {
    let fixture = try MessagingFixture()

    #expect(throws: IdentityError.principalCredentialRequired) {
      _ = try fixture.messages.inbox(token: fixture.owner, after: nil)
    }
  }

  // MARK: - Read

  @Test func test_read_recipientGetsTheContent_andTheDeliveryStaysPending() throws {
    let fixture = try MessagingFixture()
    let id = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer, "hello")

    let message = try fixture.messages.read(token: fixture.alphaPeerToken, messageID: id)

    #expect(message.body == "body of hello", "the content")
    #expect(
      !(try fixture.isAcknowledged(id, by: fixture.alphaPeer)), "reading does not acknowledge")
    #expect(
      try fixture.messages.inbox(token: fixture.alphaPeerToken, after: nil).entries.count == 1,
      "the mail is still in the inbox")
  }

  @Test func test_read_senderAndHeadOfTheSendersFamilyMayRead_othersMayNot() throws {
    let fixture = try MessagingFixture()
    let id = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer)

    #expect(
      try fixture.messages.read(token: fixture.alphaToken, messageID: id).id == id, "the sender")
    #expect(
      try fixture.messages.read(token: fixture.alphaHeadToken, messageID: id).id == id,
      "the head of the sender's family, decided from the stored sender")
    #expect(throws: MessagingError.messageUnavailable(id)) {
      _ = try fixture.messages.read(token: fixture.betaToken, messageID: id)
    }
  }

  @Test func test_read_unknownMessage_looksLikeAForbiddenOne() throws {
    let fixture = try MessagingFixture()

    #expect(throws: MessagingError.messageUnavailable(MessageID("nothing"))) {
      _ = try fixture.messages.read(token: fixture.alphaToken, messageID: MessageID("nothing"))
    }
  }

  @Test func test_read_grantOpensOnlyTheMailItsTargetNames() throws {
    let fixture = try MessagingFixture()
    let id = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer)
    _ = try fixture.rights.addReadGrant(
      reader: .principal(fixture.beta.id), target: .family("B"), expiresAt: nil,
      ownerToken: fixture.owner)

    #expect(throws: MessagingError.messageUnavailable(id)) {
      _ = try fixture.messages.read(token: fixture.betaToken, messageID: id)
    }
    _ = try fixture.rights.addReadGrant(
      reader: .principal(fixture.beta.id), target: .family("A"), expiresAt: nil,
      ownerToken: fixture.owner)
    #expect(
      try fixture.messages.read(token: fixture.betaToken, messageID: id).id == id,
      "a grant naming the sender's family opens it")
  }

  // MARK: - Acknowledge

  @Test func test_acknowledge_recipient_marksTheDeliveryAndEmptiesTheInbox() throws {
    let fixture = try MessagingFixture()
    let id = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer)

    try fixture.messages.acknowledge(token: fixture.alphaPeerToken, messageID: id)

    #expect(try fixture.isAcknowledged(id, by: fixture.alphaPeer), "acknowledged")
    #expect(
      try fixture.acknowledgedAt(id, by: fixture.alphaPeer) == 1_800_000_000_000,
      "at the injected time")
    #expect(
      try fixture.messages.inbox(token: fixture.alphaPeerToken, after: nil).entries.isEmpty,
      "nothing pending")
    #expect(
      try fixture.messages.read(token: fixture.alphaPeerToken, messageID: id).id == id,
      "an acknowledged message can still be read")
  }

  @Test func test_acknowledge_twice_isIdempotentAndKeepsTheFirstTime() throws {
    let fixture = try MessagingFixture()
    let id = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer)
    try fixture.messages.acknowledge(token: fixture.alphaPeerToken, messageID: id)
    fixture.clock.instant = fixture.clock.instant.addingTimeInterval(60)

    try fixture.messages.acknowledge(token: fixture.alphaPeerToken, messageID: id)

    #expect(
      try fixture.acknowledgedAt(id, by: fixture.alphaPeer) == 1_800_000_000_000,
      "the first acknowledgement time stands")
  }

  @Test func test_acknowledge_oneRecipient_leavesTheOthersPending() throws {
    let fixture = try MessagingFixture()
    try fixture.rights.allowSending(from: "A", to: "B", ownerToken: fixture.owner)
    let id = try fixture.messages.send(
      token: fixture.alphaToken, to: [fixture.alphaPeer.id, fixture.beta.id], subject: "s",
      body: "b")

    try fixture.messages.acknowledge(token: fixture.alphaPeerToken, messageID: id)

    #expect(try fixture.isAcknowledged(id, by: fixture.alphaPeer), "the acknowledging recipient")
    #expect(!(try fixture.isAcknowledged(id, by: fixture.beta)), "the other recipient is untouched")
  }

  @Test func test_acknowledge_nonRecipient_isRefusedAndChangesNothing() throws {
    let fixture = try MessagingFixture()
    let id = try fixture.mail(from: fixture.alphaToken, to: fixture.alphaPeer)

    #expect(throws: MessagingError.messageUnavailable(id)) {
      try fixture.messages.acknowledge(token: fixture.alphaToken, messageID: id)
    }
    #expect(throws: MessagingError.messageUnavailable(id)) {
      try fixture.messages.acknowledge(token: fixture.alphaHeadToken, messageID: id)
    }
    #expect(!(try fixture.isAcknowledged(id, by: fixture.alphaPeer)), "still pending")
  }

  @Test func test_acknowledge_unknownMessage_isRefused() throws {
    let fixture = try MessagingFixture()

    #expect(throws: MessagingError.messageUnavailable(MessageID("nothing"))) {
      try fixture.messages.acknowledge(token: fixture.alphaToken, messageID: MessageID("nothing"))
    }
  }
}

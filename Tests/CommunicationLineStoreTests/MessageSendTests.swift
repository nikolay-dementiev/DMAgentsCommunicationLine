import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation
import Testing

@Suite struct MessageSendTests {
  @Test func test_send_sameFamily_storesTheMessageAndOnePendingDeliveryPerRecipient() throws {
    let fixture = try MessagingFixture()

    let id = try fixture.messages.send(
      token: fixture.alphaToken, to: [fixture.alphaPeer.id], subject: "hello", body: "world")

    let stored = try #require(try fixture.store.message(id: id))
    #expect(stored.sender == fixture.alpha.id, "the sender comes from the token")
    #expect(stored.family == "A", "the sender's family")
    #expect(stored.recipients == [fixture.alphaPeer.id], "the original recipients")
    #expect(stored.subject == "hello" && stored.body == "world", "the content")
    #expect(stored.createdAt == fixture.clock.instant, "the time comes from the injected clock")
    #expect(
      try fixture.identity.raw().integer(
        "SELECT count(*) FROM deliveries WHERE state = 'pending'") == 1,
      "one pending delivery")
  }

  @Test func test_send_severalRecipients_createsOneDeliveryEach_andIgnoresDuplicates() throws {
    let fixture = try MessagingFixture()
    try fixture.rights.allowSending(from: "A", to: "B", ownerToken: fixture.owner)

    let id = try fixture.messages.send(
      token: fixture.alphaToken,
      to: [fixture.alphaPeer.id, fixture.beta.id, fixture.alphaPeer.id], subject: "s", body: "b")

    let stored = try #require(try fixture.store.message(id: id))
    #expect(
      stored.recipients == [fixture.alphaPeer.id, fixture.beta.id],
      "each recipient once, in the order given")
    #expect(try fixture.count("deliveries") == 2, "two deliveries")
  }

  @Test func test_send_oneRefusedRecipient_storesNothingAndNamesIt() throws {
    let fixture = try MessagingFixture()

    #expect(throws: MessagingError.recipientRefused(fixture.beta.id)) {
      _ = try fixture.messages.send(
        token: fixture.alphaToken, to: [fixture.alphaPeer.id, fixture.beta.id], subject: "s",
        body: "b")
    }
    #expect(try fixture.count("messages") == 0, "no message, although one recipient was allowed")
    #expect(try fixture.count("deliveries") == 0, "no delivery for the allowed recipient")
    #expect(fixture.recorder.signals.isEmpty, "nobody is signalled about a refused send")
  }

  @Test func test_send_acrossFamilies_followsTheOwnerRuleInThatDirectionOnly() throws {
    let fixture = try MessagingFixture()
    try fixture.rights.allowSending(from: "A", to: "B", ownerToken: fixture.owner)

    _ = try fixture.messages.send(
      token: fixture.alphaToken, to: [fixture.beta.id], subject: "s", body: "b")

    #expect(throws: MessagingError.recipientRefused(fixture.alpha.id)) {
      _ = try fixture.messages.send(
        token: fixture.betaToken, to: [fixture.alpha.id], subject: "s", body: "b")
    }
  }

  @Test func test_send_senderDisabledAfterAuthentication_isRefusedInsideTheTransaction() throws {
    let fixture = try MessagingFixture()
    fixture.store.beforeSend = {
      try fixture.identity.service.disablePrincipal(fixture.alpha.id, ownerToken: fixture.owner)
    }

    #expect(throws: IdentityError.principalDisabled) {
      _ = try fixture.messages.send(
        token: fixture.alphaToken, to: [fixture.alphaPeer.id], subject: "s", body: "b")
    }
    #expect(try fixture.count("messages") == 0, "nothing was stored")
  }

  @Test func test_send_recipientDisabledAfterAuthentication_isRefused() throws {
    let fixture = try MessagingFixture()
    fixture.store.beforeSend = {
      try fixture.identity.service.disablePrincipal(fixture.alphaPeer.id, ownerToken: fixture.owner)
    }

    #expect(throws: MessagingError.recipientRefused(fixture.alphaPeer.id)) {
      _ = try fixture.messages.send(
        token: fixture.alphaToken, to: [fixture.alphaPeer.id], subject: "s", body: "b")
    }
  }

  @Test func test_send_ruleRemovedAfterAuthentication_isRefused() throws {
    let fixture = try MessagingFixture()
    try fixture.rights.allowSending(from: "A", to: "B", ownerToken: fixture.owner)
    fixture.store.beforeSend = {
      try fixture.rights.removeSendRule(from: "A", to: "B", ownerToken: fixture.owner)
    }

    #expect(throws: MessagingError.recipientRefused(fixture.beta.id)) {
      _ = try fixture.messages.send(
        token: fixture.alphaToken, to: [fixture.beta.id], subject: "s", body: "b")
    }
  }

  @Test func test_send_unknownRecipient_isRefusedWithItsName() throws {
    let fixture = try MessagingFixture()

    #expect(throws: MessagingError.unknownRecipient(PrincipalID("nobody"))) {
      _ = try fixture.messages.send(
        token: fixture.alphaToken, to: [PrincipalID("nobody")], subject: "s", body: "b")
    }
  }

  @Test func test_send_withoutRecipients_storesNothing() throws {
    let fixture = try MessagingFixture()

    #expect(throws: MessageError.noRecipients) {
      _ = try fixture.messages.send(token: fixture.alphaToken, to: [], subject: "s", body: "b")
    }
    #expect(try fixture.count("messages") == 0, "no message without recipients")
  }

  @Test func test_send_bodyOverTheCatalogLimit_storesNothing() throws {
    let fixture = try MessagingFixture()
    _ = try fixture.settings.change(
      SettingAddress(key: "messaging.body_max", scope: .global, subject: nil), to: .integer(10),
      ownerToken: fixture.owner)

    #expect(throws: MessageError.bodyTooLarge(limit: 10, actual: 11)) {
      _ = try fixture.messages.send(
        token: fixture.alphaToken, to: [fixture.alphaPeer.id], subject: "s",
        body: String(repeating: "b", count: 11))
    }
    #expect(try fixture.count("messages") == 0, "an oversized body is not stored")
    _ = try fixture.messages.send(
      token: fixture.alphaToken, to: [fixture.alphaPeer.id], subject: "s",
      body: String(repeating: "b", count: 10))
    #expect(try fixture.count("messages") == 1, "a body at the limit is stored")
  }

  @Test func test_send_subjectOverTheDefaultLimit_isRefused() throws {
    let fixture = try MessagingFixture()

    #expect(throws: MessageError.subjectTooLarge(limit: 512, actual: 513)) {
      _ = try fixture.messages.send(
        token: fixture.alphaToken, to: [fixture.alphaPeer.id],
        subject: String(repeating: "s", count: 513), body: "b")
    }
  }

  @Test func test_send_ownerToken_isRefused() throws {
    let fixture = try MessagingFixture()

    #expect(throws: IdentityError.principalCredentialRequired) {
      _ = try fixture.messages.send(
        token: fixture.owner, to: [fixture.alphaPeer.id], subject: "s", body: "b")
    }
    #expect(try fixture.count("messages") == 0, "the owner is not a sender")
  }

  @Test func test_send_afterTheCommit_signalsExactlyTheRecipients() throws {
    let fixture = try MessagingFixture()

    _ = try fixture.messages.send(
      token: fixture.alphaToken, to: [fixture.alphaPeer.id], subject: "s", body: "b")

    #expect(
      fixture.recorder.signals == [[fixture.alphaPeer.id]], "one signal naming the recipients")
  }
}

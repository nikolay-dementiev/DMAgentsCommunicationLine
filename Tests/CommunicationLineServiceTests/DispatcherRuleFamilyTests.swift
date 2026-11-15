import CommunicationLineWire
import Foundation
import Testing

struct DispatcherRuleFamilyTests {
  private func rules(_ response: WireResponse) throws -> [WireValue] {
    guard case .object(let fields)? = response.result, case .array(let items)? = fields["rules"]
    else { throw POSIXError(.EIO) }
    return items
  }

  private func rule(_ from: String, _ to: String) -> WireValue {
    .object(["from": .string(from), "to": .string(to)])
  }

  private func makeFixture() throws -> (fixture: ServiceFixture, owner: String) {
    let fixture = try ServiceFixture()
    let owner = try fixture.bootstrapOwner()
    for (from, to) in [("A", "B"), ("C", "A"), ("B", "C")] {
      _ = fixture.call("rule.add", token: owner, ["from": .string(from), "to": .string(to)])
    }
    return (fixture, owner)
  }

  @Test func test_withoutAFamily_everyRuleIsListed() throws {
    let world = try makeFixture()

    let all = try rules(world.fixture.call("rule.list", token: world.owner))

    #expect(all.count == 3, "as in v0.1, nothing is filtered")
  }

  @Test func test_withAFamily_keepsTheRulesThatSendFromItOrIntoIt() throws {
    let world = try makeFixture()

    let listed = try rules(
      world.fixture.call("rule.list", token: world.owner, ["family": .string("A")]))

    #expect(listed.contains(rule("A", "B")), "a rule out of the family")
    #expect(listed.contains(rule("C", "A")), "a rule into the family from another one")
    #expect(!listed.contains(rule("B", "C")), "a rule between two other families is left out")
  }

  @Test func test_withAFamilyThatHasNoRule_theListIsEmpty() throws {
    let world = try makeFixture()

    let listed = try rules(
      world.fixture.call("rule.list", token: world.owner, ["family": .string("Nobody")]))

    #expect(listed.isEmpty, "no rule mentions it; it is not an error")
  }
}

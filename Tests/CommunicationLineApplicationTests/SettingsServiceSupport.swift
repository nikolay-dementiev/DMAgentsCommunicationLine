import CommunicationLineApplication
import CommunicationLineDomain
import Foundation

struct FixedClock: WallClock {
  let instant: Date
  func now() -> Date { instant }
}

/// Records what the service asks of the store and answers with canned values.
final class SpySettingsStore: SettingsStore {
  var stored = StoredSettingValues(principal: nil, family: nil, global: nil)
  private(set) var lookups: [(key: String, family: String?, principal: String?)] = []
  private(set) var applied:
    [(address: SettingAddress, value: SettingValue, actor: String, at: Date)] =
      []

  func storedValues(key: String, family: String?, principal: String?) throws -> StoredSettingValues
  {
    lookups.append((key, family, principal))
    return stored
  }

  func apply(
    _ value: SettingValue, to address: SettingAddress, actor: String, at instant: Date
  ) throws -> SettingAuditRecord {
    applied.append((address, value, actor, instant))
    return SettingAuditRecord(
      at: instant, actor: actor, address: address, oldValue: nil, newValue: value)
  }

  func auditRecords(key: String) throws -> [SettingAuditRecord] { [] }
}

let demoCatalogJSON = Data(
  #"""
  {"settings":[
    {"key":"demo.limit","type":"integer","default":5,"range":{"min":1,"max":10},
     "scopes":["global","family","principal"],"description":"A demo limit."},
    {"key":"demo.budget","type":"bytes","default":100,"range":{"min":1},
     "scopes":["global"],"description":"A demo budget."}
  ]}
  """#.utf8)

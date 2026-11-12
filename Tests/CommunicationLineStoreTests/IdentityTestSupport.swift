import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation

struct StoreFixedClock: WallClock {
  let instant: Date
  func now() -> Date { instant }
}

/// Returns 32 bytes that differ on every call, or the same bytes every time when `repeating`.
final class SequenceRandom: RandomSource {
  private var counter: UInt8 = 0
  private let repeating: Bool

  init(repeating: Bool = false) { self.repeating = repeating }

  func randomBytes(count: Int) throws -> [UInt8] {
    if !repeating { counter += 1 }
    return [UInt8](repeating: repeating ? 9 : counter, count: count)
  }
}

struct FailingRandom: RandomSource {
  struct Failure: Error, Equatable {}
  func randomBytes(count: Int) throws -> [UInt8] { throw Failure() }
}

final class SequentialIdentifiers: IdentifierSource {
  private var next = 0
  private var nextMessage = 0

  func newMessageID() -> MessageID {
    nextMessage += 1
    return MessageID("m\(nextMessage)")
  }

  func newPrincipalID() -> PrincipalID {
    next += 1
    return PrincipalID("p\(next)")
  }
}

/// A real store on a scratch file with the identity service on top of it.
struct IdentityFixture {
  let service: IdentityService
  let owner: CredentialToken
  let scratch: TemporaryDirectory
  let store: SQLiteStore

  init(random: any RandomSource = SequenceRandom()) throws {
    scratch = try TemporaryDirectory()
    store = try SQLiteStore.open(
      at: scratch.storePath, busyTimeoutMilliseconds: 1000, migrations: SchemaMigrations.all)
    service = IdentityService(
      store: SQLiteIdentityStore(store: store), random: random,
      identifiers: SequentialIdentifiers(),
      clock: StoreFixedClock(instant: Date(timeIntervalSince1970: 1_800_000_000)))
    owner = try service.issueOwnerCredential(replacing: nil)
  }

  func raw() throws -> RawDatabase { try RawDatabase(path: scratch.storePath) }

  /// Every byte of the database file and its write-ahead log.
  func everythingOnDisk() throws -> Data {
    var bytes = try Data(contentsOf: scratch.storePath)
    let log = URL(fileURLWithPath: scratch.storePath.path + "-wal")
    if let extra = try? Data(contentsOf: log) { bytes.append(extra) }
    return bytes
  }
}

import CommunicationLineApplication
import CommunicationLineDomain
import CommunicationLineStore
import Foundation

/// The wall clock of the running service.
struct SystemWallClock: WallClock {
  func now() -> Date { Date() }
}

public enum ServiceRuntimeError: Error, Equatable {
  case missingSetting(String)
  case invalidFrameMaximum(Int64)
}

/// The composition root: the one place that picks the concrete store, services and arrival.
public final class ServiceRuntime {
  /// File names inside the store folder.
  public static let databaseName = "commline.sqlite"

  public let dispatcher: RequestDispatcher
  /// The largest frame the service reads or writes, from the `service.frame_max` setting at start.
  public let frameMaximum: Int
  /// How often the service runs cleanup, from the `cleanup.interval` setting at start.
  public let cleanupInterval: TimeInterval
  public let cleanup: CleanupRunner
  private let store: SQLiteStore
  private let arrival: InProcessMailArrival

  private init(
    dispatcher: RequestDispatcher, frameMaximum: Int, cleanupInterval: TimeInterval,
    cleanup: CleanupRunner, store: SQLiteStore, arrival: InProcessMailArrival
  ) {
    self.cleanupInterval = cleanupInterval
    self.cleanup = cleanup
    self.arrival = arrival
    self.dispatcher = dispatcher
    self.frameMaximum = frameMaximum
    self.store = store
  }

  /// Opens (or creates) the store in `storeFolder` and wires the services onto it.
  public static func open(
    storeFolder: URL, clock: (any WallClock)? = nil,
    reporter: any FailureReporter = StandardErrorReporter()
  ) throws -> ServiceRuntime {
    let catalog = try BundledSettingsCatalogSource.shipped.load()
    let busyTimeout = try integerDefault(of: "store.busy_timeout", in: catalog)
    let store = try SQLiteStore.open(
      at: storeFolder.appendingPathComponent(databaseName),
      busyTimeoutMilliseconds: Int(busyTimeout), migrations: SchemaMigrations.all)
    let clock: any WallClock = clock ?? SystemWallClock()
    let identity = IdentityService(
      store: SQLiteIdentityStore(store: store), random: SecureRandomSource(),
      identifiers: UUIDIdentifierSource(), clock: clock)
    let rights = RightsService(
      rights: SQLiteRightsStore(store: store), principals: SQLiteIdentityStore(store: store),
      authenticator: identity, clock: clock)
    let settingsStore = SQLiteSettingsStore(store: store)
    let settings = SettingsService(
      catalog: catalog, store: settingsStore, clock: clock, authenticator: identity)
    let arrival = InProcessMailArrival()
    let messages = MessageService(
      store: SQLiteMessageStore(store: store), rights: SQLiteRightsStore(store: store),
      authenticator: identity, settings: settings, identifiers: UUIDIdentifierSource(),
      clock: clock, arrival: arrival,
      waitQuota: WaitQuota())
    let frameMaximum = try frameMaximum(catalog: catalog, store: settingsStore)
    let activity = ActivityService(
      store: SQLiteActivityStore(store: store), identity: identity, settings: settings,
      clock: clock)
    let transactions = SQLiteTransactionRunner(store: store)
    let cleanup = CleanupRunner(
      service: CleanupService(
        store: SQLiteRetentionStore(store: store), settings: settings, transactions: transactions,
        clock: clock),
      clock: clock)
    let dispatcher = RequestDispatcher(
      identity: identity, rights: rights, settings: settings, messages: messages,
      activity: activity, cleanup: cleanup, transactions: transactions, reporter: reporter)
    return ServiceRuntime(
      dispatcher: dispatcher, frameMaximum: frameMaximum,
      cleanupInterval: try cleanupInterval(settings), cleanup: cleanup, store: store,
      arrival: arrival)
  }

  /// Answers every parked `wait` now, as if its time had run out.
  public func cancelWaits() {
    arrival.close()
  }

  /// Closes the database. The dispatcher answers `internal` to anything that arrives later.
  public func close() {
    store.close()
  }

  private static func cleanupInterval(_ settings: SettingsService) throws -> TimeInterval {
    guard case .integer(let seconds) = try settings.serviceValue(of: "cleanup.interval"),
      seconds >= 1
    else { throw ServiceRuntimeError.missingSetting("cleanup.interval") }
    return TimeInterval(seconds)
  }

  private static func integerDefault(of key: String, in catalog: SettingsCatalog) throws -> Int64 {
    guard case .integer(let value)? = catalog.definition(for: key)?.defaultValue else {
      throw ServiceRuntimeError.missingSetting(key)
    }
    return value
  }

  private static func frameMaximum(catalog: SettingsCatalog, store: any SettingsStore) throws -> Int
  {
    let key = "service.frame_max"
    guard let definition = catalog.definition(for: key) else {
      throw ServiceRuntimeError.missingSetting(key)
    }
    let stored = try store.storedValues(key: key, family: nil, principal: nil)
    let value = definition.effectiveValue(principal: nil, family: nil, global: stored.global)
    guard case .integer(let bytes) = value, bytes >= 1, bytes <= Int64(Int32.max) else {
      throw ServiceRuntimeError.invalidFrameMaximum(
        { if case .integer(let raw) = value { return raw } else { return 0 } }())
    }
    return Int(bytes)
  }
}

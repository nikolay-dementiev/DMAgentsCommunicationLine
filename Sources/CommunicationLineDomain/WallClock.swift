import Foundation

/// The source of the current time; injected so that audited times are deterministic in tests.
public protocol WallClock {
  func now() -> Date
}

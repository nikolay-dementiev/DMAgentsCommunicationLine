import Foundation

/// How the store keeps times: whole milliseconds since 1970.
enum StoreTime {
  static func milliseconds(of instant: Date) throws -> Int64 {
    guard let value = Int64(exactly: (instant.timeIntervalSince1970 * 1000).rounded()) else {
      throw StoreError.invalidTimestamp
    }
    return value
  }
}

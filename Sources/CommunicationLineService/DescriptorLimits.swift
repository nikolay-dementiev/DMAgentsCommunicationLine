import Darwin

/// The limit on open files of the process.
public protocol DescriptorLimits: Sendable {
  /// Raises the soft limit as far as the hard limit allows and returns the soft limit in force.
  func raiseSoftLimit() throws -> UInt64
}

/// The limit the system enforces on this process.
public struct SystemDescriptorLimits: DescriptorLimits {
  public init() {}

  /// A soft limit that cannot be raised is not an error: the limit that stays is the answer, and
  /// the connection budget is worked out from it.
  public func raiseSoftLimit() throws -> UInt64 {
    var limit = rlimit()
    guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
      throw ServiceHostError.system(operation: "getrlimit", code: errno)
    }
    let target = min(limit.rlim_max, Self.perProcessCeiling())
    if limit.rlim_cur < target {
      var raised = limit
      raised.rlim_cur = target
      if setrlimit(RLIMIT_NOFILE, &raised) == 0 { return UInt64(target) }
    }
    return UInt64(limit.rlim_cur)
  }

  /// A soft limit above this is refused by the system whatever the hard limit says.
  private static func perProcessCeiling() -> rlim_t {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname("kern.maxfilesperproc", &value, &size, nil, 0) == 0, value > 0 else {
      return 10_240
    }
    return rlim_t(value)
  }
}

/// How many connections a descriptor limit leaves room for.
public enum DescriptorBudget {
  /// What the service holds apart from connections: standard streams, the listener, the instance
  /// lock, the database files, the connections held only to refuse them, and a margin.
  public static let reservedDescriptors = 64
  /// What one connection can hold at most: a parked wait keeps the socket and what watches it.
  public static let descriptorsPerConnection = 3

  /// At least one, so that the service can always answer.
  public static func connectionsFitting(softLimit: UInt64) -> Int {
    let reserved = UInt64(reservedDescriptors)
    guard softLimit > reserved else { return 1 }
    return max(1, Int((softLimit - reserved) / UInt64(descriptorsPerConnection)))
  }
}

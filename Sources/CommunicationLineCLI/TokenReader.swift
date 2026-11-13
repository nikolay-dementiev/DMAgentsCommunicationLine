import Darwin
import Foundation

public enum TokenInputError: Error, Equatable {
  case unreadable(String)
  case notRegularFile(String)
  case notOwnedByUser(String)
  /// Others can read or write the file: `mode` is its permission bits.
  case insecureMode(path: String, mode: Int)
  case empty
  /// No file was named and standard input held nothing.
  case notSupplied
}

/// Reads the token from a private file or from standard input. It is never read from an argument or
/// from the environment, where other processes could see it.
public struct TokenReader {
  private let standardInput: () throws -> String?
  private let userID: UInt32

  /// `standardInput` returns the first line of standard input, or nil when there is none. A token
  /// file must belong to `userID`, which is the current user unless a test says otherwise.
  public init(
    standardInput: @escaping () throws -> String?, userID: UInt32 = UInt32(geteuid())
  ) {
    self.standardInput = standardInput
    self.userID = userID
  }

  public func read(tokenFile: String?) throws -> String {
    let raw: String
    if let tokenFile {
      raw = try contents(ofPrivateFile: tokenFile)
    } else {
      guard let line = try standardInput() else { throw TokenInputError.notSupplied }
      raw = line
    }
    let token =
      (raw.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty else { throw TokenInputError.empty }
    return token
  }

  private func contents(ofPrivateFile path: String) throws -> String {
    // O_NOFOLLOW: a link could point at a file that is private only by accident.
    // O_NONBLOCK: opening a pipe with no writer would otherwise wait for one before the type is checked.
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard descriptor >= 0 else { throw TokenInputError.unreadable(path) }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw TokenInputError.unreadable(path) }
    guard (info.st_mode & S_IFMT) == S_IFREG else { throw TokenInputError.notRegularFile(path) }
    guard info.st_uid == userID else { throw TokenInputError.notOwnedByUser(path) }
    let permissions = Int(info.st_mode & 0o7777)
    guard permissions & 0o077 == 0 else {
      throw TokenInputError.insecureMode(path: path, mode: permissions)
    }
    guard let data = try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd()
    else { throw TokenInputError.unreadable(path) }
    return String(decoding: data, as: UTF8.self)
  }
}

import Foundation

/// The folder that holds the database and the service's own files.
public enum StoreFolder {
  /// Creates the folder private to its owner, or checks that an existing one is.
  public static func prepare(_ folder: URL, waitingUpTo timeoutMilliseconds: Int) throws {
    try StoreFilesystem.prepareFolder(folder, waitingUpTo: timeoutMilliseconds)
  }
}
